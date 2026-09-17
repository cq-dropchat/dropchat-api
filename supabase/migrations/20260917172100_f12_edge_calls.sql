-- F12. Edited by hand after db diff:
--   * the two message triggers are replaced in place (CREATE OR REPLACE
--     TRIGGER, at the end, once edge_calls exists) instead of dropped first:
--     the CLI runs each statement on its own, and a message inserted between
--     a DROP and the CREATE would reach neither pg_net nor the queue;
--   * edge_calls_health keeps security_invoker (db diff drops the option).



  create table "public"."edge_calls" (
    "id" uuid not null default gen_random_uuid(),
    "organization_id" uuid not null,
    "function" text not null,
    "record_id" uuid not null,
    "payload" jsonb not null,
    "forward_headers" jsonb not null default '{}'::jsonb,
    "status" text not null default 'pending'::text,
    "attempts" integer not null default 0,
    "next_attempt_at" timestamp with time zone not null default now(),
    "locked_until" timestamp with time zone,
    "request_id" bigint,
    "last_status_code" integer,
    "last_error" text,
    "created_at" timestamp with time zone not null default now(),
    "updated_at" timestamp with time zone not null default now()
      );


alter table "public"."edge_calls" enable row level security;

CREATE INDEX edge_calls_pending_idx ON public.edge_calls USING btree (organization_id, next_attempt_at) WHERE (status = 'pending'::text);

CREATE UNIQUE INDEX edge_calls_pkey ON public.edge_calls USING btree (id);

CREATE INDEX edge_calls_record_idx ON public.edge_calls USING btree (record_id);

CREATE INDEX edge_calls_sending_idx ON public.edge_calls USING btree (request_id) WHERE (status = 'sending'::text);

alter table "public"."edge_calls" add constraint "edge_calls_pkey" PRIMARY KEY using index "edge_calls_pkey";

alter table "public"."edge_calls" add constraint "edge_calls_function_check" CHECK ((function = ANY (ARRAY['agent-client'::text, 'media-preprocessor'::text]))) not valid;

alter table "public"."edge_calls" validate constraint "edge_calls_function_check";

alter table "public"."edge_calls" add constraint "edge_calls_organization_id_fkey" FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE not valid;

alter table "public"."edge_calls" validate constraint "edge_calls_organization_id_fkey";

alter table "public"."edge_calls" add constraint "edge_calls_status_check" CHECK ((status = ANY (ARRAY['pending'::text, 'sending'::text, 'done'::text, 'failed'::text]))) not valid;

alter table "public"."edge_calls" validate constraint "edge_calls_status_check";

set check_function_bodies = off;

CREATE OR REPLACE FUNCTION public.deliver_edge_calls()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  _settled integer;
  _sent integer;
begin
  _settled := public.settle_edge_calls();
  _sent := public.dispatch_edge_calls();
  return jsonb_build_object('settled', _settled, 'sent', _sent);
end;
$function$
;

CREATE OR REPLACE FUNCTION public.dispatch_edge_calls(_batch integer DEFAULT 1000, _per_org integer DEFAULT 250)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  _base_url text;
  _token text;
  _row record;
  _request_id bigint;
  _sent integer := 0;
begin
  select * into _base_url, _token from public.edge_functions_config();

  for _row in
    select c.id, c.function, c.payload, c.forward_headers
    from (
      select p.id,
        row_number() over (partition by p.organization_id order by p.next_attempt_at, p.id) as rank,
        p.next_attempt_at
      from public.edge_calls p
      where p.status = 'pending'
        and p.next_attempt_at <= now()
    ) ranked
    join public.edge_calls c on c.id = ranked.id
    where ranked.rank <= _per_org
    order by ranked.rank, ranked.next_attempt_at
    limit _batch
    for update of c skip locked
  loop
    select net.http_post(
      url := _base_url || '/' || _row.function,
      body := _row.payload,
      headers := jsonb_build_object(
        'content-type', 'application/json',
        'authorization', 'Bearer ' || _token
      ) || _row.forward_headers,
      timeout_milliseconds := 10000
    ) into _request_id;

    update public.edge_calls
    set status = 'sending',
        attempts = attempts + 1,
        request_id = _request_id,
        locked_until = now() + public.edge_call_lease()
    where id = _row.id;

    _sent := _sent + 1;
  end loop;

  return _sent;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.edge_call_lease()
 RETURNS interval
 LANGUAGE sql
 IMMUTABLE
AS $function$
  select interval '2 minutes';
$function$
;

CREATE OR REPLACE FUNCTION public.edge_call_max_attempts()
 RETURNS integer
 LANGUAGE sql
 IMMUTABLE
AS $function$
  select 5;
$function$
;

CREATE OR REPLACE FUNCTION public.edge_call_retry_delay(attempt integer)
 RETURNS interval
 LANGUAGE sql
 IMMUTABLE
AS $function$
  select case attempt
    when 1 then interval '5 seconds'
    when 2 then interval '30 seconds'
    when 3 then interval '2 minutes'
    else interval '10 minutes'
  end;
$function$
;

create or replace view "public"."edge_calls_health" with (security_invoker = true) as  SELECT function,
    organization_id,
    count(*) FILTER (WHERE (status = 'pending'::text)) AS pending,
    count(*) FILTER (WHERE (status = 'sending'::text)) AS sending,
    count(*) FILTER (WHERE (status = 'failed'::text)) AS failed,
    min(created_at) FILTER (WHERE (status = 'pending'::text)) AS oldest_pending_at,
    max(updated_at) FILTER (WHERE (status = 'done'::text)) AS last_done_at
   FROM public.edge_calls c
  GROUP BY function, organization_id;


CREATE OR REPLACE FUNCTION public.enqueue_edge_call()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  insert into public.edge_calls (organization_id, function, record_id, payload, forward_headers)
  values (
    new.organization_id,
    tg_argv[0],
    new.id,
    jsonb_build_object(
      'old_record', old,
      'record', new,
      'type', tg_op,
      'table', tg_table_name,
      'schema', tg_table_schema
    ),
    public.request_id_header()
  );

  return new;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.record_edge_call_result(_id uuid, _status_code integer, _timed_out boolean, _error text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  _attempts integer;
begin
  select c.attempts into _attempts from public.edge_calls c where c.id = _id;

  if _attempts is null then
    return;
  end if;

  if _status_code between 200 and 299 or coalesce(_timed_out, false) then
    update public.edge_calls
    set status = 'done',
        last_status_code = _status_code,
        last_error = case when _timed_out then 'timed out waiting for the response; the function kept running' end,
        request_id = null,
        locked_until = null
    where id = _id;
  elsif _status_code between 400 and 499 and _status_code not in (408, 429) then
    update public.edge_calls
    set status = 'failed',
        last_status_code = _status_code,
        last_error = coalesce(_error, 'HTTP ' || _status_code::text),
        request_id = null,
        locked_until = null
    where id = _id;
  elsif _attempts >= public.edge_call_max_attempts() then
    update public.edge_calls
    set status = 'failed',
        last_status_code = _status_code,
        last_error = coalesce(_error, 'HTTP ' || _status_code::text),
        request_id = null,
        locked_until = null
    where id = _id;
  else
    update public.edge_calls
    set status = 'pending',
        next_attempt_at = now() + public.edge_call_retry_delay(_attempts),
        last_status_code = _status_code,
        last_error = coalesce(_error, 'HTTP ' || _status_code::text),
        request_id = null,
        locked_until = null
    where id = _id;
  end if;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.settle_edge_calls()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  _row record;
  _settled integer := 0;
begin
  for _row in
    select c.id, c.locked_until, r.id as response_id, r.status_code, r.timed_out, r.error_msg
    from public.edge_calls c
    left join net._http_response r on r.id = c.request_id
    where c.status = 'sending'
    for update of c skip locked
  loop
    if _row.response_id is not null then
      perform public.record_edge_call_result(
        _row.id, _row.status_code, _row.timed_out, _row.error_msg
      );
      _settled := _settled + 1;
    elsif _row.locked_until < now() then
      perform public.record_edge_call_result(_row.id, null, false, 'no response');
      _settled := _settled + 1;
    end if;
  end loop;

  return _settled;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.local_message_to_agent()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  segments text[] := string_to_array(new.conversation_address, ':');
begin
  -- Two-member rosters only, for now: deleting this guard is the entire
  -- multi-party extension. Group/channel addresses are a single uuid and fail
  -- it too, and `is distinct from` keeps a peerless row (null address) out.
  if array_length(segments, 1) is distinct from 2 then
    return new;
  end if;

  if not exists (
    select 1 from public.agents a
    where a.organization_id = new.organization_id
      and a.id::text = any (segments)
      and a.id <> new.agent_id
      and a.user_id is null
      and a.deleted_at is null
  ) then
    return new;
  end if;

  -- F12: queued like the contact-space trigger (edge_calls), not posted.
  insert into public.edge_calls (organization_id, function, record_id, payload, forward_headers)
  values (
    new.organization_id,
    'agent-client',
    new.id,
    jsonb_build_object(
      'old_record', old,
      'record', new,
      'type', tg_op,
      'table', tg_table_name,
      'schema', tg_table_schema
    ),
    public.request_id_header()
  );

  return new;
end
$function$
;

grant delete on table "public"."edge_calls" to "service_role";

grant insert on table "public"."edge_calls" to "service_role";

grant references on table "public"."edge_calls" to "service_role";

grant select on table "public"."edge_calls" to "service_role";

grant trigger on table "public"."edge_calls" to "service_role";

grant truncate on table "public"."edge_calls" to "service_role";

grant update on table "public"."edge_calls" to "service_role";

CREATE TRIGGER set_updated_at BEFORE UPDATE ON public.edge_calls FOR EACH ROW EXECUTE FUNCTION public.moddatetime('updated_at');

CREATE OR REPLACE TRIGGER handle_incoming_message_to_agent AFTER INSERT ON public.messages FOR EACH ROW WHEN (((new.sender_address IS NOT NULL) AND (new.service <> ALL (ARRAY['local'::public.service, 'slack'::public.service])) AND ((new.status ->> 'pending'::text) IS NOT NULL))) EXECUTE FUNCTION public.enqueue_edge_call('agent-client');

CREATE OR REPLACE TRIGGER handle_message_to_media_preprocessor AFTER INSERT ON public.messages FOR EACH ROW WHEN ((((new.status ->> 'pending'::text) IS NOT NULL) AND ((new.content ->> 'type'::text) = 'file'::text))) EXECUTE FUNCTION public.enqueue_edge_call('media-preprocessor');



-- ---------------------------------------------------------------------------
-- Hand-written: privileges and schedule (db diff models neither).
-- ---------------------------------------------------------------------------

revoke all on table public.edge_calls from anon, authenticated;
revoke all on public.edge_calls_health from anon, authenticated;

revoke execute on function public.enqueue_edge_call() from public, anon, authenticated, service_role;
revoke execute on function public.record_edge_call_result(uuid, integer, boolean, text) from public, anon, authenticated;
revoke execute on function public.settle_edge_calls() from public, anon, authenticated;
revoke execute on function public.dispatch_edge_calls(integer, integer) from public, anon, authenticated;
revoke execute on function public.deliver_edge_calls() from public, anon, authenticated;

select cron.schedule(
  'deliver-edge-calls',
  '5 seconds',
  $$ select public.deliver_edge_calls() $$
);

-- Rollback (runbook in CLAUDE.md): point the two triggers back at
-- public.edge_function('/agent-client' | '/media-preprocessor', 'post'),
-- restore local_message_to_agent's net.http_post, and let this cron drain
-- what is queued before unscheduling it.

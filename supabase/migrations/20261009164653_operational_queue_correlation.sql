set check_function_bodies = off;

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
    select c.id, c.function, c.payload, c.forward_headers, c.attempts, c.next_attempt_at
    from (
      select p.id,
        row_number() over (partition by o.id order by p.next_attempt_at, p.id) as rank,
        p.next_attempt_at
      from public.organizations o
      cross join lateral (
        select q.id, q.next_attempt_at
        from public.edge_calls q
        where q.organization_id = o.id
          and q.status = 'pending'
          and q.next_attempt_at <= now()
        order by q.next_attempt_at, q.id
        limit least(greatest(_per_org, 0), greatest(_batch, 0))
      ) p
    ) ranked
    join public.edge_calls c on c.id = ranked.id
    where ranked.rank <= _per_org
    order by ranked.rank, ranked.next_attempt_at, c.id
    limit greatest(_batch, 0)
    for update of c skip locked
  loop
    select net.http_post(
      url := _base_url || '/' || _row.function,
      body := _row.payload,
      headers := jsonb_build_object(
        'content-type', 'application/json',
        'authorization', 'Bearer ' || _token
      ) || _row.forward_headers || jsonb_build_object(
        'x-job-id', _row.id::text,
        'x-job-attempt', (_row.attempts + 1)::text,
        'x-queue-wait-ms', (greatest(0, extract(epoch from now() - _row.next_attempt_at)) * 1000)::text
      ),
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



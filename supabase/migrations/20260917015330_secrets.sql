
  create table "public"."secrets" (
    "organization_id" uuid not null,
    "scope" text not null,
    "ref" text not null default ''::text,
    "service" public.service,
    "address" text,
    "agent_id" uuid,
    "value" jsonb not null default '{}'::jsonb,
    "created_at" timestamp with time zone not null default now(),
    "updated_at" timestamp with time zone not null default now()
      );


alter table "public"."secrets" enable row level security;

-- Hand-written (db diff cannot see it): the shadow it diffed against had no
-- table, so it emitted the service_role grants that survive 05-14_secrets_rls
-- but not the revoke that removes what the default privileges hand out.
revoke all on table "public"."secrets" from anon, authenticated;

CREATE INDEX secrets_agent_id_idx ON public.secrets USING btree (agent_id);

CREATE UNIQUE INDEX secrets_pkey ON public.secrets USING btree (organization_id, scope, ref);

alter table "public"."secrets" add constraint "secrets_pkey" PRIMARY KEY using index "secrets_pkey";

alter table "public"."secrets" add constraint "secrets_agent_id_fkey" FOREIGN KEY (organization_id, agent_id) REFERENCES public.agents(organization_id, id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED not valid;

alter table "public"."secrets" validate constraint "secrets_agent_id_fkey";

alter table "public"."secrets" add constraint "secrets_organization_address_fkey" FOREIGN KEY (organization_id, service, address) REFERENCES public.organizations_addresses(organization_id, service, address) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED not valid;

alter table "public"."secrets" validate constraint "secrets_organization_address_fkey";

alter table "public"."secrets" add constraint "secrets_organization_id_fkey" FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED not valid;

alter table "public"."secrets" validate constraint "secrets_organization_id_fkey";

alter table "public"."secrets" add constraint "secrets_scope_check" CHECK ((scope = ANY (ARRAY['organization'::text, 'address'::text, 'agent'::text]))) not valid;

alter table "public"."secrets" validate constraint "secrets_scope_check";

set check_function_bodies = off;

CREATE OR REPLACE FUNCTION public.extract_secrets()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  mask constant text := '********';
  _org_id uuid;
  _scope text;
  _ref text;
  _service public.service;
  _address text;
  _agent_id uuid;
  _stored jsonb;
  _next jsonb;
  _extra jsonb := new.extra;
  _paths jsonb;
  _path text[];
  _p jsonb;
  _incoming jsonb;
  _tools jsonb;
  _tool jsonb;
  _tool_key text;
  _tool_secret jsonb;
  _tool_config jsonb;
  _headers jsonb;
  _stored_headers jsonb;
  _hkey text;
  _hval jsonb;
  _i int;
begin
  -- Where this row's secrets live.
  case tg_table_name
    when 'organizations' then
      _org_id := new.id;
      _scope := 'organization';
      _ref := '';
      _paths := '[["media_preprocessing", "api_key"]]';
    when 'organizations_addresses' then
      _org_id := new.organization_id;
      _scope := 'address';
      _ref := new.service::text || ':' || new.address;
      _service := new.service;
      _address := new.address;
      _paths := '[["access_token"], ["refresh_token"]]';
    when 'agents' then
      _org_id := new.organization_id;
      _scope := 'agent';
      _ref := new.id::text;
      _agent_id := new.id;
      _paths := '[["api_key"]]';
    else
      raise exception 'extract_secrets: unexpected table %', tg_table_name;
  end case;

  select s.value into _stored
  from public.secrets s
  where s.organization_id = _org_id
    and s.scope = _scope
    and s.ref = _ref;

  _next := coalesce(_stored, '{}'::jsonb);

  -- Scalar paths.
  for _p in select value from jsonb_array_elements(_paths) loop
    _path := array(select jsonb_array_elements_text(_p));
    _incoming := _extra #> _path;

    if _incoming is null or jsonb_typeof(_incoming) = 'null' then
      _next := _next #- _path;
    elsif jsonb_typeof(_incoming) = 'string' and _incoming #>> '{}' = mask then
      if _next #> _path is null then
        -- A mask with nothing behind it: the client is stating a secret we
        -- never had. Do not keep the lie in extra.
        _extra := _extra #- _path;
      end if;
    else
      _next := public.jsonb_deep_set(_next, _path, _incoming);
      _extra := jsonb_set(_extra, _path, to_jsonb(mask), true);
    end if;
  end loop;

  -- Agent tools: password/token scalars and the whole headers object.
  if tg_table_name = 'agents' then
    _tools := _extra -> 'tools';

    if _tools is not null and jsonb_typeof(_tools) = 'array' then
      _next := _next - 'tools';

      for _i in 0 .. jsonb_array_length(_tools) - 1 loop
        _tool := _tools -> _i;
        _tool_key := coalesce(_tool ->> 'type', '') || ':' ||
          coalesce(_tool ->> 'label', _tool ->> 'name', '');
        _tool_secret := coalesce(_stored #> array['tools', _tool_key], '{}'::jsonb);
        _tool_config := coalesce(_tool -> 'config', '{}'::jsonb);

        -- password, token
        for _path in select array[p] from unnest(array['password', 'token']) p loop
          _incoming := _tool_config #> _path;

          if _incoming is null or jsonb_typeof(_incoming) = 'null' then
            _tool_secret := _tool_secret #- _path;
          elsif jsonb_typeof(_incoming) = 'string' and _incoming #>> '{}' = mask then
            if _tool_secret #> _path is null then
              _tool_config := _tool_config #- _path;
            end if;
          else
            _tool_secret := jsonb_set(_tool_secret, _path, _incoming, true);
            _tool_config := jsonb_set(_tool_config, _path, to_jsonb(mask), true);
          end if;
        end loop;

        -- headers: every value is a secret, keys stay visible.
        _headers := _tool_config -> 'headers';

        if _headers is null or jsonb_typeof(_headers) <> 'object' then
          _tool_secret := _tool_secret - 'headers';
        else
          _stored_headers := coalesce(_tool_secret -> 'headers', '{}'::jsonb);

          for _hkey, _hval in select * from jsonb_each(_headers) loop
            if jsonb_typeof(_hval) = 'null' then
              _stored_headers := _stored_headers - _hkey;
              _headers := _headers - _hkey;
            elsif jsonb_typeof(_hval) = 'string' and _hval #>> '{}' = mask then
              if _stored_headers -> _hkey is null then
                _headers := _headers - _hkey;
              end if;
            else
              _stored_headers := jsonb_set(_stored_headers, array[_hkey], _hval, true);
              _headers := jsonb_set(_headers, array[_hkey], to_jsonb(mask), true);
            end if;
          end loop;

          -- Keys the client dropped are revoked.
          for _hkey in select k from jsonb_object_keys(_stored_headers) k loop
            if _headers -> _hkey is null then
              _stored_headers := _stored_headers - _hkey;
            end if;
          end loop;

          if _stored_headers = '{}'::jsonb then
            _tool_secret := _tool_secret - 'headers';
          else
            _tool_secret := jsonb_set(_tool_secret, '{headers}', _stored_headers, true);
          end if;

          _tool_config := jsonb_set(_tool_config, '{headers}', _headers, true);
        end if;

        if _tool_secret <> '{}'::jsonb then
          _next := jsonb_set(
            jsonb_set(_next, '{tools}', coalesce(_next -> 'tools', '{}'::jsonb), true),
            array['tools', _tool_key], _tool_secret, true
          );
        end if;

        _tools := jsonb_set(_tools, array[_i::text], jsonb_set(_tool, '{config}', _tool_config, true), true);
      end loop;

      _extra := jsonb_set(_extra, '{tools}', _tools, true);
    else
      _next := _next - 'tools';
    end if;
  end if;

  new.extra := _extra;

  -- Persist. An empty document is a deleted row, so a fully revoked secret
  -- leaves no trace.
  if _next = '{}'::jsonb then
    delete from public.secrets s
    where s.organization_id = _org_id
      and s.scope = _scope
      and s.ref = _ref;
  else
    insert into public.secrets (organization_id, scope, ref, service, address, agent_id, value)
    values (_org_id, _scope, _ref, _service, _address, _agent_id, _next)
    on conflict (organization_id, scope, ref)
    do update set value = excluded.value;
  end if;

  return new;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.jsonb_deep_set(target jsonb, path text[], value jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 IMMUTABLE
 SET search_path TO ''
AS $function$
declare
  _i int;
  _prefix text[];
begin
  target := coalesce(target, '{}'::jsonb);

  for _i in 1 .. coalesce(array_length(path, 1), 0) - 1 loop
    _prefix := path[1:_i];

    if jsonb_typeof(target #> _prefix) is distinct from 'object' then
      target := jsonb_set(target, _prefix, '{}'::jsonb, true);
    end if;
  end loop;

  return jsonb_set(target, path, value, true);
end;
$function$
;

grant delete on table "public"."secrets" to "service_role";

grant insert on table "public"."secrets" to "service_role";

grant references on table "public"."secrets" to "service_role";

grant select on table "public"."secrets" to "service_role";

grant trigger on table "public"."secrets" to "service_role";

grant truncate on table "public"."secrets" to "service_role";

grant update on table "public"."secrets" to "service_role";

CREATE TRIGGER z_extract_secrets BEFORE INSERT OR UPDATE ON public.agents FOR EACH ROW WHEN ((new.extra IS NOT NULL)) EXECUTE FUNCTION public.extract_secrets();

CREATE TRIGGER z_extract_secrets BEFORE INSERT OR UPDATE ON public.organizations FOR EACH ROW WHEN ((new.extra IS NOT NULL)) EXECUTE FUNCTION public.extract_secrets();

CREATE TRIGGER z_extract_secrets BEFORE INSERT OR UPDATE ON public.organizations_addresses FOR EACH ROW WHEN ((new.extra IS NOT NULL)) EXECUTE FUNCTION public.extract_secrets();

CREATE TRIGGER set_updated_at BEFORE UPDATE ON public.secrets FOR EACH ROW EXECUTE FUNCTION public.moddatetime('updated_at');



-- Hand-written backfill (DML): move the credentials already stored in
-- `extra` into public.secrets by re-saving every row through the new
-- trigger. `extra = extra` is a no-op for merge_update and enough for
-- z_extract_secrets to see the document. The webhook trigger is held back
-- while it runs: every one of these rows would otherwise POST an "update"
-- event that changes nothing an integrator cares about.
alter table public.organizations_addresses disable trigger z_notify_webhook_organizations_addresses;
update public.organizations_addresses set extra = extra where extra is not null;
alter table public.organizations_addresses enable trigger z_notify_webhook_organizations_addresses;

update public.agents set extra = extra where extra is not null;
update public.organizations set extra = extra where extra is not null;

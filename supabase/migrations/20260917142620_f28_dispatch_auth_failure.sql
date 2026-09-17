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

  -- F28: the dispatcher marks an account whose token Meta rejected (code 190)
  -- and stops calling Meta with it. A different token — re-onboarding, a
  -- refresh, a manual fix, or its removal — is what lifts that mark, in the
  -- same write. Writing the mask back leaves the token, and the mark, as is.
  if tg_table_name = 'organizations_addresses'
     and (_next -> 'access_token') is distinct from (coalesce(_stored, '{}'::jsonb) -> 'access_token') then
    _extra := _extra - 'dispatch_auth_failure';
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



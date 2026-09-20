-- H4 — what may be SAVED into organizations.extra.attention.
--
-- Failure scenario: the defaults of A6 are applied on READ
-- (public.attention_config), and nothing looked at what was written. The UI
-- validates a schedule before saving it (frontend/src/utils/businessHours.ts),
-- but an API key writes straight to PostgREST and skips that screen entirely,
-- and `extra` is a free-form jsonb bag with no constraint on it.
--
-- So an owner's key could store a Wednesday that closes before it opens, or a
-- negative wait, and nothing would complain until the sweeps read it: the
-- window would contribute negative minutes to a wait, and a contact who was
-- promised a person would be told they were late — or never told at all.
-- `attention_business_minutes` cannot defend itself here, because by the time
-- it runs the nonsense is already the organization's configuration.
--
-- Written as a trigger and not a CHECK because `extra` arrives as a JSON merge
-- patch (merge_update): only the merged result is worth validating, and a
-- CHECK cannot see it.
begin;
select plan(24);

-- ---------------------------------------------------------------------------
-- The two the spec asked for, by name.
-- ---------------------------------------------------------------------------

select throws_ok(
  $$update public.organizations
    set extra = '{"attention": {"business_hours": {"wed": [["19:00", "09:00"]]}}}'::jsonb
    where id = tests.id('org_a')$$,
  'PT422',
  null,
  'a window that closes before it opens is refused'
);

select throws_ok(
  $$update public.organizations
    set extra = '{"attention": {"human_wait_minutes": -1}}'::jsonb
    where id = tests.id('org_a')$$,
  'PT422',
  null,
  'a negative wait is refused'
);

-- The one that is not a typo but a trap. `attention_config` is
-- `defaults || extra->'attention'`, and jsonb's `||` with a non-object does
-- not fail: it builds an ARRAY. Every key of the config then reads NULL, and
-- the guard of sweep_awaiting_human is `continue when _waited < wait` — a
-- comparison against NULL, which is not true, so the sweep does NOT skip.
-- One bad write and every escalated conversation is treated as overdue at
-- once. Verified against this database before writing the validator.
-- Reached by INSERT and not by UPDATE, which is worth being explicit about:
-- `set_extra` runs merge_update on UPDATE only, and a JSON merge patch treats
-- null as "remove this key", so an UPDATE can never store one. An INSERT has
-- no merge and stores `extra` verbatim — and any authenticated user may
-- insert an organization («users can create orgs» is `with check (true)`).
select throws_ok(
  $$insert into public.organizations (name, extra)
    values ('trampa', '{"attention": null}'::jsonb)$$,
  'PT422',
  null,
  'a null attention is refused on insert: it would read back as an array of nulls'
);

select lives_ok(
  $$update public.organizations set extra = '{"attention": null}'::jsonb
    where id = tests.id('org_a')$$,
  'the same null on update is not refused but ERASED, by the merge patch'
);

select is(
  (select extra -> 'attention' from public.organizations
   where id = tests.id('org_a')),
  null,
  'and what it erased is the key itself, so nothing reads an array'
);

select throws_ok(
  $$update public.organizations set extra = '{"attention": "si"}'::jsonb
    where id = tests.id('org_a')$$,
  'PT422',
  null,
  'an attention that is not an object is refused, for the same reason'
);

-- ---------------------------------------------------------------------------
-- The rest of the vocabulary the UI already refuses, so the two sides agree.
-- ---------------------------------------------------------------------------

select throws_ok(
  $$update public.organizations
    set extra = '{"attention": {"business_hours": {"wed": [["09:00", "09:00"]]}}}'::jsonb
    where id = tests.id('org_a')$$,
  'PT422',
  null,
  'a window of zero length is refused: "closes" is exclusive'
);

select throws_ok(
  $$update public.organizations
    set extra = '{"attention": {"business_hours": {"wed": [["09:00", "14:00"], ["13:00", "19:00"]]}}}'::jsonb
    where id = tests.id('org_a')$$,
  'PT422',
  null,
  'two windows over the same hour are refused'
);

select throws_ok(
  $$update public.organizations
    set extra = '{"attention": {"business_hours": {"wed": [["9:00", "19:00"]]}}}'::jsonb
    where id = tests.id('org_a')$$,
  'PT422',
  null,
  'a time that is not HH:MM is refused'
);

select throws_ok(
  $$update public.organizations
    set extra = '{"attention": {"business_hours": {"wed": [["09:00", "25:00"]]}}}'::jsonb
    where id = tests.id('org_a')$$,
  'PT422',
  null,
  'an hour past the end of the day is refused'
);

select throws_ok(
  $$update public.organizations
    set extra = '{"attention": {"business_hours": {"miercoles": [["09:00", "19:00"]]}}}'::jsonb
    where id = tests.id('org_a')$$,
  'PT422',
  null,
  'a day this schema does not name is refused, not ignored'
);

select throws_ok(
  $$update public.organizations
    set extra = '{"attention": {"business_hours": {"wed": [["09:00"]]}}}'::jsonb
    where id = tests.id('org_a')$$,
  'PT422',
  null,
  'a window that is not a pair is refused'
);

select throws_ok(
  $$update public.organizations
    set extra = '{"attention": {"business_hours": {"wed": "09:00-19:00"}}}'::jsonb
    where id = tests.id('org_a')$$,
  'PT422',
  null,
  'a day that is not a list of windows is refused'
);

select throws_ok(
  $$update public.organizations
    set extra = '{"attention": {"ai_assignment_ttl_days": -1}}'::jsonb
    where id = tests.id('org_a')$$,
  'PT422',
  null,
  'a negative AI assignment TTL is refused'
);

select throws_ok(
  $$update public.organizations
    set extra = '{"attention": {"human_assignment_ttl_hours": -1}}'::jsonb
    where id = tests.id('org_a')$$,
  'PT422',
  null,
  'a negative human assignment TTL is refused'
);

select throws_ok(
  $$update public.organizations
    set extra = '{"attention": {"on_human_wait_timeout": "call_the_police"}}'::jsonb
    where id = tests.id('org_a')$$,
  'PT422',
  null,
  'a timeout action that does not exist is refused'
);

select throws_ok(
  $$update public.organizations
    set extra = '{"attention": {"timezone": "Mars/Olympus_Mons"}}'::jsonb
    where id = tests.id('org_a')$$,
  'PT422',
  null,
  'a timezone the server cannot resolve is refused'
);

-- ---------------------------------------------------------------------------
-- Controls. A validator that refuses everything would pass all of the above,
-- so each legal spelling this schema relies on is pinned too.
-- ---------------------------------------------------------------------------

select lives_ok(
  $$update public.organizations
    set extra = '{"attention": {"business_hours": {"wed": [["09:00", "13:00"], ["15:00", "19:00"]]}}}'::jsonb
    where id = tests.id('org_a')$$,
  'a lunch break — two windows in one day — still saves'
);

select lives_ok(
  $$update public.organizations
    set extra = '{"attention": {"business_hours": {"sun": [["00:00", "24:00"]]}}}'::jsonb
    where id = tests.id('org_a')$$,
  '24:00 still saves: it is how this schema spells "until midnight"'
);

select lives_ok(
  $$update public.organizations
    set extra = '{"attention": {"business_hours": {"sat": []}}}'::jsonb
    where id = tests.id('org_a')$$,
  'a day with no windows still saves: that is "closed"'
);

select lives_ok(
  $$update public.organizations
    set extra = '{"attention": {"human_assignment_ttl_hours": 0}}'::jsonb
    where id = tests.id('org_a')$$,
  'a TTL of 0 still saves: it means "never expires", not "invalid"'
);

select lives_ok(
  $$update public.organizations
    set extra = '{"attention": {"business_hours": null}}'::jsonb
    where id = tests.id('org_a')$$,
  'an explicit null schedule still saves: it is how 24/7 is spelled'
);

select lives_ok(
  $$update public.organizations set extra = '{"brand_voice": "cercano"}'::jsonb
    where id = tests.id('org_a')$$,
  'an organization setting that is not attention is not this trigger''s business'
);

-- ---------------------------------------------------------------------------
-- The writer this exists for. The UI screen cannot be skipped by a member,
-- but an API key never sees it.
-- ---------------------------------------------------------------------------

select tests.authenticate_with_api_key(tests.val('key_a_owner'));

select throws_ok(
  $$update public.organizations
    set extra = '{"attention": {"business_hours": {"wed": [["19:00", "09:00"]]}}}'::jsonb
    where id = tests.id('org_a')$$,
  'PT422',
  null,
  'an owner API key is refused the same schedule, having skipped the screen'
);

select * from finish();
rollback;

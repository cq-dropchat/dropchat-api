-- H4 — how long an assignment lasts, and what "within business hours" means.
--
-- Failure scenario: a conversation one contact started stays pinned to one
-- agent for ever (conversations have no end), a person who takes one and goes
-- on holiday holds it for ever, and an escalation nobody answers waits for
-- ever — while the contact, who was told a person would come, sees nothing.
--
-- The waiting is measured in BUSINESS minutes, because a handover at 18:59 on
-- a Friday is not late at 19:29 on a Friday. That arithmetic is what the
-- first half of this file pins: midnight crossings, weekends, a day with no
-- hours at all, and Chile's daylight saving change, where one day has 23
-- hours and another 25.
begin;
select plan(41);

-- ---------------------------------------------------------------------------
-- Defaults (A6, with 24/7 as the unconfigured schedule).
-- ---------------------------------------------------------------------------

select is(
  public.attention_config('{}'::jsonb) ->> 'timezone',
  'America/Santiago',
  'the default timezone is the market''s'
);

select is(
  (public.attention_config('{}'::jsonb) ->> 'ai_assignment_ttl_days')::int,
  14,
  'an AI assignment lasts 14 days without the contact'
);

select is(
  (public.attention_config('{}'::jsonb) ->> 'human_assignment_ttl_hours')::int,
  72,
  'a human assignment lasts 72 hours without them'
);

select is(
  (public.attention_config('{}'::jsonb) ->> 'human_wait_minutes')::int,
  30,
  'a contact waits 30 business minutes for a person'
);

select is(
  public.attention_config('{}'::jsonb) ->> 'on_human_wait_timeout',
  'notify_customer',
  'and then is told, rather than handed back to the AI'
);

select is(
  (public.attention_config('{}'::jsonb) ->> 'auto_takeover')::boolean,
  true,
  'answering by hand takes the conversation (A2)'
);

select is(
  public.attention_config('{}'::jsonb) -> 'business_hours',
  'null'::jsonb,
  'an organization that configured no schedule has none'
);

select is(
  public.attention_config(
    '{"attention": {"human_wait_minutes": 5, "timezone": "UTC"}}'::jsonb
  ) ->> 'human_wait_minutes',
  '5',
  'what the organization did configure wins'
);

-- ---------------------------------------------------------------------------
-- Business minutes.
-- ---------------------------------------------------------------------------

create function pg_temp.cfg(_hours jsonb default null) returns jsonb
language sql as $$
  select public.attention_config(
    jsonb_build_object(
      'attention',
      jsonb_build_object('timezone', 'America/Santiago')
        || case when _hours is null then '{}'::jsonb
           else jsonb_build_object('business_hours', _hours) end
    )
  );
$$;

-- Monday to Friday, 09:00–19:00, Santiago.
create function pg_temp.weekdays() returns jsonb language sql as $$
  select jsonb_build_object(
    'mon', jsonb_build_array(jsonb_build_array('09:00', '19:00')),
    'tue', jsonb_build_array(jsonb_build_array('09:00', '19:00')),
    'wed', jsonb_build_array(jsonb_build_array('09:00', '19:00')),
    'thu', jsonb_build_array(jsonb_build_array('09:00', '19:00')),
    'fri', jsonb_build_array(jsonb_build_array('09:00', '19:00')),
    'sat', '[]'::jsonb,
    'sun', '[]'::jsonb
  );
$$;

-- No schedule at all: every minute counts, which is what an organization
-- that has not configured one gets.
select is(
  public.attention_business_minutes(
    pg_temp.cfg(),
    ('2026-09-19 12:00:00'::timestamp at time zone 'America/Santiago'),
    ('2026-09-19 12:45:00'::timestamp at time zone 'America/Santiago')
  ),
  45::numeric,
  '24/7: every minute is a business minute'
);

select is(
  public.attention_business_minutes(
    pg_temp.cfg(pg_temp.weekdays()),
    ('2026-09-16 10:00:00'::timestamp at time zone 'America/Santiago'),
    ('2026-09-16 10:30:00'::timestamp at time zone 'America/Santiago')
  ),
  30::numeric,
  'half an hour inside the working day is half an hour'
);

-- 18:40 Wednesday → 09:10 Thursday: 20 minutes before closing, 10 after
-- opening, and the night in between does not count.
select is(
  public.attention_business_minutes(
    pg_temp.cfg(pg_temp.weekdays()),
    ('2026-09-16 18:40:00'::timestamp at time zone 'America/Santiago'),
    ('2026-09-17 09:10:00'::timestamp at time zone 'America/Santiago')
  ),
  30::numeric,
  'a wait that crosses midnight only counts the open hours at each end'
);

-- Friday 18:59 → Monday 09:01, the case that decides whether a weekend
-- handover looks late.
select is(
  public.attention_business_minutes(
    pg_temp.cfg(pg_temp.weekdays()),
    ('2026-09-18 18:59:00'::timestamp at time zone 'America/Santiago'),
    ('2026-09-21 09:01:00'::timestamp at time zone 'America/Santiago')
  ),
  2::numeric,
  'a weekend counts as two minutes: one Friday, one Monday'
);

select is(
  public.attention_business_minutes(
    pg_temp.cfg(pg_temp.weekdays()),
    ('2026-09-19 10:00:00'::timestamp at time zone 'America/Santiago'),
    ('2026-09-19 18:00:00'::timestamp at time zone 'America/Santiago')
  ),
  0::numeric,
  'a day with no hours contributes nothing'
);

-- Two windows in a day (a lunch break): the break does not count.
select is(
  public.attention_business_minutes(
    public.attention_config(
      jsonb_build_object('attention', jsonb_build_object(
        'timezone', 'America/Santiago',
        'business_hours', jsonb_build_object(
          'wed', jsonb_build_array(
            jsonb_build_array('09:00', '13:00'),
            jsonb_build_array('15:00', '19:00')
          )
        )
      ))
    ),
    ('2026-09-16 12:30:00'::timestamp at time zone 'America/Santiago'),
    ('2026-09-16 15:30:00'::timestamp at time zone 'America/Santiago')
  ),
  60::numeric,
  'a lunch break is not business time'
);

-- Chile moves to summer time on the first Saturday of September at 24:00
-- (2026-09-05): that Sunday has 23 hours. A schedule that says 00:00–24:00
-- on Sunday therefore has 23 business hours that day, not 24.
select is(
  public.attention_business_minutes(
    public.attention_config(
      jsonb_build_object('attention', jsonb_build_object(
        'timezone', 'America/Santiago',
        'business_hours', jsonb_build_object(
          'sun', jsonb_build_array(jsonb_build_array('00:00', '24:00'))
        )
      ))
    ),
    '2026-09-06 00:00:00-04'::timestamptz,
    '2026-09-07 00:00:00-03'::timestamptz
  ),
  (23 * 60)::numeric,
  'the day Chile springs forward is 23 hours long, and so is its schedule'
);

-- ---------------------------------------------------------------------------
-- Open now, and the next opening — what the agent tells the contact.
-- ---------------------------------------------------------------------------

select ok(
  public.attention_is_open(pg_temp.cfg(), now()),
  '24/7 is always open'
);

select ok(
  public.attention_is_open(
    pg_temp.cfg(pg_temp.weekdays()), ('2026-09-16 10:00:00'::timestamp at time zone 'America/Santiago')
  ),
  'Wednesday at 10:00 is open'
);

select ok(
  not public.attention_is_open(
    pg_temp.cfg(pg_temp.weekdays()), ('2026-09-19 10:00:00'::timestamp at time zone 'America/Santiago')
  ),
  'Saturday at 10:00 is not'
);

select is(
  public.attention_next_opening(
    pg_temp.cfg(pg_temp.weekdays()),
    ('2026-09-19 10:00:00'::timestamp at time zone 'America/Santiago')
  ),
  ('2026-09-21 09:00:00'::timestamp at time zone 'America/Santiago'),
  'from Saturday, the next opening is Monday at 09:00'
);

select is(
  public.attention_next_opening(pg_temp.cfg(), now()),
  null,
  '24/7 has no next opening: it never closed'
);

-- ---------------------------------------------------------------------------
-- The human assignment expiry.
--
-- Measured in messages, not in the assignment's age: somebody who answers
-- every day keeps the conversation.
-- ---------------------------------------------------------------------------

-- 24/7, so the arithmetic above is not what these cases are about.
update public.organizations
set extra = '{"attention": {"human_assignment_ttl_hours": 72}}'::jsonb
where id = tests.id('org_a');

select public.set_conversation_assignment(
  tests.id('conv_a1'), tests.id('agent_alice'), false, null,
  '{"cause": "manual"}'::jsonb
);

select set_config('app.assignment_writer', 'off', true);

select is(
  public.expire_human_assignments(),
  0,
  'a fresh human assignment is not touched'
);

-- Four days ago, with nothing sent since.
-- Ageing the assignment means writing a guarded column, so the flag the gate
-- sets is set here too. What is under test is the sweep, not the guard (that
-- is 26_conversation_assignment).
select set_config('app.assignment_writer', 'on', true);
update public.conversations
set assigned_at = now() - interval '4 days'
where id = tests.id('conv_a1');

select set_config('app.assignment_writer', 'off', true);

select is(
  public.expire_human_assignments(),
  1,
  'a human assignment nobody worked on for longer than the TTL goes back'
);

select is(
  (select assigned_agent_id from public.conversations where id = tests.id('conv_a1')),
  null,
  'and the conversation is free to be routed again'
);

select is(
  (
    select count(*)::int
    from public.messages
    where conversation_id = tests.id('conv_a1')
      and content -> 'data' ->> 'cause' = 'expiry'
  ),
  1,
  'with a note that says it expired'
);

select set_config('app.assignment_writer', 'off', true);

select is(
  public.expire_human_assignments(),
  0,
  'and a second run has nothing left to do'
);

-- Somebody who IS working on it keeps it, however old the assignment.
select public.set_conversation_assignment(
  tests.id('conv_a1'), tests.id('agent_alice'), false, null,
  '{"cause": "manual"}'::jsonb
);

-- Ageing the assignment means writing a guarded column, so the flag the gate
-- sets is set here too. What is under test is the sweep, not the guard (that
-- is 26_conversation_assignment).
select set_config('app.assignment_writer', 'on', true);
update public.conversations
set assigned_at = now() - interval '10 days'
where id = tests.id('conv_a1');

insert into public.messages (
  organization_id, conversation_id, service, organization_address,
  conversation_address, agent_id, timestamp, status, content
)
values (
  tests.id('org_a'), tests.id('conv_a1'), 'whatsapp', tests.val('wa_a'),
  tests.val('contact_a1'), tests.id('agent_alice'), now() - interval '1 hour',
  '{}'::jsonb,
  '{"version": "1", "type": "text", "kind": "text", "text": "sigo yo"}'::jsonb
);

select set_config('app.assignment_writer', 'off', true);

select is(
  public.expire_human_assignments(),
  0,
  'a person who answered an hour ago keeps the conversation'
);

-- A TTL of 0: never. Not null — `extra` is a merge patch, where null deletes
-- the key and the default comes back.
update public.organizations
set extra = '{"attention": {"human_assignment_ttl_hours": 0}}'::jsonb
where id = tests.id('org_a');

-- Ageing the assignment means writing a guarded column, so the flag the gate
-- sets is set here too. What is under test is the sweep, not the guard (that
-- is 26_conversation_assignment).
select set_config('app.assignment_writer', 'on', true);
update public.conversations
set assigned_at = now() - interval '100 days'
where id = tests.id('conv_a1');

update public.messages
set timestamp = now() - interval '99 days'
where conversation_id = tests.id('conv_a1')
  and agent_id = tests.id('agent_alice')
  and sender_address is null;

select set_config('app.assignment_writer', 'off', true);

select is(
  public.expire_human_assignments(),
  0,
  'a TTL of 0 means a person holds it until they let go'
);

-- ---------------------------------------------------------------------------
-- The wait for a person.
-- ---------------------------------------------------------------------------

-- An inbound message just now, so the channel's 24-hour window is open.
insert into public.messages (
  organization_id, conversation_id, service, organization_address,
  conversation_address, sender_address, timestamp, status, content
)
values (
  tests.id('org_a'), tests.id('conv_a2'), 'whatsapp', tests.val('wa_a'),
  tests.val('contact_a2'), tests.val('contact_a2'), now(),
  '{}'::jsonb,
  '{"version": "1", "type": "text", "kind": "text", "text": "hola?"}'::jsonb
);

update public.organizations
set extra = '{"attention": {"human_wait_minutes": 30}}'::jsonb
where id = tests.id('org_a');

select public.set_conversation_assignment(
  tests.id('conv_a2'), null, true, tests.id('agent_robot_a'),
  '{"cause": "escalation", "category": "reclamo"}'::jsonb
);

select set_config('app.assignment_writer', 'off', true);

select is(
  public.sweep_awaiting_human(),
  0,
  'a wait that has not passed the limit is left alone'
);

-- Ageing the assignment means writing a guarded column, so the flag the gate
-- sets is set here too. What is under test is the sweep, not the guard (that
-- is 26_conversation_assignment).
select set_config('app.assignment_writer', 'on', true);
update public.conversations
set awaiting_human_since = now() - interval '45 minutes'
where id = tests.id('conv_a2');

select set_config('app.assignment_writer', 'off', true);

select is(
  public.sweep_awaiting_human(),
  1,
  'a wait past the limit tells the contact'
);

select is(
  (
    select count(*)::int
    from public.messages
    where conversation_id = tests.id('conv_a2')
      and sender_address is null
      and content ->> 'text' = (
        public.attention_config('{}'::jsonb) ->> 'human_wait_message'
      )
  ),
  1,
  'with the organization''s waiting message, sent as a normal outgoing row'
);

select set_config('app.assignment_writer', 'off', true);

select is(
  public.sweep_awaiting_human(),
  0,
  'and only once, however many times the sweep runs'
);

-- Outside business hours the clock does not run.
update public.organizations
set extra = jsonb_build_object('attention', jsonb_build_object(
  'human_wait_minutes', 30,
  'timezone', 'America/Santiago',
  'business_hours', jsonb_build_object('mon', '[]'::jsonb, 'tue', '[]'::jsonb,
    'wed', '[]'::jsonb, 'thu', '[]'::jsonb, 'fri', '[]'::jsonb,
    'sat', '[]'::jsonb, 'sun', '[]'::jsonb)
))
where id = tests.id('org_a');

-- Ageing the assignment means writing a guarded column, so the flag the gate
-- sets is set here too. What is under test is the sweep, not the guard (that
-- is 26_conversation_assignment).
select set_config('app.assignment_writer', 'on', true);
update public.conversations
set awaiting_human_since = now() - interval '10 days',
    extra = coalesce(extra, '{}'::jsonb) - 'human_wait_notified_at'
where id = tests.id('conv_a2');

select set_config('app.assignment_writer', 'off', true);

select is(
  public.sweep_awaiting_human(),
  0,
  'a closed organization is never late: no business minute ever passes'
);

-- The channel's window closed: the message would fail at the dispatcher.
--
-- `business_hours: null` and not an omitted key: `extra` is a merge patch, so
-- leaving it out would keep the closed schedule set just above.
update public.organizations
set extra = '{"attention": {"human_wait_minutes": 30, "business_hours": null}}'::jsonb
where id = tests.id('org_a');

update public.messages
set timestamp = now() - interval '30 hours'
where conversation_id = tests.id('conv_a2')
  and sender_address is not null;

select set_config('app.assignment_writer', 'off', true);

select is(
  public.sweep_awaiting_human(),
  0,
  'nothing is sent to a contact whose 24-hour window has closed'
);

-- return_to_ai hands it back instead, and clears the mark.
update public.organizations
set extra = '{"attention": {"human_wait_minutes": 30, "on_human_wait_timeout": "return_to_ai"}}'::jsonb
where id = tests.id('org_a');

update public.conversations
set extra = coalesce(extra, '{}'::jsonb)
  || '{"human_wait_notified_at": "2026-01-01T00:00:00Z"}'::jsonb
where id = tests.id('conv_a2');

select set_config('app.assignment_writer', 'off', true);

select is(
  public.sweep_awaiting_human(),
  1,
  'with return_to_ai, the conversation goes back to routing'
);

select ok(
  (
    select awaiting_human_since is null
      and not (coalesce(extra, '{}'::jsonb) ? 'human_wait_notified_at')
    from public.conversations
    where id = tests.id('conv_a2')
  ),
  'the wait and its mark are both gone'
);

select set_config('app.assignment_writer', 'off', true);

select is(
  public.sweep_awaiting_human(),
  0,
  'and the sweep has nothing left to do'
);

-- ---------------------------------------------------------------------------
-- Both sweeps are cron jobs, and nobody else's to call.
-- ---------------------------------------------------------------------------

select is(
  (select schedule from cron.job where jobname = 'sweep-awaiting-human'),
  '* * * * *',
  'the wait sweep runs every minute — it is what the contact waits on'
);

select is(
  (select schedule from cron.job where jobname = 'expire-human-assignments'),
  '*/15 * * * *',
  'the human expiry runs every fifteen minutes'
);

-- ---------------------------------------------------------------------------
-- H5 — who gets told, and who decides that.
--
-- Without email (A7 was answered "no email in v1"), the notice is the app's:
-- the conversation row travels by Realtime, where RLS already decides who
-- sees it, and the member's own preference decides whether it interrupts
-- them. What has to hold here is that the preference is THEIRS: an admin
-- cannot decide what interrupts a colleague.
-- ---------------------------------------------------------------------------

select tests.authenticate_as('amber@test.local');

select lives_ok(
  format(
    $$update public.agents
      set extra = '{"notifications": {"escalation": false}}'::jsonb
      where id = %L$$,
    tests.id('agent_amber')
  ),
  'a member turns their own escalation notices off'
);

select is(
  (
    select (extra -> 'notifications' ->> 'escalation')::boolean
    from public.agents where id = tests.id('agent_amber')
  ),
  false,
  'and it is stored'
);

-- Alice is the owner, so she CAN write amber's row (the admin policy) — what
-- she cannot do is pass herself off as amber, which the identity guard
-- covers. The preference being per-member is the product rule; this pins
-- that a plain member cannot reach anybody else's.
select tests.clear_authentication();
select tests.authenticate_as('amber@test.local');

-- RLS hides the row from the UPDATE rather than raising, so what says
-- "refused" is that nothing changed.
update public.agents
set extra = '{"notifications": {"escalation": false}}'::jsonb
where id = tests.id('agent_alice');

select is(
  (
    select extra -> 'notifications' ->> 'escalation'
    from public.agents where id = tests.id('agent_alice')
  ),
  null,
  'a member cannot change another member''s preference'
);

select tests.clear_authentication();

select * from finish();
rollback;

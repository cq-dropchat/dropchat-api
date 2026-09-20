
create type public.service as enum (
  'whatsapp',
  'instagram',
  'local',
  'slack',
  'discord',
  'teams',
  'whatsapp-web',
  -- S1: the simulator's own channel. A value rather than a flag because
  -- everything worth exercising ('is there a welcome message?', 'may the
  -- agent escalate?', 'is the channel window open?') is already a question
  -- about `service` — so a test conversation walks the real path instead of
  -- adding `or is_a_drill` to every one of those conditions.
  --
  -- Never leaves the building: no dispatcher, no read receipt, no webhook.
  'sandbox'
);

create type public.webhook_operation as enum ('insert', 'update');

create type public.webhook_table as enum (
  'messages',
  'conversations',
  'organizations_addresses',
  'contacts_addresses',
  'logs'
);

create type public.role as enum ('owner', 'admin', 'member');

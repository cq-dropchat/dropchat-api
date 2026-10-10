-- Armed inserts execute real billing/quota/message/queue triggers.
\set tenant random(1, :tenants)
begin;
insert into public.messages(organization_id,service,organization_address,conversation_address,agent_id,content,status)
values (('e4000000-0000-4000-8000-'||lpad(:tenant::text,12,'0'))::uuid,'whatsapp','capacity-'||:tenant,'peer',
 ('e4000000-0000-4000-8001-'||lpad(:tenant::text,12,'0'))::uuid,
 '{"version":"1","type":"text","kind":"text","text":"capacity"}',jsonb_build_object('pending',now()));
commit;

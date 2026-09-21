-- T2: los niveles de modelo. DDL generado con `db diff`, sin tocar.
--
-- Renombrada a mano de 20260921070725 a 20260921126000: `db diff` fecha con la
-- hora real, y las migraciones de T3 y T4 ya desplegadas están fechadas al
-- mediodía, así que habría quedado ANTES de migraciones ya aplicadas — que es
-- lo que el CLI rechaza al desplegar.
--
-- Las tres filas de referencia van al final, escritas a mano: son DML, que es
-- uno de los casos que `db diff` no produce, y sin ellas la tabla existe vacía
-- y ningún agente puede elegir un nivel.


  create table "public"."model_tiers" (
    "slug" text not null,
    "name" text not null,
    "description" text,
    "provider" text not null,
    "model" text not null,
    "protocol" text not null default 'chat_completions'::text,
    "supports_forced_tools" boolean not null default true,
    "sort_order" integer not null default 0,
    "created_at" timestamp with time zone not null default now(),
    "updated_at" timestamp with time zone not null default now()
      );


alter table "public"."model_tiers" enable row level security;

CREATE UNIQUE INDEX model_tiers_pkey ON public.model_tiers USING btree (slug);

alter table "public"."model_tiers" add constraint "model_tiers_pkey" PRIMARY KEY using index "model_tiers_pkey";

alter table "public"."model_tiers" add constraint "model_tiers_protocol_known" CHECK ((protocol = ANY (ARRAY['chat_completions'::text, 'responses'::text]))) not valid;

alter table "public"."model_tiers" validate constraint "model_tiers_protocol_known";

alter table "public"."model_tiers" add constraint "model_tiers_protocol_supported" CHECK (((protocol = 'chat_completions'::text) OR (provider = ANY (ARRAY['openai'::text, 'groq'::text])))) not valid;

alter table "public"."model_tiers" validate constraint "model_tiers_protocol_supported";

alter table "public"."model_tiers" add constraint "model_tiers_provider_known" CHECK ((provider = ANY (ARRAY['openai'::text, 'anthropic'::text, 'google'::text, 'groq'::text]))) not valid;

alter table "public"."model_tiers" validate constraint "model_tiers_provider_known";

grant delete on table "public"."model_tiers" to "anon";

grant insert on table "public"."model_tiers" to "anon";

grant references on table "public"."model_tiers" to "anon";

grant select on table "public"."model_tiers" to "anon";

grant trigger on table "public"."model_tiers" to "anon";

grant update on table "public"."model_tiers" to "anon";

grant delete on table "public"."model_tiers" to "authenticated";

grant insert on table "public"."model_tiers" to "authenticated";

grant references on table "public"."model_tiers" to "authenticated";

grant select on table "public"."model_tiers" to "authenticated";

grant trigger on table "public"."model_tiers" to "authenticated";

grant update on table "public"."model_tiers" to "authenticated";

grant delete on table "public"."model_tiers" to "service_role";

grant insert on table "public"."model_tiers" to "service_role";

grant references on table "public"."model_tiers" to "service_role";

grant select on table "public"."model_tiers" to "service_role";

grant trigger on table "public"."model_tiers" to "service_role";

grant truncate on table "public"."model_tiers" to "service_role";

grant update on table "public"."model_tiers" to "service_role";


  create policy "anyone may read the tiers"
  on "public"."model_tiers"
  as permissive
  for select
  to authenticated, anon
using (true);



  create policy "platform admins manage the tiers"
  on "public"."model_tiers"
  as permissive
  for all
  to authenticated
using (rls.is_platform_admin())
with check (rls.is_platform_admin());


CREATE TRIGGER set_updated_at BEFORE UPDATE ON public.model_tiers FOR EACH ROW EXECUTE FUNCTION public.moddatetime('updated_at');



-- Lo que `db diff` no trajo la primera vez, igual que en T4: los privilegios
-- por defecto de Supabase incluyen TRUNCATE, y el diff sólo emite los grants
-- que encuentra en la base sombra, no los revokes de lo que la tabla todavía
-- no tenía. Sin estas dos líneas, `db diff` después de un `db reset` vuelve a
-- pedirlas — que es exactamente como se encontraron.
revoke truncate on table public.model_tiers from anon;
revoke truncate on table public.model_tiers from authenticated;

-- ---------------------------------------------------------------------------
-- Los tres niveles.
--
-- Cada uno apunta a un (provider, model) con precio en `billing.costs` — una
-- llamada facturable sin precio LANZA, no degrada (`38_model_tiers`). Los
-- precios al 21/09/2026, por millón de tokens de entrada/salida:
--
--   rápido       groq/openai/gpt-oss-20b    0.075 / 0.30
--   equilibrado  openai/gpt-5-mini          0.25  / 2.00
--   avanzado     anthropic/claude-sonnet-5  2.00  / 10.00
--
-- «Avanzado» es sonnet-5 y no sonnet-4-6: cuesta menos (2/10 contra 3/15) y es
-- más nuevo. 4-6 sigue con precio, así que ningún agente que ya lo nombre se
-- rompe.
--
-- Ninguno es un modelo insignia, y eso es una decisión: lo que hace el agente
-- —seguir instrucciones, contestar corto en español, extraer un dato, llamar
-- una herramienta— no es trabajo de razonamiento, y el costo por pedido se
-- mueve un orden de magnitud. Si conviene uno más caro es una pregunta sobre
-- LLAMADO A HERRAMIENTAS, y es empírica: se mide en el simulador (S1).
--
-- `on conflict do nothing`: la migración corre también en `db reset`, y estas
-- filas son configuración que un superadmin puede haber cambiado desde que se
-- aplicó. No las pisa.
insert into public.model_tiers
  (slug, name, description, provider, model, protocol, supports_forced_tools, sort_order)
values
  ('rapido', 'Rápido',
   'El más barato y el más veloz. Responde bien preguntas directas.',
   'groq', 'openai/gpt-oss-20b', 'chat_completions', true, 1),
  ('equilibrado', 'Equilibrado',
   'El que conviene para la mayoría de las tiendas.',
   'openai', 'gpt-5-mini', 'chat_completions', true, 2),
  ('avanzado', 'Avanzado',
   'Para conversaciones largas o catálogos complicados. Cuesta más.',
   'anthropic', 'claude-sonnet-5', 'chat_completions', true, 3)
on conflict (slug) do nothing;

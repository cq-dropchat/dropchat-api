
  create table "public"."agent_template_versions" (
    "template_id" uuid not null,
    "version" integer not null,
    "config" jsonb not null,
    "config_hash" text not null,
    "changelog" text,
    "published_by" uuid,
    "published_at" timestamp with time zone not null default now(),
    "retired_at" timestamp with time zone
      );


alter table "public"."agent_template_versions" enable row level security;


  create table "public"."agent_templates" (
    "id" uuid not null default gen_random_uuid(),
    "slug" text not null,
    "name" text not null,
    "description" text,
    "category" text,
    "source_agent_id" uuid,
    "archived_at" timestamp with time zone,
    "created_at" timestamp with time zone not null default now(),
    "updated_at" timestamp with time zone not null default now()
      );


alter table "public"."agent_templates" enable row level security;


  create table "public"."platform_settings" (
    "id" boolean not null default true,
    "template_org_id" uuid,
    "updated_at" timestamp with time zone not null default now()
      );


alter table "public"."platform_settings" enable row level security;

CREATE UNIQUE INDEX agent_template_versions_pkey ON public.agent_template_versions USING btree (template_id, version);

CREATE UNIQUE INDEX agent_templates_pkey ON public.agent_templates USING btree (id);

CREATE UNIQUE INDEX agent_templates_slug_key ON public.agent_templates USING btree (slug);

CREATE UNIQUE INDEX platform_settings_pkey ON public.platform_settings USING btree (id);

alter table "public"."agent_template_versions" add constraint "agent_template_versions_pkey" PRIMARY KEY using index "agent_template_versions_pkey";

alter table "public"."agent_templates" add constraint "agent_templates_pkey" PRIMARY KEY using index "agent_templates_pkey";

alter table "public"."platform_settings" add constraint "platform_settings_pkey" PRIMARY KEY using index "platform_settings_pkey";

alter table "public"."agent_template_versions" add constraint "agent_template_versions_published_by_fkey" FOREIGN KEY (published_by) REFERENCES auth.users(id) ON DELETE SET NULL not valid;

alter table "public"."agent_template_versions" validate constraint "agent_template_versions_published_by_fkey";

alter table "public"."agent_template_versions" add constraint "agent_template_versions_template_id_fkey" FOREIGN KEY (template_id) REFERENCES public.agent_templates(id) ON DELETE CASCADE not valid;

alter table "public"."agent_template_versions" validate constraint "agent_template_versions_template_id_fkey";

alter table "public"."agent_template_versions" add constraint "agent_template_versions_version_check" CHECK ((version > 0)) not valid;

alter table "public"."agent_template_versions" validate constraint "agent_template_versions_version_check";

alter table "public"."agent_templates" add constraint "agent_templates_slug_key" UNIQUE using index "agent_templates_slug_key";

alter table "public"."agent_templates" add constraint "agent_templates_source_agent_id_fkey" FOREIGN KEY (source_agent_id) REFERENCES public.agents(id) ON DELETE SET NULL not valid;

alter table "public"."agent_templates" validate constraint "agent_templates_source_agent_id_fkey";

alter table "public"."platform_settings" add constraint "platform_settings_singleton" CHECK (id) not valid;

alter table "public"."platform_settings" validate constraint "platform_settings_singleton";

alter table "public"."platform_settings" add constraint "platform_settings_template_org_id_fkey" FOREIGN KEY (template_org_id) REFERENCES public.organizations(id) ON DELETE SET NULL not valid;

alter table "public"."platform_settings" validate constraint "platform_settings_template_org_id_fkey";

grant references on table "public"."agent_template_versions" to "anon";

grant select on table "public"."agent_template_versions" to "anon";

grant trigger on table "public"."agent_template_versions" to "anon";

grant references on table "public"."agent_template_versions" to "authenticated";

grant select on table "public"."agent_template_versions" to "authenticated";

grant trigger on table "public"."agent_template_versions" to "authenticated";

grant delete on table "public"."agent_template_versions" to "service_role";

grant insert on table "public"."agent_template_versions" to "service_role";

grant references on table "public"."agent_template_versions" to "service_role";

grant select on table "public"."agent_template_versions" to "service_role";

grant trigger on table "public"."agent_template_versions" to "service_role";

grant truncate on table "public"."agent_template_versions" to "service_role";

grant update on table "public"."agent_template_versions" to "service_role";

grant insert on table "public"."agent_templates" to "anon";

grant references on table "public"."agent_templates" to "anon";

grant select on table "public"."agent_templates" to "anon";

grant trigger on table "public"."agent_templates" to "anon";

grant update on table "public"."agent_templates" to "anon";

grant insert on table "public"."agent_templates" to "authenticated";

grant references on table "public"."agent_templates" to "authenticated";

grant select on table "public"."agent_templates" to "authenticated";

grant trigger on table "public"."agent_templates" to "authenticated";

grant update on table "public"."agent_templates" to "authenticated";

grant delete on table "public"."agent_templates" to "service_role";

grant insert on table "public"."agent_templates" to "service_role";

grant references on table "public"."agent_templates" to "service_role";

grant select on table "public"."agent_templates" to "service_role";

grant trigger on table "public"."agent_templates" to "service_role";

grant truncate on table "public"."agent_templates" to "service_role";

grant update on table "public"."agent_templates" to "service_role";

grant references on table "public"."platform_settings" to "anon";

grant select on table "public"."platform_settings" to "anon";

grant trigger on table "public"."platform_settings" to "anon";

grant references on table "public"."platform_settings" to "authenticated";

grant select on table "public"."platform_settings" to "authenticated";

grant trigger on table "public"."platform_settings" to "authenticated";

grant delete on table "public"."platform_settings" to "service_role";

grant insert on table "public"."platform_settings" to "service_role";

grant references on table "public"."platform_settings" to "service_role";

grant select on table "public"."platform_settings" to "service_role";

grant trigger on table "public"."platform_settings" to "service_role";

grant truncate on table "public"."platform_settings" to "service_role";

grant update on table "public"."platform_settings" to "service_role";


  create policy "members can read published versions"
  on "public"."agent_template_versions"
  as permissive
  for select
  to authenticated
using ((rls.is_platform_admin() OR ((retired_at IS NULL) AND (EXISTS ( SELECT 1
   FROM public.agent_templates t
  WHERE ((t.id = agent_template_versions.template_id) AND (t.archived_at IS NULL)))))));



  create policy "members can read the published catalogue"
  on "public"."agent_templates"
  as permissive
  for select
  to authenticated
using (((archived_at IS NULL) OR rls.is_platform_admin()));



  create policy "platform admins can edit the catalogue"
  on "public"."agent_templates"
  as permissive
  for update
  to authenticated
using (rls.is_platform_admin())
with check (rls.is_platform_admin());



  create policy "platform admins can write the catalogue"
  on "public"."agent_templates"
  as permissive
  for insert
  to authenticated
with check (rls.is_platform_admin());



  create policy "platform admins can read the platform settings"
  on "public"."platform_settings"
  as permissive
  for select
  to authenticated
using (rls.is_platform_admin());


CREATE TRIGGER set_updated_at BEFORE UPDATE ON public.agent_templates FOR EACH ROW EXECUTE FUNCTION public.moddatetime('updated_at');

CREATE TRIGGER set_updated_at BEFORE UPDATE ON public.platform_settings FOR EACH ROW EXECUTE FUNCTION public.moddatetime('updated_at');



-- Supabase's ALTER DEFAULT PRIVILEGES grants every privilege on a new public
-- table to anon and authenticated, so omitting the grants above is not enough:
-- the table is created with them anyway. These are the revokes db diff asked
-- for on the next run, merged into this migration rather than trailing it.
revoke delete on table "public"."agent_template_versions" from "anon";

revoke insert on table "public"."agent_template_versions" from "anon";

revoke truncate on table "public"."agent_template_versions" from "anon";

revoke update on table "public"."agent_template_versions" from "anon";

revoke delete on table "public"."agent_template_versions" from "authenticated";

revoke insert on table "public"."agent_template_versions" from "authenticated";

revoke truncate on table "public"."agent_template_versions" from "authenticated";

revoke update on table "public"."agent_template_versions" from "authenticated";

revoke delete on table "public"."agent_templates" from "anon";

revoke truncate on table "public"."agent_templates" from "anon";

revoke delete on table "public"."agent_templates" from "authenticated";

revoke truncate on table "public"."agent_templates" from "authenticated";

revoke delete on table "public"."platform_settings" from "anon";

revoke insert on table "public"."platform_settings" from "anon";

revoke truncate on table "public"."platform_settings" from "anon";

revoke update on table "public"."platform_settings" from "anon";

revoke delete on table "public"."platform_settings" from "authenticated";

revoke insert on table "public"."platform_settings" from "authenticated";

revoke truncate on table "public"."platform_settings" from "authenticated";

revoke update on table "public"."platform_settings" from "authenticated";




  create table "public"."agent_template_test_runs" (
    "id" uuid not null default gen_random_uuid(),
    "test_id" uuid,
    "template_id" uuid not null,
    "version" integer not null,
    "status" text not null default 'running'::text,
    "deterministic_total" integer not null default 0,
    "deterministic_passed" integer not null default 0,
    "judge_score" numeric,
    "transcript" jsonb not null default '[]'::jsonb,
    "failures" jsonb not null default '[]'::jsonb,
    "error" text,
    "started_at" timestamp with time zone not null default now(),
    "finished_at" timestamp with time zone
      );


alter table "public"."agent_template_test_runs" enable row level security;


  create table "public"."agent_template_tests" (
    "id" uuid not null default gen_random_uuid(),
    "template_id" uuid not null,
    "name" text not null,
    "profile" jsonb not null default '{}'::jsonb,
    "turns" jsonb not null,
    "expectations" jsonb not null default '{}'::jsonb,
    "created_at" timestamp with time zone not null default now(),
    "updated_at" timestamp with time zone not null default now()
      );


alter table "public"."agent_template_tests" enable row level security;

CREATE UNIQUE INDEX agent_template_test_runs_pkey ON public.agent_template_test_runs USING btree (id);

CREATE INDEX agent_template_test_runs_template_idx ON public.agent_template_test_runs USING btree (template_id, version, started_at DESC);

CREATE UNIQUE INDEX agent_template_tests_pkey ON public.agent_template_tests USING btree (id);

CREATE UNIQUE INDEX agent_template_tests_template_id_name_key ON public.agent_template_tests USING btree (template_id, name);

alter table "public"."agent_template_test_runs" add constraint "agent_template_test_runs_pkey" PRIMARY KEY using index "agent_template_test_runs_pkey";

alter table "public"."agent_template_tests" add constraint "agent_template_tests_pkey" PRIMARY KEY using index "agent_template_tests_pkey";

alter table "public"."agent_template_test_runs" add constraint "agent_template_test_runs_status_known" CHECK ((status = ANY (ARRAY['running'::text, 'passed'::text, 'failed'::text, 'error'::text]))) not valid;

alter table "public"."agent_template_test_runs" validate constraint "agent_template_test_runs_status_known";

alter table "public"."agent_template_test_runs" add constraint "agent_template_test_runs_test_id_fkey" FOREIGN KEY (test_id) REFERENCES public.agent_template_tests(id) ON DELETE SET NULL not valid;

alter table "public"."agent_template_test_runs" validate constraint "agent_template_test_runs_test_id_fkey";

alter table "public"."agent_template_test_runs" add constraint "agent_template_test_runs_version_fkey" FOREIGN KEY (template_id, version) REFERENCES public.agent_template_versions(template_id, version) ON DELETE CASCADE not valid;

alter table "public"."agent_template_test_runs" validate constraint "agent_template_test_runs_version_fkey";

alter table "public"."agent_template_tests" add constraint "agent_template_tests_expectations_shape" CHECK ((jsonb_typeof(expectations) = 'object'::text)) not valid;

alter table "public"."agent_template_tests" validate constraint "agent_template_tests_expectations_shape";

alter table "public"."agent_template_tests" add constraint "agent_template_tests_template_id_fkey" FOREIGN KEY (template_id) REFERENCES public.agent_templates(id) ON DELETE CASCADE not valid;

alter table "public"."agent_template_tests" validate constraint "agent_template_tests_template_id_fkey";

alter table "public"."agent_template_tests" add constraint "agent_template_tests_template_id_name_key" UNIQUE using index "agent_template_tests_template_id_name_key";

alter table "public"."agent_template_tests" add constraint "agent_template_tests_turns_shape" CHECK (((jsonb_typeof(turns) = 'array'::text) AND (jsonb_array_length(turns) > 0))) not valid;

alter table "public"."agent_template_tests" validate constraint "agent_template_tests_turns_shape";

grant delete on table "public"."agent_template_test_runs" to "anon";

grant insert on table "public"."agent_template_test_runs" to "anon";

grant references on table "public"."agent_template_test_runs" to "anon";

grant select on table "public"."agent_template_test_runs" to "anon";

grant trigger on table "public"."agent_template_test_runs" to "anon";

grant update on table "public"."agent_template_test_runs" to "anon";

grant delete on table "public"."agent_template_test_runs" to "authenticated";

grant insert on table "public"."agent_template_test_runs" to "authenticated";

grant references on table "public"."agent_template_test_runs" to "authenticated";

grant select on table "public"."agent_template_test_runs" to "authenticated";

grant trigger on table "public"."agent_template_test_runs" to "authenticated";

grant update on table "public"."agent_template_test_runs" to "authenticated";

grant delete on table "public"."agent_template_test_runs" to "service_role";

grant insert on table "public"."agent_template_test_runs" to "service_role";

grant references on table "public"."agent_template_test_runs" to "service_role";

grant select on table "public"."agent_template_test_runs" to "service_role";

grant trigger on table "public"."agent_template_test_runs" to "service_role";

grant truncate on table "public"."agent_template_test_runs" to "service_role";

grant update on table "public"."agent_template_test_runs" to "service_role";

grant delete on table "public"."agent_template_tests" to "anon";

grant insert on table "public"."agent_template_tests" to "anon";

grant references on table "public"."agent_template_tests" to "anon";

grant select on table "public"."agent_template_tests" to "anon";

grant trigger on table "public"."agent_template_tests" to "anon";

grant update on table "public"."agent_template_tests" to "anon";

grant delete on table "public"."agent_template_tests" to "authenticated";

grant insert on table "public"."agent_template_tests" to "authenticated";

grant references on table "public"."agent_template_tests" to "authenticated";

grant select on table "public"."agent_template_tests" to "authenticated";

grant trigger on table "public"."agent_template_tests" to "authenticated";

grant update on table "public"."agent_template_tests" to "authenticated";

grant delete on table "public"."agent_template_tests" to "service_role";

grant insert on table "public"."agent_template_tests" to "service_role";

grant references on table "public"."agent_template_tests" to "service_role";

grant select on table "public"."agent_template_tests" to "service_role";

grant trigger on table "public"."agent_template_tests" to "service_role";

grant truncate on table "public"."agent_template_tests" to "service_role";

grant update on table "public"."agent_template_tests" to "service_role";


  create policy "platform admins manage the runs"
  on "public"."agent_template_test_runs"
  as permissive
  for all
  to authenticated
using (rls.is_platform_admin())
with check (rls.is_platform_admin());



  create policy "platform admins manage the drills"
  on "public"."agent_template_tests"
  as permissive
  for all
  to authenticated
using (rls.is_platform_admin())
with check (rls.is_platform_admin());


CREATE TRIGGER set_updated_at BEFORE UPDATE ON public.agent_template_tests FOR EACH ROW EXECUTE FUNCTION public.moddatetime('updated_at');



-- Hand-appended, as in T2 and T4: Supabase's default privileges include
-- TRUNCATE and `db diff` only emits the grants it finds in the shadow
-- database, never the revokes for what the table did not have yet. Without
-- these, `db diff` after a `db reset` asks for them again.
revoke truncate on table public.agent_template_tests from anon;
revoke truncate on table public.agent_template_tests from authenticated;
revoke truncate on table public.agent_template_test_runs from anon;
revoke truncate on table public.agent_template_test_runs from authenticated;

alter table "public"."platform_admins" add column "granted_by" uuid default auth.uid();

alter table "public"."platform_admins" add constraint "platform_admins_granted_by_fkey" FOREIGN KEY (granted_by) REFERENCES auth.users(id) ON DELETE SET NULL not valid;

alter table "public"."platform_admins" validate constraint "platform_admins_granted_by_fkey";



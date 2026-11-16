
-- Safer first-run defaults for new Nipto accounts.
alter table public.profiles
  alter column is_private set default true;

alter table public.posts
  alter column visibility set default 'followers';

alter table public.shorts
  alter column visibility set default 'followers';

comment on column public.profiles.is_private is
  'New accounts are private by default. Users can opt into public discovery in Settings.';
comment on column public.posts.visibility is
  'New posts are visible to followers by default; public sharing requires an explicit user choice.';
comment on column public.shorts.visibility is
  'New Shorts are visible to followers by default; public distribution requires an explicit user choice.';

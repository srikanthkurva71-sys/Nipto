
create table public.user_feedback (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  category text not null check (category in ('bug', 'idea', 'experience', 'support')),
  rating smallint check (rating between 1 and 5),
  subject text not null check (char_length(trim(subject)) between 3 and 100),
  message text not null check (char_length(trim(message)) between 10 and 4000),
  app_version text,
  platform text not null default 'android' check (platform = 'android'),
  status text not null default 'received' check (status in ('received', 'reviewing', 'planned', 'resolved', 'closed')),
  created_at timestamptz not null default now()
);

create index user_feedback_user_created_idx
  on public.user_feedback (user_id, created_at desc);
create index user_feedback_status_created_idx
  on public.user_feedback (status, created_at desc);

alter table public.user_feedback enable row level security;

create policy "feedback_submit_as_self"
  on public.user_feedback
  for insert
  to authenticated
  with check (user_id = auth.uid() and status = 'received' and platform = 'android');

create policy "feedback_read_own"
  on public.user_feedback
  for select
  to authenticated
  using (user_id = auth.uid());

revoke all on public.user_feedback from anon, public;
grant insert, select on public.user_feedback to authenticated;

comment on table public.user_feedback is
  'Product feedback and support requests submitted by authenticated Nipto Android users. Status is managed by trusted moderation tooling, never by clients.';

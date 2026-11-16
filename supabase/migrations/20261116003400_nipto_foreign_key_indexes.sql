-- Cover foreign-key lookups used by joins, deletes and staff review workflows.
create index if not exists blocked_users_blocked_id_idx on public.blocked_users(blocked_id);
create index if not exists close_friends_friend_id_idx on public.close_friends(friend_id);
create index if not exists conversations_created_by_idx on public.conversations(created_by);
create index if not exists conversations_direct_user_b_idx on public.conversations(direct_user_b);
create index if not exists message_receipts_conversation_id_idx on public.message_receipts(conversation_id);
create index if not exists messages_reply_to_id_idx on public.messages(reply_to_id);
create index if not exists notifications_actor_id_idx on public.notifications(actor_id);
create index if not exists post_comments_author_id_idx on public.post_comments(author_id);
create index if not exists post_likes_user_id_idx on public.post_likes(user_id);
create index if not exists posts_moderation_reviewed_by_idx on public.posts(moderation_reviewed_by);
create index if not exists short_comments_author_id_idx on public.short_comments(author_id);
create index if not exists short_likes_user_id_idx on public.short_likes(user_id);
create index if not exists shorts_moderation_reviewed_by_idx on public.shorts(moderation_reviewed_by);
create index if not exists status_views_viewer_id_idx on public.status_views(viewer_id);
create index if not exists user_feedback_reviewed_by_idx on public.user_feedback(reviewed_by);
create index if not exists user_reports_reported_user_id_idx on public.user_reports(reported_user_id);
create index if not exists user_reports_reporter_id_idx on public.user_reports(reporter_id);
create index if not exists user_reports_reviewed_by_idx on public.user_reports(reviewed_by);
create index if not exists staff_action_log_actor_id_idx on private.staff_action_log(actor_id);
create index if not exists staff_roles_granted_by_idx on private.staff_roles(granted_by);

-- The rate-limit event table needs a stable row identity for maintenance and diagnostics.
alter table private.nipto_auth_attempts
  add column if not exists id bigint generated always as identity;
do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conrelid = 'private.nipto_auth_attempts'::regclass
      and contype = 'p'
  ) then
    alter table private.nipto_auth_attempts
      add constraint nipto_auth_attempts_pkey primary key (id);
  end if;
end;
$$;

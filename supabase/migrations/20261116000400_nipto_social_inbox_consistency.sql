
-- Nipto Social v1.0 consistency and least-privilege follow-up.
revoke update on public.follows from authenticated;
grant update (status) on public.follows to authenticated;

drop policy "posts_read_visible" on public.posts;
create policy "posts_read_visible" on public.posts for select to authenticated
using (author_id = (select auth.uid()) or private.can_view_post(id));

drop policy "post_media_read_visible" on storage.objects;
create policy "post_media_read_visible" on storage.objects for select to authenticated
using (
  bucket_id = 'posts' and exists (
    select 1 from public.posts p
    where p.media_path = storage.objects.name
      and (p.author_id = (select auth.uid()) or private.can_view_post(p.id))
  )
);

create or replace function private.on_message_created()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  update public.conversations
  set updated_at = now()
  where id = new.conversation_id;

  insert into public.message_receipts (message_id, conversation_id, user_id)
  select new.id, new.conversation_id, cm.user_id
  from public.conversation_members cm
  where cm.conversation_id = new.conversation_id
    and cm.user_id <> new.sender_id
    and cm.membership_state = 'accepted'
  on conflict do nothing;

  return new;
end;
$$;
revoke all on function private.on_message_created() from public, anon, authenticated;
create trigger messages_after_insert
after insert on public.messages
for each row execute function private.on_message_created();

create or replace function private.notify_group_invite()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid;
  v_title text;
begin
  if new.membership_state <> 'invited' then return new; end if;
  select c.created_by, c.title into v_actor, v_title
  from public.conversations c where c.id = new.conversation_id;
  insert into public.notifications (recipient_id, actor_id, notification_type, entity_id, payload)
  values (
    new.user_id,
    v_actor,
    'system',
    new.conversation_id,
    jsonb_build_object('kind', 'group_invite', 'title', coalesce(v_title, 'Group conversation'))
  );
  return new;
end;
$$;
revoke all on function private.notify_group_invite() from public, anon, authenticated;
create trigger conversation_member_invited
after insert on public.conversation_members
for each row execute function private.notify_group_invite();

comment on function private.on_message_created() is 'Updates conversation recency and creates per-recipient message receipt rows.';

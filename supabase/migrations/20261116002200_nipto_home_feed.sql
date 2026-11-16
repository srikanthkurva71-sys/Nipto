
create or replace function public.get_home_feed(p_limit integer default 25, p_before timestamptz default null)
returns table (
  id uuid,
  author_id uuid,
  author_nipto_id text,
  author_display_name text,
  author_avatar_path text,
  caption text,
  media_path text,
  media_type text,
  created_at timestamptz,
  like_count bigint,
  comment_count bigint,
  viewer_liked boolean
)
language sql
stable
security definer
set search_path = ''
as $$
  select
    p.id,
    p.author_id,
    pr.nipto_id,
    pr.display_name,
    pr.avatar_path,
    p.caption,
    p.media_path,
    p.media_type,
    p.created_at,
    (select count(*) from public.post_likes pl where pl.post_id = p.id),
    (select count(*) from public.post_comments pc where pc.post_id = p.id),
    exists (
      select 1 from public.post_likes mine
      where mine.post_id = p.id and mine.user_id = auth.uid()
    )
  from public.posts p
  join public.profiles pr on pr.id = p.author_id
  where auth.uid() is not null
    and p.moderation_state = 'approved'
    and (p_before is null or p.created_at < p_before)
    and not private.is_blocked_between(auth.uid(), p.author_id)
    and (
      p.author_id = auth.uid()
      or p.visibility = 'public'
      or (
        p.visibility = 'followers'
        and private.has_accepted_follow(auth.uid(), p.author_id)
      )
    )
    and (
      not pr.is_private
      or p.author_id = auth.uid()
      or private.has_accepted_follow(auth.uid(), p.author_id)
    )
  order by p.created_at desc, p.id desc
  limit least(greatest(coalesce(p_limit, 25), 1), 50);
$$;

revoke all on function public.get_home_feed(integer, timestamptz) from public, anon;
grant execute on function public.get_home_feed(integer, timestamptz) to authenticated;

create or replace function private.notify_post_like()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_author uuid;
begin
  select p.author_id into v_author from public.posts p where p.id = new.post_id;
  if v_author is null or v_author = new.user_id then return new; end if;
  insert into public.notifications (recipient_id, actor_id, notification_type, entity_id, payload)
  values (v_author, new.user_id, 'like', new.post_id, jsonb_build_object('content_type','post'));
  return new;
end;
$$;
revoke all on function private.notify_post_like() from public, anon, authenticated;
drop trigger if exists post_likes_after_insert_notify on public.post_likes;
create trigger post_likes_after_insert_notify
after insert on public.post_likes
for each row execute function private.notify_post_like();

create or replace function private.notify_post_comment()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_author uuid;
begin
  select p.author_id into v_author from public.posts p where p.id = new.post_id;
  if v_author is null or v_author = new.author_id then return new; end if;
  insert into public.notifications (recipient_id, actor_id, notification_type, entity_id, payload)
  values (v_author, new.author_id, 'comment', new.post_id, jsonb_build_object('content_type','post'));
  return new;
end;
$$;
revoke all on function private.notify_post_comment() from public, anon, authenticated;
drop trigger if exists post_comments_after_insert_notify on public.post_comments;
create trigger post_comments_after_insert_notify
after insert on public.post_comments
for each row execute function private.notify_post_comment();


-- Keep feed query plans predictable as the social graph grows.
create index if not exists posts_approved_feed_created_idx
  on public.posts (created_at desc, id desc)
  where moderation_state = 'approved';

create index if not exists post_likes_post_id_idx
  on public.post_likes (post_id);

create index if not exists post_comments_post_created_idx
  on public.post_comments (post_id, created_at);

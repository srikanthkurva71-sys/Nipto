
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
    case
      when pr.is_private and not private.has_accepted_follow(auth.uid(), pr.id)
      then null
      else pr.avatar_path
    end as author_avatar_path,
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
    and (p_before is null or (p.created_at, p.id) < (p_before, 'ffffffff-ffff-ffff-ffff-ffffffffffff'::uuid))
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

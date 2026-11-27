-- Nipto media validation pipeline: private asset ledger, real validation states,
-- owner-scoped enqueue/status RPCs, service-role cleanup and staff review gates.
-- No public buckets and no service-role credentials are exposed to clients.

create table if not exists private.media_assets (
  bucket text not null check (
    bucket in ('avatars','chat-media','statuses','posts','shorts')
  ),
  path text not null,
  owner_id uuid not null references auth.users(id) on delete cascade,
  mime text not null,
  size bigint not null check (size > 0),
  sha256 text,
  state text not null default 'uploaded' check (
    state in (
      'uploaded','queued','scanning','clean','needs_review',
      'processing','ready','rejected','failed'
    )
  ),
  attempts integer not null default 0 check (attempts >= 0 and attempts <= 10),
  last_error text,
  thumbnail_path text,
  rendition_path text,
  next_attempt_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  validated_at timestamptz,
  primary key (bucket, path)
);

create index if not exists media_assets_owner_state_idx
  on private.media_assets (owner_id, state, updated_at desc);
create index if not exists media_assets_queue_idx
  on private.media_assets (state, next_attempt_at)
  where state in ('uploaded','queued','scanning','failed');

alter table private.media_assets enable row level security;
drop policy if exists media_assets_service_role on private.media_assets;
create policy media_assets_service_role on private.media_assets
  for all to service_role using (true) with check (true);

-- Defense in depth: clients have no table grants and no row policies.
revoke all on private.media_assets from public, anon, authenticated;
grant select, insert, update, delete on private.media_assets to service_role;

comment on table private.media_assets is
  'Server-owned media validation ledger. Clients may only use the scoped enqueue/status RPCs.';

-- Canonical owner-prefixed object keys. The same shape is enforced by storage
-- insert policies and by the enqueue RPC, so an object cannot be enqueued under
-- a path the caller could not have uploaded.
create or replace function private.nipto_media_valid_owner_path(
  p_bucket text,
  p_path text,
  p_owner uuid
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  with key as (
    select string_to_array(p_path, '/') as tokens
  )
  select
    p_owner is not null
    and p_bucket in ('avatars','chat-media','statuses','posts','shorts')
    and array_length(tokens, 1) is not null
    and case p_bucket
      when 'avatars' then
        array_length(tokens, 1) = 2
        and tokens[1] = p_owner::text
        and tokens[2] ~ '^avatar_[0-9]{10,20}\.(jpg|jpeg|png|webp)$'
      when 'chat-media' then
        array_length(tokens, 1) = 3
        and tokens[1] ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
        and tokens[2] = p_owner::text
        and tokens[3] ~ '^[0-9]{10,20}\.(jpg|jpeg|png|webp)$'
      when 'statuses' then
        array_length(tokens, 1) = 2
        and tokens[1] = p_owner::text
        and tokens[2] ~ '^[0-9]{10,20}\.(jpg|jpeg|png|webp|mp4)$'
      when 'posts' then
        array_length(tokens, 1) = 2
        and tokens[1] = p_owner::text
        and tokens[2] ~ '^[0-9]{10,20}\.(jpg|jpeg|png|webp|mp4)$'
      when 'shorts' then
        array_length(tokens, 1) = 2
        and tokens[1] = p_owner::text
        and tokens[2] ~ '^[0-9]{10,20}\.mp4$'
      else false
    end
  from key;
$$;
revoke all on function private.nipto_media_valid_owner_path(text, text, uuid)
  from public, anon, authenticated;

create or replace function private.nipto_media_mime_allowed(p_bucket text, p_mime text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select case p_bucket
    when 'avatars' then p_mime in ('image/jpeg','image/png','image/webp')
    when 'chat-media' then p_mime in (
      'image/jpeg','image/png','image/webp','video/mp4','audio/mpeg','audio/mp4'
    )
    when 'statuses' then p_mime in ('image/jpeg','image/png','image/webp','video/mp4')
    when 'posts' then p_mime in ('image/jpeg','image/png','image/webp','video/mp4')
    when 'shorts' then p_mime = 'video/mp4'
    else false
  end;
$$;
revoke all on function private.nipto_media_mime_allowed(text, text)
  from public, anon, authenticated;

-- Client entry point. It confirms the caller uploaded this exact owner-prefixed
-- object, that the object exists, and that the server allowlists its declared
-- MIME and size. Magic-byte verification happens later in the Edge Function.
create or replace function public.nipto_media_enqueue(p_bucket text, p_path text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user uuid := auth.uid();
  v_meta jsonb;
  v_limit bigint;
  v_mime text;
  v_size_text text;
  v_state text;
begin
  if v_user is null then
    raise exception 'Sign in to continue';
  end if;
  if p_path is null or char_length(p_path) > 512
    or not private.nipto_media_valid_owner_path(p_bucket, p_path, v_user) then
    raise exception 'Media path is not owned by this account';
  end if;
  if p_bucket = 'chat-media'
    and not private.is_conversation_member((string_to_array(p_path, '/'))[1]::uuid) then
    raise exception 'Media conversation is not available';
  end if;

  select o.metadata, b.file_size_limit
    into v_meta, v_limit
  from storage.objects o
  join storage.buckets b on b.id = o.bucket_id
  where o.bucket_id = p_bucket and o.name = p_path;

  if v_meta is null then
    raise exception 'Media object is not available';
  end if;
  v_mime := lower(coalesce(v_meta->>'mimetype', ''));
  v_size_text := coalesce(v_meta->>'size', '');
  if not private.nipto_media_mime_allowed(p_bucket, v_mime) then
    raise exception 'Media type is not allowed';
  end if;
  if v_size_text !~ '^[0-9]+$'
    or v_size_text::bigint <= 0
    or v_size_text::bigint > coalesce(v_limit, 209715200) then
    raise exception 'Media size is not allowed';
  end if;

  insert into private.media_assets as a (
    bucket, path, owner_id, mime, size, state,
    created_at, updated_at, next_attempt_at
  )
  values (p_bucket, p_path, v_user, v_mime, v_size_text::bigint,
          'queued', now(), now(), now())
  on conflict (bucket, path) do update
    set mime = excluded.mime,
        size = excluded.size,
        updated_at = case
          when a.state in ('clean','ready','needs_review','processing','rejected')
            then a.updated_at
          else now()
        end
    where a.owner_id = v_user
  returning a.state into v_state;

  if v_state is null then
    raise exception 'Media path is not available';
  end if;

  return jsonb_build_object(
    'bucket', p_bucket,
    'path', p_path,
    'state', v_state,
    'mime', v_mime,
    'size', v_size_text::bigint
  );
end;
$$;

create or replace function public.nipto_media_status(p_bucket text, p_path text)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_user uuid := auth.uid();
  v_staff boolean := public.staff_can_access();
  v_result jsonb;
begin
  if v_user is null then
    raise exception 'Sign in to continue';
  end if;
  if p_path is null or char_length(p_path) > 512
    or (not v_staff
        and not private.nipto_media_valid_owner_path(p_bucket, p_path, v_user)) then
    raise exception 'Media path is not available';
  end if;

  select jsonb_build_object(
    'bucket', a.bucket,
    'path', a.path,
    'state', a.state,
    'mime', a.mime,
    'size', a.size,
    'sha256', a.sha256,
    'attempts', a.attempts,
    'last_error', a.last_error,
    'thumbnail_path', a.thumbnail_path,
    'rendition_path', a.rendition_path,
    'next_attempt_at', a.next_attempt_at,
    'updated_at', a.updated_at
  )
  into v_result
  from private.media_assets a
  where a.bucket = p_bucket
    and a.path = p_path
    and (v_staff or a.owner_id = v_user);

  return coalesce(v_result, 'null'::jsonb);
end;
$$;

revoke all on function public.nipto_media_enqueue(text, text) from public, anon;
revoke all on function public.nipto_media_status(text, text) from public, anon;
grant execute on function public.nipto_media_enqueue(text, text) to authenticated;
grant execute on function public.nipto_media_status(text, text) to authenticated;

-- Service-role-only pipeline hooks. They are never granted to clients.
create or replace function private.nipto_media_claim(
  p_bucket text,
  p_path text,
  p_sha256 text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_asset private.media_assets%rowtype;
  v_max_attempts constant integer := 5;
begin
  select * into v_asset
  from private.media_assets
  where bucket = p_bucket and path = p_path
  for update;

  if not found then
    return jsonb_build_object('claimed', false, 'state', 'not_enqueued');
  end if;

  if v_asset.sha256 = p_sha256
    and v_asset.state in ('needs_review','processing','clean','ready','rejected') then
    return jsonb_build_object(
      'claimed', false, 'state', v_asset.state, 'reason', 'already_validated'
    );
  end if;

  if v_asset.attempts >= v_max_attempts then
    update private.media_assets
    set state = 'failed', last_error = 'attempt_limit_exceeded', updated_at = now()
    where bucket = p_bucket and path = p_path;
    return jsonb_build_object('claimed', false, 'state', 'failed', 'reason', 'attempt_limit_exceeded');
  end if;

  if now() < v_asset.next_attempt_at then
    return jsonb_build_object('claimed', false, 'state', v_asset.state, 'reason', 'backoff');
  end if;

  update private.media_assets
  set state = 'scanning',
      sha256 = p_sha256,
      attempts = attempts + 1,
      last_error = null,
      next_attempt_at = now() + (least(attempts + 1, v_max_attempts) * interval '1 minute'),
      updated_at = now()
  where bucket = p_bucket and path = p_path
  returning * into v_asset;

  return jsonb_build_object(
    'claimed', true, 'state', v_asset.state, 'attempts', v_asset.attempts
  );
end;
$$;

create or replace function private.nipto_media_finish_validation(
  p_bucket text,
  p_path text,
  p_sha256 text,
  p_mime text,
  p_size bigint,
  p_state text,
  p_error text default null
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if p_state not in ('needs_review','processing','rejected','failed','clean','ready') then
    raise exception 'Invalid media validation state';
  end if;

  update private.media_assets
  set state = p_state,
      sha256 = p_sha256,
      mime = p_mime,
      size = p_size,
      last_error = p_error,
      validated_at = case
        when p_state in ('needs_review','processing','clean','ready') then now()
        else validated_at
      end,
      updated_at = now()
  where bucket = p_bucket
    and path = p_path
    and state = 'scanning';
end;
$$;

revoke all on function private.nipto_media_claim(text, text, text)
  from public, anon, authenticated;
revoke all on function private.nipto_media_finish_validation(text, text, text, text, bigint, text, text)
  from public, anon, authenticated;
grant execute on function private.nipto_media_claim(text, text, text) to service_role;
grant execute on function private.nipto_media_finish_validation(text, text, text, text, bigint, text, text)
  to service_role;

-- Unreferenced objects and expired pending states can be reclaimed by a
-- scheduled service-role job. Referenced content is never removed here.
create or replace function private.nipto_media_cleanup(
  p_retention interval default interval '7 days',
  p_pending_retention interval default interval '24 hours'
)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_asset record;
  v_deleted integer := 0;
begin
  for v_asset in
    select a.*
    from private.media_assets a
    where a.bucket in ('avatars','chat-media','statuses','posts','shorts')
      and (
        (a.state in ('clean','ready') and a.created_at < now() - p_retention)
        or (
          a.state in ('uploaded','queued','scanning','needs_review','processing','failed','rejected')
          and (
            a.updated_at < now() - p_pending_retention
            or a.created_at < now() - p_retention
          )
        )
      )
      and not exists (
        select 1 from public.profiles p
        where p.avatar_path in (a.path, a.thumbnail_path, a.rendition_path)
      )
      and not exists (
        select 1 from public.statuses s
        where s.media_path in (a.path, a.thumbnail_path, a.rendition_path)
      )
      and not exists (
        select 1 from public.posts p
        where p.media_path in (a.path, a.thumbnail_path, a.rendition_path)
      )
      and not exists (
        select 1 from public.shorts s
        where s.video_path in (a.path, a.thumbnail_path, a.rendition_path)
           or s.thumbnail_path in (a.path, a.thumbnail_path, a.rendition_path)
      )
      and not exists (
        select 1 from public.messages m
        where m.media_path in (a.path, a.thumbnail_path, a.rendition_path)
      )
  loop
    delete from storage.objects
    where bucket_id = v_asset.bucket
      and name in (v_asset.path, v_asset.thumbnail_path, v_asset.rendition_path);
    delete from private.media_assets
    where bucket = v_asset.bucket and path = v_asset.path;
    v_deleted := v_deleted + 1;
  end loop;

  return v_deleted;
end;
$$;

revoke all on function private.nipto_media_cleanup(interval, interval)
  from public, anon, authenticated;
grant execute on function private.nipto_media_cleanup(interval, interval) to service_role;

-- Storage insert policies now require canonical owner-prefixed key shapes.
drop policy if exists "avatar_owner_upload" on storage.objects;
create policy "avatar_owner_upload" on storage.objects
for insert to authenticated
with check (
  bucket_id = 'avatars'
  and private.nipto_media_valid_owner_path(bucket_id, name, (select auth.uid()))
);

drop policy if exists "chat_media_upload_member" on storage.objects;
create policy "chat_media_upload_member" on storage.objects
for insert to authenticated
with check (
  bucket_id = 'chat-media'
  and case
    when private.nipto_media_valid_owner_path(bucket_id, name, (select auth.uid()))
      then private.is_conversation_member((string_to_array(name, '/'))[1]::uuid)
    else false
  end
);

drop policy if exists "status_media_upload_owner" on storage.objects;
create policy "status_media_upload_owner" on storage.objects
for insert to authenticated
with check (
  bucket_id = 'statuses'
  and private.nipto_media_valid_owner_path(bucket_id, name, (select auth.uid()))
);

drop policy if exists "post_media_upload_owner" on storage.objects;
create policy "post_media_upload_owner" on storage.objects
for insert to authenticated
with check (
  bucket_id = 'posts'
  and private.nipto_media_valid_owner_path(bucket_id, name, (select auth.uid()))
);

drop policy if exists "short_media_upload_owner" on storage.objects;
create policy "short_media_upload_owner" on storage.objects
for insert to authenticated
with check (
  bucket_id = 'shorts'
  and private.nipto_media_valid_owner_path(bucket_id, name, (select auth.uid()))
);

-- Staff queue exposes the real validation state so reviewers do not mistake a
-- missing scanner verdict for approval.
drop function if exists public.staff_list_pending_content(text, integer);
create or replace function public.staff_list_pending_content(
  p_kind text default 'all',
  p_limit integer default 50
)
returns table (
  content_type text,
  content_id uuid,
  owner_id uuid,
  nipto_id text,
  display_name text,
  caption text,
  media_path text,
  media_type text,
  media_state text,
  media_error text,
  created_at timestamptz
)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if private.current_staff_role() not in ('moderator','admin') then
    raise exception 'Staff access required';
  end if;
  if p_kind not in ('all','posts','shorts') then
    raise exception 'Invalid content type';
  end if;
  return query
  select 'post'::text, p.id, p.author_id, pr.nipto_id, pr.display_name,
         p.caption, p.media_path, p.media_type,
         coalesce(a.state, 'not_enqueued'), a.last_error, p.created_at
  from public.posts p
  join public.profiles pr on pr.id = p.author_id
  left join private.media_assets a on a.bucket = 'posts' and a.path = p.media_path
  where p.moderation_state = 'pending' and p_kind in ('all','posts')
  union all
  select 'short'::text, s.id, s.creator_id, pr.nipto_id, pr.display_name,
         s.caption, s.video_path, 'video'::text,
         coalesce(a.state, 'not_enqueued'), a.last_error, s.created_at
  from public.shorts s
  join public.profiles pr on pr.id = s.creator_id
  left join private.media_assets a on a.bucket = 'shorts' and a.path = s.video_path
  where s.moderation_state = 'pending' and p_kind in ('all','shorts')
  order by created_at desc
  limit least(greatest(coalesce(p_limit, 50), 1), 100);
end;
$$;

-- Approval requires a real scanner/processor verdict or an explicit staff
-- override after human review. Rejection removes the private object and marks
-- its ledger entry rejected; it never publishes media.
drop function if exists public.staff_review_content(text, uuid, text, text);
create or replace function public.staff_review_content(
  p_kind text,
  p_content_id uuid,
  p_decision text,
  p_reason text default null,
  p_override boolean default false
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_owner uuid;
  v_bucket text;
  v_media_path text;
  v_thumb_path text;
  v_asset_state text;
begin
  if v_actor is null or private.current_staff_role() not in ('moderator','admin') then
    raise exception 'Staff access required';
  end if;
  if p_kind not in ('post','short') or p_decision not in ('approved','rejected') then
    raise exception 'Invalid moderation decision';
  end if;
  if p_reason is not null and char_length(p_reason) > 2000 then
    raise exception 'Moderation reason is too long';
  end if;

  if p_kind = 'post' then
    v_bucket := 'posts';
    select p.media_path into v_media_path
    from public.posts p
    where p.id = p_content_id and p.moderation_state = 'pending';
  else
    v_bucket := 'shorts';
    select s.video_path, s.thumbnail_path into v_media_path, v_thumb_path
    from public.shorts s
    where s.id = p_content_id and s.moderation_state = 'pending';
  end if;

  if v_media_path is null then
    raise exception 'Pending content item not found';
  end if;

  select a.state into v_asset_state
  from private.media_assets a
  where a.bucket = v_bucket and a.path = v_media_path;

  if p_decision = 'approved'
    and coalesce(v_asset_state, 'not_enqueued') not in ('clean','ready')
    and coalesce(p_override, false) = false then
    raise exception
      'Media validation is incomplete. Review the object manually and approve with an explicit override.';
  end if;

  if p_kind = 'post' then
    update public.posts
    set moderation_state = p_decision,
        moderation_reviewed_by = v_actor,
        moderation_reviewed_at = now(),
        moderation_reason = p_reason
    where id = p_content_id and moderation_state = 'pending'
    returning author_id into v_owner;
  else
    update public.shorts
    set moderation_state = p_decision,
        moderation_reviewed_by = v_actor,
        moderation_reviewed_at = now(),
        moderation_reason = p_reason
    where id = p_content_id and moderation_state = 'pending'
    returning creator_id into v_owner;
  end if;

  if v_owner is null then
    raise exception 'Pending content item not found';
  end if;

  if p_decision = 'rejected' then
    update private.media_assets
    set state = 'rejected',
        last_error = 'staff_rejected',
        updated_at = now()
    where bucket = v_bucket
      and path in (v_media_path, v_thumb_path);
    delete from storage.objects
    where bucket_id = v_bucket
      and name in (v_media_path, v_thumb_path);
  end if;

  insert into private.staff_action_log (actor_id, action_type, target_type, target_id, reason, details)
  values (
    v_actor,
    'content_moderated',
    p_kind,
    p_content_id,
    p_reason,
    jsonb_build_object(
      'decision', p_decision,
      'media_state', coalesce(v_asset_state, 'not_enqueued'),
      'staff_override', coalesce(p_override, false) and p_decision = 'approved'
    )
  );

  insert into public.notifications (recipient_id, actor_id, notification_type, entity_id, payload)
  values (
    v_owner,
    v_actor,
    'system',
    p_content_id,
    jsonb_build_object(
      'kind', 'content_moderation',
      'content_type', p_kind,
      'decision', p_decision
    )
  );
end;
$$;

revoke all on function public.staff_list_pending_content(text, integer) from public, anon;
revoke all on function public.staff_review_content(text, uuid, text, text, boolean)
  from public, anon;
grant execute on function public.staff_list_pending_content(text, integer) to authenticated;
grant execute on function public.staff_review_content(text, uuid, text, text, boolean)
  to authenticated;

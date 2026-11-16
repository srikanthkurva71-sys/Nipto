
-- Harden status updates: a user may acknowledge views but cannot spoof view timestamps.
revoke insert, update on public.status_views from authenticated;
grant insert (status_id, viewer_id) on public.status_views to authenticated;

-- Only the message recipient may update a receipt, and only receipt timestamps.
revoke insert, update on public.message_receipts from authenticated;
grant update (delivered_at, read_at) on public.message_receipts to authenticated;

-- Prevent clients setting server-owned notification fields during insert.
revoke insert on public.notifications from authenticated;

-- Make follow request transitions explicit: only the recipient may accept/decline
-- a pending request, and only status is writable through the grant.
create or replace function private.guard_follow_transition()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if tg_op = 'INSERT' then
    if new.follower_id = auth.uid() then
      select case when p.is_private then 'pending' else 'accepted' end
      into new.status
      from public.profiles p
      where p.id = new.following_id and p.account_state = 'active';
      if new.status is null then
        raise exception 'Account is unavailable';
      end if;
    end if;
  elsif tg_op = 'UPDATE' then
    if new.follower_id <> old.follower_id
       or new.following_id <> old.following_id then
      raise exception 'Follow relationship identity is immutable';
    end if;
    if old.status = 'pending' and new.status = 'accepted'
       and old.following_id = auth.uid() then
      return new;
    end if;
    if old.status = 'accepted' and new.status = 'pending'
       and old.follower_id = auth.uid() then
      return new;
    end if;
    raise exception 'Invalid follow state transition';
  end if;
  return new;
end;
$$;
revoke all on function private.guard_follow_transition() from public, anon, authenticated;

drop trigger if exists follows_guard_state on public.follows;
create trigger follows_guard_state
before insert or update on public.follows
for each row execute function private.guard_follow_transition();

-- A pending follow can only be accepted by the person receiving the request.
drop policy if exists follows_update_recipient on public.follows;
drop policy if exists follows_update_participants on public.follows;
create policy follows_update_recipient on public.follows
for update to authenticated
using (following_id = auth.uid() or follower_id = auth.uid())
with check (
  following_id = auth.uid() or follower_id = auth.uid()
);

-- Keep profile-read projections minimal through search RPC rather than direct table enumeration.

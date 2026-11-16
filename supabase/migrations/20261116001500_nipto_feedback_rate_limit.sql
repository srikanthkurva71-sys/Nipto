
create or replace function private.enforce_feedback_rate_limit()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_count bigint;
begin
  perform pg_advisory_xact_lock(hashtextextended(new.user_id::text, 0));

  select count(*) into v_count
  from public.user_feedback f
  where f.user_id = new.user_id
    and f.created_at > now() - interval '24 hours';

  if v_count >= 5 then
    raise exception 'Feedback limit reached. Please try again later.'
      using errcode = 'P0001';
  end if;

  return new;
end;
$$;

revoke all on function private.enforce_feedback_rate_limit() from public, anon, authenticated;

create trigger user_feedback_rate_limit_before_insert
before insert on public.user_feedback
for each row execute function private.enforce_feedback_rate_limit();

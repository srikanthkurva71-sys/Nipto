create or replace function private.notify_recovery_contact_request()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.notifications(recipient_id,actor_id,notification_type,payload)
  values (
    new.recovery_user_id,
    new.owner_id,
    'system',
    jsonb_build_object('kind','recovery_request','request_id',new.id)
  );
  return new;
end;
$$;
revoke all on function private.notify_recovery_contact_request() from public,anon,authenticated;
create trigger recovery_contact_after_insert_notify
after insert on public.account_recovery_contacts
for each row execute function private.notify_recovery_contact_request();

create or replace function private.notify_recovery_contact_response()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if old.status = 'pending' and new.status = 'accepted' then
    insert into public.notifications(recipient_id,actor_id,notification_type,payload)
    values (
      new.owner_id,
      new.recovery_user_id,
      'system',
      jsonb_build_object('kind','recovery_accepted','request_id',new.id)
    );
  end if;
  return new;
end;
$$;
revoke all on function private.notify_recovery_contact_response() from public,anon,authenticated;
create trigger recovery_contact_after_response_notify
after update of status on public.account_recovery_contacts
for each row execute function private.notify_recovery_contact_response();

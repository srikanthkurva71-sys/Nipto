
create or replace function public.staff_review_report(
  p_report_id uuid,
  p_status text,
  p_resolution_note text default null
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_reporter uuid;
begin
  if v_actor is null or private.current_staff_role() not in ('moderator','admin') then
    raise exception 'Staff access required';
  end if;
  if p_status not in ('reviewing','actioned','dismissed') then
    raise exception 'Invalid report status';
  end if;
  if p_resolution_note is not null and char_length(p_resolution_note) > 4000 then
    raise exception 'Resolution note is too long';
  end if;

  update public.user_reports
  set status = p_status,
      resolution_note = p_resolution_note,
      reviewed_by = v_actor,
      reviewed_at = now()
  where id = p_report_id
  returning reporter_id into v_reporter;

  if v_reporter is null then raise exception 'Report not found'; end if;

  insert into private.staff_action_log (actor_id, action_type, target_type, target_id, reason, details)
  values (
    v_actor,
    'report_reviewed',
    'report',
    p_report_id,
    p_resolution_note,
    jsonb_build_object('status', p_status)
  );

  insert into public.notifications (recipient_id, actor_id, notification_type, entity_id, payload)
  values (
    v_reporter,
    v_actor,
    'system',
    p_report_id,
    jsonb_build_object('kind', 'report_update', 'status', p_status)
  );
end;
$$;
revoke all on function public.staff_review_report(uuid, text, text) from public, anon;
grant execute on function public.staff_review_report(uuid, text, text) to authenticated;

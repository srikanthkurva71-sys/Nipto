-- Explicit NULL-role rejection is required: SQL NOT IN returns NULL for a NULL role.
create or replace function public.staff_review_feedback(
  p_feedback_id uuid, p_status text, p_response_message text default null, p_staff_note text default null
)
returns void language plpgsql security definer set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_role text := private.current_staff_role();
  v_user_id uuid;
begin
  if v_actor is null or v_role is null or v_role not in ('moderator','admin') then
    raise exception 'Staff access required';
  end if;
  if p_status not in ('reviewing','planned','resolved','closed') then raise exception 'Invalid feedback status'; end if;
  if p_response_message is not null and char_length(p_response_message) > 2000 then raise exception 'Response is too long'; end if;
  if p_staff_note is not null and char_length(p_staff_note) > 4000 then raise exception 'Staff note is too long'; end if;
  update public.user_feedback
  set status = p_status, staff_note = coalesce(p_staff_note, staff_note),
      response_message = coalesce(p_response_message, response_message),
      reviewed_by = v_actor, reviewed_at = now()
  where id = p_feedback_id returning user_id into v_user_id;
  if v_user_id is null then raise exception 'Feedback item not found'; end if;
  insert into private.staff_action_log (actor_id, action_type, target_type, target_id, reason, details)
  values (v_actor, 'feedback_status_changed', 'feedback', p_feedback_id, p_staff_note,
          jsonb_build_object('status', p_status, 'has_response', p_response_message is not null));
  if p_response_message is not null or p_status in ('resolved','closed') then
    insert into public.notifications (recipient_id, actor_id, notification_type, entity_id, payload)
    values (v_user_id, v_actor, 'system', p_feedback_id,
            jsonb_build_object('kind', 'feedback_update', 'status', p_status, 'response', p_response_message));
  end if;
end;
$$;

create or replace function public.staff_review_report(
  p_report_id uuid, p_status text, p_resolution_note text default null
)
returns void language plpgsql security definer set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_role text := private.current_staff_role();
  v_reporter uuid;
begin
  if v_actor is null or v_role is null or v_role not in ('moderator','admin') then
    raise exception 'Staff access required';
  end if;
  if p_status not in ('reviewing','actioned','dismissed') then raise exception 'Invalid report status'; end if;
  if p_resolution_note is not null and char_length(p_resolution_note) > 4000 then raise exception 'Resolution note is too long'; end if;
  update public.user_reports
  set status = p_status, resolution_note = p_resolution_note, reviewed_by = v_actor, reviewed_at = now()
  where id = p_report_id returning reporter_id into v_reporter;
  if v_reporter is null then raise exception 'Report not found'; end if;
  insert into private.staff_action_log (actor_id, action_type, target_type, target_id, reason, details)
  values (v_actor, 'report_reviewed', 'report', p_report_id, p_resolution_note, jsonb_build_object('status', p_status));
  insert into public.notifications (recipient_id, actor_id, notification_type, entity_id, payload)
  values (v_reporter, v_actor, 'system', p_report_id, jsonb_build_object('kind', 'report_update', 'status', p_status));
end;
$$;

create or replace function public.staff_review_content(
  p_kind text, p_content_id uuid, p_decision text, p_reason text default null
)
returns void language plpgsql security definer set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_role text := private.current_staff_role();
  v_owner uuid;
begin
  if v_actor is null or v_role is null or v_role not in ('moderator','admin') then
    raise exception 'Staff access required';
  end if;
  if p_kind not in ('post','short') or p_decision not in ('approved','rejected') then raise exception 'Invalid moderation decision'; end if;
  if p_reason is not null and char_length(p_reason) > 2000 then raise exception 'Moderation reason is too long'; end if;
  if p_kind = 'post' then
    update public.posts
    set moderation_state = p_decision, moderation_reviewed_by = v_actor,
        moderation_reviewed_at = now(), moderation_reason = p_reason
    where id = p_content_id and moderation_state = 'pending'
    returning author_id into v_owner;
  else
    update public.shorts
    set moderation_state = p_decision, moderation_reviewed_by = v_actor,
        moderation_reviewed_at = now(), moderation_reason = p_reason
    where id = p_content_id and moderation_state = 'pending'
    returning creator_id into v_owner;
  end if;
  if v_owner is null then raise exception 'Pending content item not found'; end if;
  insert into private.staff_action_log (actor_id, action_type, target_type, target_id, reason, details)
  values (v_actor, 'content_moderated', p_kind, p_content_id, p_reason, jsonb_build_object('decision', p_decision));
  insert into public.notifications (recipient_id, actor_id, notification_type, entity_id, payload)
  values (v_owner, v_actor, 'system', p_content_id,
          jsonb_build_object('kind', 'content_moderation', 'content_type', p_kind, 'decision', p_decision));
end;
$$;

revoke all on function public.staff_review_feedback(uuid,text,text,text) from public, anon;
revoke all on function public.staff_review_report(uuid,text,text) from public, anon;
revoke all on function public.staff_review_content(text,uuid,text,text) from public, anon;
grant execute on function public.staff_review_feedback(uuid,text,text,text) to authenticated;
grant execute on function public.staff_review_report(uuid,text,text) to authenticated;
grant execute on function public.staff_review_content(text,uuid,text,text) to authenticated;

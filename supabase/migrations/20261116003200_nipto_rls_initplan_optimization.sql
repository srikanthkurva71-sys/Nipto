
do $$
declare
  pol record;
  v_using text;
  v_check text;
  v_statement text;
begin
  for pol in
    select
      n.nspname as schema_name,
      c.relname as table_name,
      p.polname as policy_name,
      pg_get_expr(p.polqual, p.polrelid) as using_expression,
      pg_get_expr(p.polwithcheck, p.polrelid) as check_expression
    from pg_policy p
    join pg_class c on c.oid = p.polrelid
    join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public'
      and (
        coalesce(pg_get_expr(p.polqual, p.polrelid), '') like '%auth.uid()%'
        or coalesce(pg_get_expr(p.polwithcheck, p.polrelid), '') like '%auth.uid()%'
      )
      and position(
        'select auth.uid()' in lower(
          coalesce(pg_get_expr(p.polqual, p.polrelid), '') || ' ' ||
          coalesce(pg_get_expr(p.polwithcheck, p.polrelid), '')
        )
      ) = 0
  loop
    v_using := case
      when pol.using_expression is null then null
      else replace(pol.using_expression, 'auth.uid()', '(select auth.uid())')
    end;
    v_check := case
      when pol.check_expression is null then null
      else replace(pol.check_expression, 'auth.uid()', '(select auth.uid())')
    end;

    v_statement := format(
      'alter policy %I on %I.%I',
      pol.policy_name,
      pol.schema_name,
      pol.table_name
    );
    if v_using is not null then
      v_statement := v_statement || format(' using (%s)', v_using);
    end if;
    if v_check is not null then
      v_statement := v_statement || format(' with check (%s)', v_check);
    end if;
    execute v_statement;
  end loop;
end;
$$;

-- Supabase Advisor flagged missing covering indexes for two private foreign keys.
-- These are forward-only, non-destructive indexes on existing user references.
create index if not exists privacy_audit_user_id_idx
  on private.privacy_audit (user_id);

create index if not exists push_delivery_outbox_user_id_idx
  on private.push_delivery_outbox (user_id);

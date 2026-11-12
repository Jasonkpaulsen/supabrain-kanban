-- SB-827 D2 (1/3): connection-less rows allowed only for identity refusals.
ALTER TABLE public.external_connection_audit_log ALTER COLUMN connection_id DROP NOT NULL;
ALTER TABLE public.external_connection_audit_log
  ADD CONSTRAINT ecal_connection_or_auth_refusal CHECK (connection_id IS NOT NULL OR operation = 'auth');
COMMENT ON COLUMN public.external_connection_audit_log.connection_id IS
  'SB-827: NULL only for identity refusals (operation = auth) where no connection could be identified.';

-- SB-827 D2 (2/3): the refusal recorder.
CREATE OR REPLACE FUNCTION public.external_connection_record_auth_refusal(p_reason_code text, p_trace_id uuid DEFAULT NULL::uuid)
 RETURNS void
 LANGUAGE plpgsql
 VOLATILE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_uid       uuid := auth.uid();
  v_client    text := public.oauth_client_id();
  c           public.external_connections%rowtype;
  v_reason    text := p_reason_code;
  v_conn      uuid := null;
  v_principal uuid := null;
  v_clientcol text := null;
  v_bucket    integer;
  v_global    integer;
  k_bucket_cap constant integer := 10;   -- auth rows per bucket per 60 s
  k_global_cap constant integer := 30;   -- connection-less rows per 60 s, all buckets
  k_token    constant text[] := array['token_missing','token_malformed','token_bad_signature','token_expired',
                                      'token_not_yet_valid','token_wrong_issuer','token_wrong_audience',
                                      'token_invalid','token_no_subject','identity_check_error'];
  k_identity constant text[] := array['client_id_missing','connection_not_found','connection_principal_mismatch',
                                      'connection_proposed','connection_disabled','connection_revoked','connection_expired'];
begin
  if p_reason_code is null or not (p_reason_code = any (k_token || k_identity)) then
    raise exception 'SB-827: unknown reason_code' using errcode = '22023';
  end if;

  if v_uid is null then
    -- Unverified caller: token-level reasons only, nothing attributed.
    if not (p_reason_code = any (k_token)) then
      raise exception 'SB-827: identity reasons need a verified session' using errcode = '42501';
    end if;
  else
    v_principal := v_uid;
    v_clientcol := v_client;               -- verified by PostgREST; never taken from a parameter
    if p_reason_code = any (k_identity) then
      if v_client is null then
        v_reason := 'client_id_missing';
      else
        select * into c from public.external_connections where oauth_client_id = v_client;
        if not found then
          v_reason := 'connection_not_found';
        elsif c.principal_user_id is distinct from v_uid then
          v_reason := 'connection_principal_mismatch';
        else
          if c.status <> 'active' then
            v_conn := c.id; v_reason := 'connection_' || c.status;
          elsif c.expires_at is not null and c.expires_at <= now() then
            v_conn := c.id; v_reason := 'connection_expired';
          else
            v_reason := 'identity_check_error';   -- DB sees it active: refusal unconfirmed, not attached
          end if;
        end if;
      end if;
    end if;
  end if;

  perform pg_advisory_xact_lock(hashtext('sb827_auth_refusal'));

  select count(*) into v_global
    from public.external_connection_audit_log a
   where a.connection_id is null and a.created_at > now() - interval '60 seconds';

  if v_principal is null then
    select count(*) into v_bucket
      from public.external_connection_audit_log a
     where a.connection_id is null and a.principal_user_id is null
       and a.created_at > now() - interval '60 seconds';
  else
    select count(*) into v_bucket
      from public.external_connection_audit_log a
     where a.principal_user_id = v_principal and a.operation = 'auth'
       and a.created_at > now() - interval '60 seconds';
  end if;

  if v_bucket < k_bucket_cap and (v_conn is not null or v_global < k_global_cap) then
    insert into public.external_connection_audit_log
      (connection_id, principal_user_id, oauth_client_id, tool_name, resource_name, operation,
       project_id, outcome, reason_code, trace_id, result_rows)
    values (v_conn, v_principal, v_clientcol, null, null, 'auth', null,
            case when v_reason = 'identity_check_error' then 'error' else 'denied' end,
            v_reason, p_trace_id, null);
  elsif not exists (
    select 1 from public.external_connection_audit_log a
     where a.operation = 'auth' and a.reason_code = 'auth_refusals_throttled'
       and a.principal_user_id is not distinct from v_principal
       and a.created_at > now() - interval '60 seconds') then
    insert into public.external_connection_audit_log
      (connection_id, principal_user_id, oauth_client_id, operation, outcome, reason_code, trace_id)
    values (v_conn, v_principal, v_clientcol, 'auth', 'denied', 'auth_refusals_throttled', p_trace_id);
  end if;
  -- else: suppressed. Returns nothing in every case, so callers learn no state.
end $function$;

COMMENT ON FUNCTION public.external_connection_record_auth_refusal(text, uuid) IS
  'SB-827: one throttled audit row per identity refusal at family-codex-mcp. Deliberate, narrow exception to SB-443: '
  'anon may execute because refusals happen before any identity exists. Takes no connection id, returns nothing, '
  'stores no token; client id only from the verified claim.';

-- SB-827 D2 (3/3): grants.
REVOKE ALL ON FUNCTION public.external_connection_record_auth_refusal(text, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.external_connection_record_auth_refusal(text, uuid) TO anon, authenticated, service_role;

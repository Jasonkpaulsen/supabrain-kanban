ALTER FUNCTION enforce_authority_governance() SET search_path = public;
ALTER FUNCTION audit_authority_governance() SET search_path = public;
REVOKE EXECUTE ON FUNCTION enforce_authority_governance() FROM anon, authenticated, public;
REVOKE EXECUTE ON FUNCTION audit_authority_governance() FROM anon, authenticated, public;;

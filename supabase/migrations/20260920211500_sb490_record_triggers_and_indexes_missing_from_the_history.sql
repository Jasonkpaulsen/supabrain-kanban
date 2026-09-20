-- SB-490: fifteen objects that exist in production and are created by no migration.
--
-- Found by the static reconciliation (TC-SB439-V6), which swept policies,
-- triggers and indexes for the first time. TC-SB439-V1 swept functions, tables
-- and views in September and found zero unaccounted; every defect since has
-- been in a class V1 did not cover, and this is the rest of that gap.
--
-- None of these breaks a replay -- nothing references them, which is why seven
-- paid branch cycles never surfaced one. The cost is quieter: a rebuilt copy
-- would be missing four triggers and eleven indexes and would NOT error. It
-- would behave differently and run slower, which is the worst kind of
-- difference.
--
-- Definitions are rendered by pg_get_triggerdef and pg_get_indexdef, not
-- transcribed (ADR-DL-003 clause 4). Idempotent forms are used so the
-- statements are safe if anyone ever executes them, and so a replay that runs
-- twice is harmless.
--
-- WHAT IS HERE, and why each is wanted:
--
--   protect_sentinel_columns_trigger (trade_signals)
--     A guardrail on the trading table. Losing it in a rebuild loses a control,
--     silently. The most important object in this migration.
--   trg_generate_skill_embedding (skills)
--     Drives the skill embedding pipeline. Note it is one of the two triggers
--     TC-CLSRM-39-9 records as a residual risk: it gates regeneration on a fixed
--     column list while the edge function re-reads the whole row.
--   trg_normalize_skill_file_path (skills)
--     Normalises source_path on write. Worth knowing next to SB-319, which
--     reports six different source_path shapes in this table: the trigger
--     exists and the data is still inconsistent, so it does not do what SB-319
--     needs.
--   trigger_update_research_briefs_updated_at (research_briefs)
--     Without it updated_at silently freezes.
--   eleven indexes
--     Nine are measurably in use over a 220-day statistics window
--     (idx_wi_user_project_status alone: 50,557 scans). Two on trade_signals
--     show zero scans, which is explained by the table holding 47 rows -- the
--     planner will not use an index at that size -- and the KEL pipeline still
--     being in paper-trading validation. They are kept.
--
-- WHAT IS DELIBERATELY ABSENT, and why -- the same treatment 20260531010318
-- gave the classroom_writer policies. These two stay flagged by the coverage
-- scan on purpose, so the open question stays visible instead of being
-- enshrined by this migration:
--
--   idx_wi_attention (work_items)
--     Zero scans in 220 days on the busiest table in the database, which had
--     50,557 scans on another index in the same window. Table size does not
--     explain it. This index appears genuinely unused and the right change is
--     to DROP it, not to record it. Raised separately.
--   users_insert_own (lce_deletion_log)
--     Lets an authenticated user INSERT rows into a purge audit trail. The
--     migration that created that table (20260613144741, ADR-LCE-003) granted
--     authenticated read only, and deliberately: the log is written by the
--     retention job. Only service_role and postgres have ever touched the table
--     in 220 days. This looks like drift that weakens an audit surface, and
--     enshrining it in the history would make a questionable grant official.
--     Raised separately as a security question.
--
-- Recorded as applied without having run. Every object already exists in
-- production with these exact definitions, so the end state is unchanged by
-- construction and production is not touched.
CREATE OR REPLACE TRIGGER protect_sentinel_columns_trigger BEFORE UPDATE ON public.trade_signals FOR EACH ROW EXECUTE FUNCTION protect_sentinel_columns();
CREATE OR REPLACE TRIGGER trg_generate_skill_embedding AFTER INSERT OR UPDATE OF name, description, rules, examples, tags, content ON public.skills FOR EACH ROW EXECUTE FUNCTION fn_trigger_skill_embedding();
CREATE OR REPLACE TRIGGER trg_normalize_skill_file_path BEFORE INSERT OR UPDATE ON public.skills FOR EACH ROW EXECUTE FUNCTION fn_normalize_skill_file_path();
CREATE OR REPLACE TRIGGER trigger_update_research_briefs_updated_at BEFORE UPDATE ON public.research_briefs FOR EACH ROW EXECUTE FUNCTION update_updated_at();
CREATE INDEX IF NOT EXISTS idx_briefings_user_date ON public.jarvis_briefings USING btree (user_id, briefing_date DESC);
CREATE INDEX IF NOT EXISTS idx_projects_triage_suspended ON public.projects USING btree ((((meta -> 'triage_suspension'::text) ->> 'suspended'::text))) WHERE ((meta -> 'triage_suspension'::text) IS NOT NULL);
CREATE INDEX IF NOT EXISTS idx_signals_consumable ON public.trade_signals USING btree (user_id, status, sentinel_cleared, rating DESC) WHERE ((status = 'proposed'::text) AND (sentinel_cleared = true) AND (archived = false));
CREATE INDEX IF NOT EXISTS idx_signals_pending_review ON public.trade_signals USING btree (user_id, sentinel_cleared, created_at DESC) WHERE ((status = 'proposed'::text) AND (sentinel_cleared = false));
CREATE INDEX IF NOT EXISTS idx_signals_settled ON public.trade_signals USING btree (user_id, settled_at DESC) WHERE (outcome IS NOT NULL);
CREATE INDEX IF NOT EXISTS idx_test_cases_project_status ON public.test_cases USING btree (user_id, project_id, status);
CREATE INDEX IF NOT EXISTS idx_test_runs_bug_ticket ON public.test_runs USING btree (bug_ticket_id) WHERE (bug_ticket_id IS NOT NULL);
CREATE INDEX IF NOT EXISTS idx_test_runs_case_result ON public.test_runs USING btree (test_case_id, result);
CREATE INDEX IF NOT EXISTS idx_wi_completed ON public.work_items USING btree (user_id, completed_at DESC) WHERE (status = 'done'::text);
CREATE INDEX IF NOT EXISTS idx_wi_user_project_status ON public.work_items USING btree (user_id, project_id, status);
CREATE INDEX IF NOT EXISTS idx_wi_user_status_sort ON public.work_items USING btree (user_id, status, sort_order);

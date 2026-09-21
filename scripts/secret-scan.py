#!/usr/bin/env python3
"""SB-446 — refuse a commit that carries a credential.

Four live secrets have been found in this project (SB-408, SB-440, SB-447,
SB-493). SB-440 was committed by a model into a migration in this PUBLIC
repository and sat there for weeks; it was found by a QA definition pull, not
by review, and a second reviewer would not have caught it either because it
looked like ordinary migration boilerplate.

That class is caught by a grep, not by judgement. This is the grep.

DESIGN: precision over recall. A blocking gate that cries wolf gets disabled,
and a disabled gate catches nothing. So the rules target the shapes that
ACTUALLY occurred in this repository's history rather than sweeping for
entropy everywhere. Each rule names the incident it comes from.

Run `--self-test` to prove the rules still fire on those incidents. A detector
is not believed until it reproduces known failures (ADR-TEST-002); the first
five scans written for this project were wrong, so this one carries its own
backtest and CI runs it before it runs the scan.
"""

from __future__ import annotations
import argparse, hashlib, json, re, subprocess, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ALLOW_FILE = ROOT / ".secret-scan-allow.json"

SCAN_EXT = {".sql", ".ts", ".js", ".mjs", ".json", ".html", ".yml", ".yaml", ".sh", ".py", ".md"}
SKIP_DIRS = {".git", "node_modules", "test-results", "playwright-report", ".temp", "dist", "build"}

# A value that is plainly not a secret: an env read, a Vault read, a helper
# call, a placeholder, or a template substitution.
NOT_A_SECRET = re.compile(
    r"""(
        Deno\.env\.get | process\.env | os\.environ | getenv
      | decrypted_secret | vault\. | _headers\s*\( | _token_matches\s*\(
      | \$\{ | \{\{ | <[A-Za-z_ -]+> | %s | \$[0-9]
        # Placeholder words. The trailing (?:[-_. ]|$) is load-bearing: without
        # it these matched as bare PREFIXES, so any real secret beginning with
        # "a", "x", "y", "the", "some"... was silently excused -- roughly one
        # random token in five. The backtest caught it on the Bearer fixture.
      | ^(?:x{1,3}|y|your|my|the|a|an|some|test|fake|dummy|example|sample|placeholder|changeme|redacted|replace|todo|none|null|undefined|true|false)(?:[-_. ]|$)
      | ^(?:application|text|multipart)/        # content types
      | ^Bearer\s*$ | ^\s*$
    )""",
    re.X | re.I,
)

# Keys whose VALUE is a credential when it is a literal.
CRED_KEY = r"(?:x-token|x-api-key|api[-_]?key|apikey|authorization|auth[-_]?token|service[-_]?role[-_]?key|anon[-_]?key|password|passwd|secret|dsn|connection[-_]?string)"

RULES = [
    dict(
        id="HEADER_TOKEN_LITERAL",
        incident="SB-440 (agent-runner token in a committed migration), SB-493 (lce-cleanup token in cron.job.command)",
        why="A credential written as the value of an auth header, in SQL or TypeScript.",
        # "x-token":"VALUE"  |  'x-token': 'VALUE'  |  x-token = "VALUE"
        pattern=re.compile(
            r"""["']?\b""" + CRED_KEY + r"""\b["']?\s*(?::|:=|=|,)\s*["']([^"'\n]{8,})["']""",
            re.I,
        ),
        group=1,
    ),
    dict(
        id="CREDENTIAL_CONSTANT",
        incident="SB-493 (const TOKEN = \"...\" in the deployed lce-cleanup source)",
        why="A credential assigned to a named constant instead of read from Vault or the environment.",
        pattern=re.compile(
            r"""\b(?:const|let|var|final)\s+[A-Za-z_]*(?:TOKEN|SECRET|APIKEY|API_KEY|PASSWORD|DSN|CREDENTIAL)[A-Za-z_]*\s*(?::\s*\w+\s*)?=\s*["']([^"'\n]{8,})["']""",
            re.I,
        ),
        group=1,
    ),
    dict(
        id="LONG_OPAQUE_LITERAL",
        incident="SB-440 — the shape a base64/hex secret takes inside a migration or an edge function.",
        why="A long opaque string literal in supabase/functions or supabase/migrations.",
        pattern=re.compile(r"""["']([A-Za-z0-9+/_-]{32,}={0,2})["']"""),
        group=1,
        paths=("supabase/functions/", "supabase/migrations/"),
    ),
]

# REVOKE_FROM_PUBLIC_ONLY is not a line rule.
#
# The first version was: any `revoke ... from public;` is suspect. CI proved
# that wrong within a minute of shipping -- it flagged SB-440's own fix, where
# line 24 revokes from public and a later line revokes from anon and
# authenticated. Live grants confirmed those functions have no client access at
# all, so every hit was false.
#
# That is the TC-SB481-V4 failure mode: a check that resolves to an easier
# question than the one asked. The question is not "does this statement name
# only PUBLIC" but "is this function LEFT reachable by a client role after the
# whole file has run". So gather every revoke per target and judge the union.
REVOKE_RE = re.compile(
    r"revoke\s+(?:all|execute)[^;]*?\bon\s+function\s+([^;]+?)\s+from\s+([^;]+);",
    re.I | re.S,
)


def revoke_findings(rel: str, text: str) -> list[dict]:
    targets: dict[str, dict] = {}
    for m in REVOKE_RE.finditer(text):
        sig = re.sub(r"\s+", " ", m.group(1)).strip().lower()
        roles = {r.strip().lower() for r in m.group(2).split(",")}
        t = targets.setdefault(sig, {"roles": set(), "line": text.count("\n", 0, m.start()) + 1})
        t["roles"] |= roles
    out = []
    for sig, t in targets.items():
        if "public" in t["roles"] and not (t["roles"] & {"anon", "authenticated"}):
            out.append(dict(
                rule="REVOKE_FROM_PUBLIC_ONLY", file=rel, line=t["line"],
                fingerprint=fingerprint(sig), blocking=True, kind="antipattern",
                incident="SB-408, and the same mistake repeated inside SB-440's own fix.",
                why=("REVOKE ... FROM PUBLIC does not undo Supabase's default ACL grants, which "
                     "are made to anon and authenticated BY ROLE NAME. This file revokes "
                     f"{sorted(t['roles'])} on this function and never names anon or "
                     "authenticated, so a client role may still hold EXECUTE."),
                preview=f"revoke on function {sig} from {sorted(t['roles'])}"))
    return out

# Hashes are not secrets; they appear legitimately in this repo's migration notes.
HASH_LEN = {32, 40, 64}  # md5, sha1, sha256 rendered as hex

# Shapes that are long and opaque but structurally NOT credentials. The first
# repo-wide run produced 188 findings and all but a handful were UUIDs seeded
# into migrations. A gate that cries wolf gets switched off, and a switched-off
# gate catches nothing -- so these are excluded by structure rather than
# absolved one-by-one in the allowlist.
UUID_RE = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", re.I)
IDENTIFIER_RE = re.compile(r"^[a-z][a-z0-9]*(?:[_-][a-z0-9]+)+$")   # anon_exposure_check, my-thing-name


def is_structural(v: str) -> bool:
    """True when a long literal is a UUID or a snake/kebab identifier, not a secret."""
    if UUID_RE.match(v) or IDENTIFIER_RE.match(v):
        return True
    # A credential mixes character classes. Require at least two of
    # lower/upper/digit; UUIDs and slugs fail this, base64 and JWTs pass.
    classes = sum(bool(re.search(c, v)) for c in (r"[a-z]", r"[A-Z]", r"[0-9]"))
    return classes < 2


def fingerprint(value: str) -> str:
    return hashlib.sha256(value.encode()).hexdigest()[:16]


def load_allow() -> dict:
    """Allowlist keyed by (fingerprint, file).

    Deliberately NOT keyed by value alone. The dead SB-440 token is excused in
    the one applied migration that historically carries it -- but if anyone
    pastes that same literal into a new file, that is a fresh act and must
    fail, which is exactly what this ticket's acceptance criterion asks for.
    An excuse is for a place, not for a string.
    """
    if not ALLOW_FILE.exists():
        return {}
    out = {}
    for e in json.loads(ALLOW_FILE.read_text())["allow"]:
        for loc in e["locations"]:
            out[(e["fingerprint"], loc.rsplit(":", 1)[0])] = e
    return out


def looks_like_hash(v: str) -> bool:
    return len(v) in HASH_LEN and re.fullmatch(r"[0-9a-f]+", v, re.I) is not None


def scan_text(rel: str, text: str, allow: dict, new_lines_only: bool = False) -> list[dict]:
    """Scan one file's text.

    new_lines_only: when False we are looking at the whole tree, and the
    anti-pattern rules are informational rather than blocking. A bad REVOKE in
    an applied migration is a historical fact -- the migration ran, the grant
    state it produced is what it is, and SB-488's runtime audit is what checks
    that. Editing applied history to satisfy a linter would be the wrong fix,
    and failing every future commit over 21 rows of history would get this gate
    switched off within a day. What matters is that nobody adds a NEW one, so
    that rule blocks on the diff and merely reports on the tree.
    """
    out = []
    for f in revoke_findings(rel, text):
        if (f["fingerprint"], rel) in allow:
            continue
        f["blocking"] = new_lines_only      # advisory across applied history
        out.append(f)
    for rule in RULES:
        if "paths" in rule and not any(rel.startswith(p) for p in rule["paths"]):
            continue
        blocking = True
        for m in rule["pattern"].finditer(text):
            value = m.group(rule["group"])
            if True:
                # An Authorization value is "<scheme> <credential>". Judge the
                # credential, not the scheme -- the backtest caught this: the
                # whitespace-means-prose heuristic below was swallowing
                # `authorization: "Bearer <token>"` whole, which is the single
                # most common way a credential is written.
                value = re.sub(r"^\s*(?:Bearer|Basic|Token|ApiKey)\s+", "", value, flags=re.I)
                if NOT_A_SECRET.search(value) or looks_like_hash(value):
                    continue
                if rule["id"] == "LONG_OPAQUE_LITERAL" and is_structural(value):
                    continue
                # a literal with whitespace or a path separator is prose, not a token
                if re.search(r"\s|^/|\.(?:ts|sql|js|md|html|png|json)$", value):
                    continue
            fp = fingerprint(value)
            if (fp, rel) in allow:
                continue
            line = text.count("\n", 0, m.start()) + 1
            out.append(dict(rule=rule["id"], file=rel, line=line, fingerprint=fp, blocking=blocking,
                            incident=rule["incident"], why=rule["why"],
                            preview=value[:6] + "…" + f"[{len(value)} chars]"))
    return out


def staged_paths() -> list[str]:
    """Paths git is about to commit, filtered to types we scan."""
    out = subprocess.run(["git", "diff", "--cached", "--name-only", "--diff-filter=ACM"],
                         cwd=ROOT, capture_output=True, text=True).stdout
    return [f for f in out.splitlines() if f and Path(f).suffix in SCAN_EXT]


def read_staged(rel: str) -> str | None:
    """The bytes git will commit for `rel`, or None if there are none.

    SB-496: --staged used to take its file list from the index and then read the
    contents FROM DISK. Those are different bytes, so the hook judged something
    git was not about to commit. Reproduced both ways: a clean staged blob with
    a dirty tree refused a good commit, and -- the one that matters -- a
    credential staged with a clean tree PASSED and was committed. `git add`
    then edit is ordinary, and `git add -p` produces it every time.

    Reading from the index also fixes a second hole in the same area: the old
    path required the file to exist on disk, so staging a secret and then
    deleting the working copy skipped the file entirely.

    argv is passed as a list, never interpolated into a shell, so paths with
    spaces or non-ASCII names are safe.
    """
    r = subprocess.run(["git", "show", f":{rel}"], cwd=ROOT, capture_output=True)
    if r.returncode != 0:
        return None          # staged for deletion, or otherwise not in the index
    return r.stdout.decode("utf-8", errors="replace")


def files_to_scan(only: list[str] | None) -> list[Path]:
    if only:
        return [ROOT / f for f in only if (ROOT / f).is_file()]
    found, skipped = [], 0
    for p in ROOT.rglob("*"):
        if not p.is_file():
            continue
        if any(part in SKIP_DIRS for part in p.relative_to(ROOT).parts):
            continue
        if p.suffix not in SCAN_EXT:
            # SCAN_EXT is an allowlist, so an unlisted type is skipped. Count
            # them so the gap is visible: a future .env, .toml or Dockerfile
            # would be skipped the same way, and .env is the commonest place a
            # credential lands.
            skipped += 1
            continue
        found.append(p)
    files_to_scan.skipped_for_extension = skipped
    return found


files_to_scan.skipped_for_extension = 0


# --------------------------------------------------------------------------
# Backtest. Every POSITIVE below is the real shape of a real incident, with the
# value replaced. Every NEGATIVE is the fixed form now in the repository.
# --------------------------------------------------------------------------
POSITIVES = [
    ("SB-440: token in a migration's http_post headers", "supabase/migrations/x.sql",
     """select net.http_post(url:='https://x.supabase.co/functions/v1/agent-runner',"""
     """ headers:='{"Content-Type":"application/json","x-token":"Nx7Qv2ZbK4tR9mLpW1yE"}'::jsonb);"""),
    ("SB-493: credential constant in an edge function", "supabase/functions/lce-cleanup/index.ts",
     '''const TOKEN = "lce-ing-7Qv2ZbK4tR9m";'''),
    ("SB-493: token in cron.job.command", "supabase/migrations/y.sql",
     """headers:='{"x-token":"lce-ing-7Qv2ZbK4tR9m"}'::jsonb"""),
    ("SB-447 shape: service-role key assigned to a constant", "supabase/functions/f/index.ts",
     '''const SERVICE_ROLE_KEY = "sbp_0123456789abcdefghijklmnopqrstuvwxyz";'''),
    ("Bearer credential in a TS header object", "supabase/functions/f/index.ts",
     '''headers: { authorization: "Bearer aK9x2Lm4Qv7ZbR1tE5yW" }'''),
    ("SB-408: a function whose only revoke names PUBLIC", "supabase/migrations/z.sql",
     """revoke all on function public.classroom_get_secret(text) from public;"""),
    ("A base64 token pasted bare into a migration (must survive the UUID tightening)",
     "supabase/migrations/w.sql",
     """select set_config('app.tok', 'k3Jx9QvZb2Rt7mLpW1yE4aNcH8sUdF6gTyQwErTz', false);"""),
]

NEGATIVES = [
    ("Vault helper supplies the headers", "supabase/migrations/a.sql",
     """headers:=public.agent_runner_headers(),"""),
    ("Vault read inside a SECURITY DEFINER accessor", "supabase/migrations/b.sql",
     """'x-token', (select s.decrypted_secret from vault.decrypted_secrets s where s.name = 'lce_cleanup_token')"""),
    ("Token read from the environment", "supabase/functions/f/index.ts",
     '''const apiKey = Deno.env.get("ANTHROPIC_API_KEY");'''),
    ("Token compared via the database, never held", "supabase/functions/f/index.ts",
     '''const { data: ok } = await sb.rpc("lce_cleanup_token_matches", { p_token: presented });'''),
    ("Revoke that names the roles explicitly", "supabase/migrations/c.sql",
     """revoke all on function public.f() from public, anon, authenticated;"""),
    ("SB-440's real shape: public on one line, the roles on another",
     "supabase/migrations/g.sql",
     """revoke all on function public.agent_runner_headers() from public;\n"""
     """revoke all on function public.agent_runner_headers() from anon;\n"""
     """revoke all on function public.agent_runner_headers() from authenticated;\n"""
     """grant execute on function public.agent_runner_headers() to service_role;"""),
    ("An md5 recorded in a migration note", "supabase/migrations/d.sql",
     """-- md5 9d18a76ad3fb8712a89a0c95593ef9b5 matches the history row"""),
    ("A content-type header", "supabase/functions/f/index.ts",
     '''headers: { "content-type": "application/json" }'''),
    ("A seeded UUID in a migration", "supabase/migrations/e.sql",
     """insert into projects (id) values ('5ecbd44a-a3e2-4363-9133-dff3851ba0f5');"""),
    ("A snake_case identifier literal", "supabase/migrations/f.sql",
     """where check_name = 'anon_exposure_detected_today';"""),
]


def _git(cwd, *args):
    return subprocess.run(["git", *args], cwd=cwd, capture_output=True, text=True)


def staged_integration_test() -> tuple[int, int]:
    """SB-496: does --staged judge the bytes git is about to commit?

    This cannot be a rule fixture. Every rule was already correct when this bug
    shipped; the defect was in WHICH BYTES the rules were pointed at. So the
    only test that can see it drives a real index: stage one thing, write
    another, and check the exit code.

    Asserts on behaviour -- the process exit status -- not on whether the
    source happens to contain "git show". This project has twice shipped
    assertions that checked structure while the failure was in behaviour
    (CLSRM-39 part 2, TC-SB481-V4).
    """
    import shutil, tempfile
    if not shutil.which("git"):
        print("  [skip ] git unavailable -- staged-index cases NOT run (this is a gap, not a pass)")
        return 0, 0

    SECRET_FILE = 'const TOKEN = "Nx7Qv2ZbK4tR9mLpW1yE";\n'
    CLEAN_FILE = 'const cfg = { name: "clean" };\n'
    rel = "supabase/functions/probe/index.ts"
    ran = bad = 0

    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        (tmp / "scripts").mkdir()
        shutil.copy(Path(__file__), tmp / "scripts" / "secret-scan.py")
        (tmp / rel).parent.mkdir(parents=True)
        _git(tmp, "init", "-q")

        def run_staged():
            return subprocess.run([sys.executable, str(tmp / "scripts" / "secret-scan.py"), "--staged"],
                                  cwd=tmp, capture_output=True, text=True).returncode

        # 1. secret in the index, working tree cleaned afterwards -> must FAIL
        (tmp / rel).write_text(SECRET_FILE)
        _git(tmp, "add", rel)
        (tmp / rel).write_text(CLEAN_FILE)
        rc = run_staged(); ran += 1
        ok = rc == 1
        bad += 0 if ok else 1
        print(f"  [{'CATCH' if ok else 'MISS '}] credential staged, working tree clean -> exit {rc}"
              + ("" if ok else "   <-- the secret would be COMMITTED"))

        # 2. clean index, dirty working tree -> must PASS (no false positive)
        (tmp / rel).write_text(CLEAN_FILE)
        _git(tmp, "add", rel)
        (tmp / rel).write_text(SECRET_FILE)
        rc = run_staged(); ran += 1
        ok = rc == 0
        bad += 0 if ok else 1
        print(f"  [{'clean' if ok else 'FALSE'}] clean staged, working tree dirty -> exit {rc}"
              + ("" if ok else "   <-- refuses a commit git would not make"))

        # 3. staged for deletion -> must not crash
        _git(tmp, "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-qm", "base")
        _git(tmp, "rm", "-q", rel)
        rc = run_staged(); ran += 1
        ok = rc in (0, 1)
        bad += 0 if ok else 1
        print(f"  [{'clean' if ok else 'CRASH'}] path staged for deletion -> exit {rc}")

    return ran, bad


def self_test() -> int:
    allow = {}
    bad = 0
    print("Backtest — the rules must fire on incidents that really happened:")
    for name, path, text in POSITIVES:
        hits = scan_text(path, text, allow, new_lines_only=True)
        ok = bool(hits)
        print(f"  [{'CATCH' if ok else 'MISS '}] {name}" + ("" if ok else "   <-- rule no longer detects this"))
        bad += 0 if ok else 1
    print("\nControl — the fixed forms now in the repo must NOT fire:")
    for name, path, text in NEGATIVES:
        hits = scan_text(path, text, allow, new_lines_only=True)
        ok = not hits
        print(f"  [{'clean' if ok else 'FALSE'}] {name}" + ("" if ok else f"   <-- {hits[0]['rule']}"))
        bad += 0 if ok else 1
    print("\nStaged-index cases -- do we judge the bytes git will commit? (SB-496):")
    int_ran, int_bad = staged_integration_test()
    bad += int_bad
    print()
    if bad:
        print(f"SELF-TEST FAILED: {bad} case(s) wrong. The scanner is not trustworthy; fix it before trusting a clean scan.")
        return 1
    print(f"SELF-TEST PASSED: {len(POSITIVES)} incidents caught, {len(NEGATIVES)} clean forms "
          f"not flagged, {int_ran} staged-index case(s) correct.")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description="Fail on a credential committed to this repository.")
    ap.add_argument("--self-test", action="store_true", help="prove the rules still catch the known incidents")
    ap.add_argument("--staged", action="store_true", help="scan only files staged for commit")
    ap.add_argument("--staged-like", nargs="*", default=None, metavar="FILE",
                    help="treat these files as newly added (blocks on anti-patterns too)")
    ap.add_argument("files", nargs="*", help="specific files to scan")
    args = ap.parse_args()

    if args.self_test:
        return self_test()

    only = args.files or None
    new_lines = bool(args.staged)
    if args.staged_like is not None:
        only = [f for f in args.staged_like if Path(f).suffix in SCAN_EXT]
        new_lines = True
        if not only:
            print("secret-scan: no scannable files in the change set.")
            return 0
    allow = load_allow()
    findings = []
    scanned = 0

    if args.staged:
        paths = staged_paths()
        if not paths:
            print("secret-scan: nothing staged to scan.")
            return 0
        for rel in paths:
            text = read_staged(rel)
            if text is None:
                continue
            scanned += 1
            findings += scan_text(rel, text, allow, new_lines_only=True)
    else:
        for p in files_to_scan(only):
            rel = str(p.relative_to(ROOT))
            try:
                text = p.read_text(errors="replace")
            except OSError:
                continue
            scanned += 1
            findings += scan_text(rel, text, allow, new_lines_only=new_lines)

    blocking = [f for f in findings if f["blocking"]]
    advisory = [f for f in findings if not f["blocking"]]

    if advisory:
        by_rule: dict[str, int] = {}
        for f in advisory:
            by_rule[f["rule"]] = by_rule.get(f["rule"], 0) + 1
        print("secret-scan: advisory (historical, not blocking) — "
              + ", ".join(f"{n}x {r}" for r, n in sorted(by_rule.items())))
        print("  These sit in already-applied migrations. They are a record of what ran, not")
        print("  something to edit now; SB-488's runtime grant audit is what checks the live")
        print("  state. This rule blocks only on newly added lines.\n")

    if not blocking:
        extra = ""
        if not args.staged and files_to_scan.skipped_for_extension:
            extra = (f", {files_to_scan.skipped_for_extension} skipped for extension"
                     f" (SCAN_EXT is an allowlist)")
        src = "staged" if args.staged else "files"
        print(f"secret-scan: clean ({scanned} {src}, {len(allow)} allowlisted value(s){extra}).")
        return 0

    findings = blocking
    print(f"secret-scan: {len(findings)} blocking finding(s).\n")
    for f in findings:
        print(f"  {f['file']}:{f['line']}  [{f['rule']}]")
        print(f"      value: {f['preview']}")
        print(f"      why:   {f['why']}")
        print(f"      seen:  {f['incident']}")
        print(f"      If this is genuinely not a credential, add fingerprint {f['fingerprint']}")
        print(f"             for path {f['file']} to .secret-scan-allow.json WITH A REASON.")
        print(f"             Do not widen the rule, and do not paste the value itself.\n")
    print("Refusing the commit. A credential in this repository is public the moment it is pushed;")
    print("rotate anything that has already been exposed rather than deleting it quietly.")
    return 1


if __name__ == "__main__":
    sys.exit(main())

---
description: "Safe, verified git commit — runs pull check, format, build, tests, then commits"
argument-hint: "[optional commit message override]"
allowed-tools: ["Bash", "Read", "Edit"]
---

# Safe Commit Command

Follow every phase in order. Stop and report on any failure — never commit with a broken build or failing tests.

---

## Phase 1 — Remote Divergence Check

```bash
git fetch origin 2>&1
git status -sb
git log HEAD..origin/$(git rev-parse --abbrev-ref HEAD) --oneline 2>/dev/null | head -10
```

- Remote has commits ahead → warn user, show them, stop. Ask them to `git pull` first.
- New branch (no remote) → proceed.
- Local ahead or even → proceed.

---

## Phase 2 — Sensitive File Guard

```bash
git diff --name-only HEAD 2>/dev/null; git ls-files --others --exclude-standard
```

Hard-block these — never stage or commit them:
- `.env`, `.env.*` (except `.env.example`)
- `*.pem`, `*.key`, `*.p12`, `*.pfx`
- Files with `PRIVATE_KEY`, `MNEMONIC`, `SECRET`, `PASSWORD` in the name
- `broadcast/*/run-latest.json`

Also scan for hardcoded private keys:
```bash
grep -rn "0x[0-9a-fA-F]\{64\}" --include="*.sol" --include="*.js" --include="*.ts" src/ script/ test/ 2>/dev/null | head -5
```
If any 64-char hex looks like a private key (not a contract address or tx hash) — warn and stop.

---

## Phase 3 — File Relevance Audit

```bash
git status --short
git ls-files --others --exclude-standard
```

**Unstage + gitignore** these if present:
- `out/`, `cache/`, `broadcast/` — Foundry artifacts
- `node_modules/` — NPM deps
- `*.log`, `history.txt`, `submission.txt` — runtime scratch
- `*.skill` — Claude Code skill archives (binary)
- `.claude/agent-memory/` — agent runtime state
- `.DS_Store`, `*.swp`, `*.swo`, `*.tmp`, `*.bak`

For any borderline file, ask the user before staging.

After any `.gitignore` changes, stage `.gitignore` itself.

Show a clean summary:
```
✅ Will commit:   src/VaultSentinel.sol, test/VaultSentinelTest.t.sol
🚫 Excluded:      out/, .env
📝 Gitignored:    Added N entries
```

---

## Phase 4 — Format Check

```bash
forge fmt --check 2>&1 | head -40
```

- Passes → proceed.
- Fails → run `forge fmt 2>&1`, then re-check with `forge fmt --check 2>&1 | head -10`. If still failing — stop and report.

---

## Phase 5 — Build

```bash
forge build 2>&1 | grep -E "^(Error|error\[|Compiler run|Compiling)" | head -20
BUILD_OK=${PIPESTATUS[0]}
```

Check exit code. If non-zero — show full output and stop:
```bash
[ $BUILD_OK -ne 0 ] && forge build 2>&1
```

---

## Phase 6 — Full Test Suite

```bash
forge test 2>&1 | grep -E "(FAIL|Suite result|Failing tests|Encountered a total)" | head -20
```

- All pass → the grep output will show only the passing Suite result line → proceed.
- Any failure → re-run `forge test --rerun 2>&1 | tail -60` to show failure traces, then stop.

---

## Phase 7 — Analyze Changes

```bash
git diff --staged --stat
git diff --stat
git log --oneline -6
```

Use the **stat** (file-level summary only) to understand what changed. Do NOT run `git diff --staged` (full diff) — it dumps every line and wastes context. You already know what changed from earlier phases.

---

## Phase 8 — Stage Files

```bash
git add -u
```

Stage new untracked source files individually by name if they belong to this commit. Never use `git add .` blindly.

```bash
git status
```

---

## Phase 9 — Commit

Title: `<type>(<scope>): <short imperative description>` — max 72 chars.
Types: `feat`, `fix`, `refactor`, `test`, `chore`, `docs`, `style`, `security`.

```bash
git commit -m "$(cat <<'EOF'
<title>

<optional body — why, not what. max 4 lines>

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
EOF
)"
```

---

## Phase 10 — Confirm

```bash
git log --oneline -3
git status
```

Report: commit hash + title, files included, test count, whether fmt was auto-applied.

---

## Failure Format

```
❌ ABORTED — Phase <N>: <Name>
Reason: <what failed>
Fix: <what to do>
```

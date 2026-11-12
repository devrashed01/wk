#!/bin/bash
# Runs Wk against a throwaway world of fake repos, worktrees and Claude sessions, for
# screenshots and demos. Your real config, state and sessions are not read or changed.
#   scripts/demo.sh            build the world in ~/wk-demo and start Wk on it
#   scripts/demo.sh --clean    quit the demo and delete ~/wk-demo
# WK_DEMO_DIR picks another folder; WK_APP picks another Wk.app.
set -euo pipefail

DEMO="${WK_DEMO_DIR:-$HOME/wk-demo}"
APP="${WK_APP:-$HOME/Applications/Wk.app}"
[ -d "$APP" ] || APP="/Applications/Wk.app"

pkill -x Wk 2>/dev/null || true
if [ "${1:-}" = "--clean" ]; then
  rm -rf "$DEMO"
  echo "Removed $DEMO. Start Wk again to get your own data back."
  exit 0
fi
[ -d "$APP" ] || { echo "Wk.app not found (run make install, or set WK_APP)" >&2; exit 1; }

rm -rf "$DEMO"
mkdir -p "$DEMO/code" "$DEMO/remotes" "$DEMO/claude/projects" "$DEMO/state" "$DEMO/cache" "$DEMO/bin"
DEMO="$(cd "$DEMO" && pwd -P)"
CODE="$DEMO/code"

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME="Sam Rivera" GIT_AUTHOR_EMAIL="sam@example.com"
export GIT_COMMITTER_NAME="Sam Rivera" GIT_COMMITTER_EMAIL="sam@example.com"

ago() { date -v-"$1" +%Y-%m-%dT%H:%M:%S; }   # ago 3H, ago 2d

# commit <dir> <age> <message>: one file change, dated in the past.
commit() {
  local dir="$1" when; when="$(ago "$2")"
  echo "$3" >> "$dir/CHANGELOG.md"
  git -C "$dir" add -A
  GIT_AUTHOR_DATE="$when" GIT_COMMITTER_DATE="$when" git -C "$dir" commit -q -m "$3"
}

# repo <name>: main branch, an origin remote, a little history.
repo() {
  local dir="$CODE/$1" remote="$DEMO/remotes/$1.git"
  git init -q --bare -b main "$remote"
  git init -q -b main "$dir"
  printf '# %s\n' "$1" > "$dir/README.md"
  printf 'API_URL=http://localhost:4000\n' > "$dir/.env"
  printf '.env\nnode_modules\n' > "$dir/.gitignore"
  commit "$dir" 60d "chore: project setup"
  commit "$dir" 21d "feat: account settings page"
  commit "$dir" 9d "fix: retry failed uploads"
  git -C "$dir" remote add origin "$remote"
  git -C "$dir" push -q -u origin main
}

# branch <repo> <name> <worktree-slug|-> <age> <message>...: a feature branch with commits, pushed.
branch() {
  local name="$1" branch="$2" slug="$3"; shift 3
  local main="$CODE/$name" dir="$CODE/$name"
  if [ "$slug" = "-" ]; then
    git -C "$main" switch -q -c "$branch" main
  else
    dir="$CODE/$name-$slug"
    git -C "$main" worktree add -q -b "$branch" "$dir" main
  fi
  while [ $# -gt 1 ]; do commit "$dir" "$1" "$2"; shift 2; done
  git -C "$dir" push -q -u origin "$branch"
  [ "$slug" = "-" ] && git -C "$main" switch -q main
  return 0
}

repo acme-web
repo acme-api
repo acme-mobile

branch acme-web ACME-412-checkout-redesign checkout 3d "feat(checkout): new order summary" 1d "feat(checkout): address autocomplete" 2H "fix(checkout): keep coupon after refresh"
branch acme-web ACME-398-dark-mode dark-mode 6d "feat(theme): dark palette tokens" 4d "feat(theme): follow system appearance"
branch acme-web ACME-377-search-filters - 12d "feat(search): price and rating filters"
branch acme-web ACME-350-onboarding-tour - 26d "feat(onboarding): first-run tour"
branch acme-api ACME-405-rate-limits rate-limits 2d "feat(api): per-key rate limits" 5H "test(api): burst and refill cases"
branch acme-api ACME-388-webhook-retries - 8d "feat(webhooks): exponential backoff"
branch acme-mobile ACME-420-offline-sync offline 1d "feat(sync): queue writes while offline" 40M "fix(sync): resolve conflicts by updated_at"

# Work in progress: uncommitted files and unpushed commits.
echo "export const summary = true" > "$CODE/acme-web-checkout/summary.ts"
echo "wip" >> "$CODE/acme-web-checkout/README.md"
commit "$CODE/acme-api-rate-limits" 20M "docs(api): rate limit headers"
echo "retry" >> "$CODE/acme-mobile-offline/README.md"

# Cleanup material: one branch already merged, one whose remote branch was deleted.
merged="$(ago 5d)"
GIT_AUTHOR_DATE="$merged" GIT_COMMITTER_DATE="$merged" git -C "$CODE/acme-web" merge -q --no-ff -m "Merge ACME-350-onboarding-tour" ACME-350-onboarding-tour
git -C "$CODE/acme-web" push -q origin main
git -C "$CODE/acme-api" push -q origin --delete ACME-388-webhook-retries
git -C "$CODE/acme-api" fetch -q --prune

# Fake cmux: two workspaces are "open", everything else succeeds quietly.
cat > "$DEMO/bin/cmux" <<CMUX
#!/bin/sh
case "\$*" in
  *"workspace list"*) cat "$DEMO/workspaces.json" ;;
esac
exit 0
CMUX
chmod +x "$DEMO/bin/cmux"

cat > "$DEMO/config.toml" <<TOML
roots = ["$CODE"]
recent_days = 30
claude_dir = "$DEMO/claude"
cmux_bin = "$DEMO/bin/cmux"
hotkey = "option+space"
label_strip_prefixes = ["acme-"]

[repo."$CODE/acme-web"]
server_cmd = "pnpm dev"

[repo."$CODE/acme-api"]
server_cmd = "go run ./cmd/server"
TOML

# Claude transcripts, workspaces and live-session records.
python3 - "$DEMO" <<'PY'
import json, os, sys, datetime
demo = sys.argv[1]
code = demo + "/code"
now = datetime.datetime.now(datetime.timezone.utc)

def stamp(minutes): return (now - datetime.timedelta(minutes=minutes)).strftime("%Y-%m-%dT%H:%M:%S.000Z")

# (id, folder, branch, title, first prompt, minutes ago, size in KB)
sessions = [
    ("5f1c2a70-0001-4a11-9c01-aaaaaaaa0001", "acme-web-checkout", "ACME-412-checkout-redesign", "Checkout redesign: order summary", "Rebuild the order summary panel to match the new design", 6, 1840),
    ("5f1c2a70-0002-4a11-9c01-aaaaaaaa0002", "acme-web-checkout", "ACME-412-checkout-redesign", "Address autocomplete review", "Review the address autocomplete for edge cases", 1500, 420),
    ("5f1c2a70-0003-4a11-9c01-aaaaaaaa0003", "acme-api-rate-limits", "ACME-405-rate-limits", "Per-key rate limiting", "Add token-bucket rate limits per API key", 24, 960),
    ("5f1c2a70-0004-4a11-9c01-aaaaaaaa0004", "acme-mobile-offline", "ACME-420-offline-sync", "Offline sync conflict rules", "Design conflict resolution for offline writes", 55, 2600),
    ("5f1c2a70-0005-4a11-9c01-aaaaaaaa0005", "acme-web-dark-mode", "ACME-398-dark-mode", "Dark mode tokens", "Create dark palette tokens and wire them into the theme", 5800, 310),
    ("5f1c2a70-0006-4a11-9c01-aaaaaaaa0006", "acme-web", "ACME-377-search-filters", "Search filters: price and rating", "Add price and rating filters to search", 17000, 540),
    ("5f1c2a70-0007-4a11-9c01-aaaaaaaa0007", "acme-web", "main", "Upgrade to React 19", "Plan the React 19 upgrade", 9000, 720),
    ("5f1c2a70-0008-4a11-9c01-aaaaaaaa0008", "acme-api", "main", "Flaky integration tests", "Find out why the integration tests are flaky on CI", 30000, 150),
    ("5f1c2a70-0009-4a11-9c01-aaaaaaaa0009", "acme-web-old-banner", "ACME-301-promo-banner", "Promo banner experiment", "Try a dismissible promo banner", 52000, 90),
]
filler = "Reading the surrounding code and tests before changing anything. " * 12
for sid, folder, branch, title, prompt, minutes, kb in sessions:
    cwd = f"{code}/{folder}"
    out = f"{demo}/claude/projects/{cwd.replace('/', '-')}"
    os.makedirs(out, exist_ok=True)
    def line(kind, text, at):
        return json.dumps({"type": kind, "cwd": cwd, "gitBranch": branch, "timestamp": stamp(at),
                           "message": {"role": kind, "content": text}})
    lines = [line("user", prompt, minutes + 90), json.dumps({"type": "ai-title", "aiTitle": title})]
    size, turn = 0, 0
    while size < kb * 1024:
        entry = line("assistant", filler, minutes + 60)
        lines.append(entry); size += len(entry); turn += 1
        if turn % 40 == 0: lines.append(line("user", "Looks good, continue", minutes + 30))
    lines.append(line("assistant", "Done. Tests pass.", minutes))
    path = f"{out}/{sid}.jsonl"
    open(path, "w").write("\n".join(lines) + "\n")
    when = (now - datetime.timedelta(minutes=minutes)).timestamp()
    os.utime(path, (when, when))

ws = lambda n, title, folder, ports: {"id": f"0000000{n}-demo-4000-8000-00000000000{n}", "ref": f"workspace:{n}", "title": title,
                                       "custom_title": title, "current_directory": f"{code}/{folder}", "listening_ports": ports, "selected": n == 1}
json.dump({"workspaces": [ws(1, "WEB ACME-412", "acme-web-checkout", [3000]),
                          ws(2, "API ACME-405", "acme-api-rate-limits", [4000]),
                          ws(3, "MOBILE ACME-420", "acme-mobile-offline", [])]}, open(demo + "/workspaces.json", "w"))

live = lambda sid, n, folder, state: {"sessionId": sid, "workspaceId": f"0000000{n}-demo-4000-8000-00000000000{n}", "surfaceId": f"surface-{n}",
                                      "cwd": f"{code}/{folder}", "agentLifecycle": state, "runtimeStatus": state, "turnSettled": state != "running", "pid": 1}
json.dump({"sessions": {
    "a": live(sessions[0][0], 1, "acme-web-checkout", "running"),
    "b": live(sessions[2][0], 2, "acme-api-rate-limits", "idle"),
    "c": live(sessions[3][0], 3, "acme-mobile-offline", "running"),
}}, open(demo + "/hooks.json", "w"))
PY

echo "Demo world ready in $DEMO"
WK_CONFIG="$DEMO/config.toml" WK_STATE_DIR="$DEMO/state" WK_CACHE_DIR="$DEMO/cache" \
  WK_CMUX_HOOK_SESSIONS="$DEMO/hooks.json" nohup "$APP/Contents/MacOS/Wk" >/dev/null 2>&1 &
echo "Wk is running on demo data. Press ⌥Space. Run scripts/demo.sh --clean when done."

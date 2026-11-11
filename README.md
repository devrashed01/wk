# Wk

A macOS menu-bar app and CLI for keeping track of your repos, feature branches, git worktrees and the [Claude Code](https://claude.com/claude-code) session that belongs to each, built on top of [cmux](https://cmux.dev).

You stop hunting for branch names and lost Claude sessions. Press a hotkey, type a ticket or a word, hit ↵, and you're back in that task with its server, Claude and git panes (⌘↵ for a single Claude pane).

- **⌥Space** opens the search window from anywhere. Type a ticket (`ABC-123` or `123`), a branch, a repo or a session title, then press **↵** to jump there. Wk focuses the running Claude, selects its cmux workspace, or opens a new *server | claude | git* workspace and resumes the latest session.
- **⌘K** lists every action for the selected row, so there's nothing to memorize.
- Other shortcuts: **⌘N** new task, **⌘⌫** remove, **⌘R** pick a session, **⌘P** pin, **⌘1–4** tabs (Tasks, Sessions, Cleanup, Settings).
- **New task**: start from the base branch, a local or remote branch, or another worktree. It can be created in place or as a sibling worktree (`<repo>-<slug>`). For worktrees, `.env*` files are copied and dependencies installed automatically.
- **Remove**: removes a worktree, branch, remote branch, cmux workspace or sessions, with safety checks. Before anything with uncommitted or unpushed work is removed, you must type the branch name. Sessions go to a trash you can restore from.
- **Cleanup** finds merged branches, branches whose upstream is gone, missing worktrees, stale branches and orphaned sessions.
- The menu-bar icon shows how many Claude sessions are waiting for you, and a notification fires when one finishes.
- Every action is also available in the terminal. Run `wk help` for the list; add `--json` to any command for machine-readable output.

It's light: about 40 MB RAM at idle and no polling, since it uses FSEvents.

## Requirements

- macOS 14 or later (Apple silicon or Intel)
- [cmux](https://cmux.dev), [Claude Code](https://claude.com/claude-code) and git
- Optional: [fzf](https://github.com/junegunn/fzf) for the terminal picker

## Install

**One line (recommended):**

```sh
curl -fsSL https://raw.githubusercontent.com/devrashed01/wk/main/install.sh | sh
```

This installs the latest `Wk.app` into `/Applications` (or `~/Applications`), puts `wk` on your PATH, and starts it. Run it again any time to update. The script checks the download against the release checksums. You can set `WK_VERSION=x.y.z` to pin a version.

**DMG:** download `Wk-<version>.dmg` from [Releases](https://github.com/devrashed01/wk/releases), open it, and drag **Wk** onto **Applications**. The app is signed with the author's personal certificate but is not notarized, so the first time you open it, macOS blocks it. Right-click Wk → **Open**, or go to **System Settings → Privacy & Security → Open Anyway**. (The curl install skips this step.) To also get the CLI:

```sh
sudo ln -sf /Applications/Wk.app/Contents/Resources/wk /usr/local/bin/wk
```

**CLI only:** `wk-<version>-darwin-universal.tar.gz` from the same release.

## Configure

Settings are in `~/.config/wk/config.toml`. You can edit them in the app's Settings tab or with `wk config edit`. Everything is optional.

```toml
roots = ["~/code"]               # where to look for repos (default: ~/code, ~/projects, ~/Developer, ~/src, ...)
base_branch = ""                 # empty = auto-detect (origin/HEAD, then main/master/...)
recent_days = 30                 # how far back the Recent list goes
hotkey = "option+space"
auto_start_claude = false        # false: only type `claude` / `claude --resume` in cmux, Enter runs it (resuming costs tokens)
label_strip_prefixes = ["acme-"] # shorten repo labels: "acme-web" -> "web"

[repo."~/code/acme-web"]
server_cmd = "yarn dev"          # runs in the server pane
base_branch = "develop"
post_worktree = ["yarn install"] # runs in a new worktree (default: detected from the lockfile)
```

wk keeps its own data (pins, notes, session names, trashed sessions) in `~/.local/state/wk`. It never edits Claude's files; it only moves them into its trash when you ask.

## Build from source

You need Go 1.25+ and Xcode (Swift 6).

```sh
make install   # build for this Mac -> ~/Applications/Wk.app and ~/go/bin/wk
make run       # install and (re)start the app
make test      # Go + Swift tests
make release VERSION=x.y.z   # universal, signed build + zips in dist/
```

Signing uses a *Developer ID Application* certificate when one is in your keychain. Without one, it falls back to *Apple Development*, and then to ad-hoc signing. Set `SIGN_IDENTITY="..."` to choose the certificate. If you have a Developer ID, set `NOTARY_PROFILE=<profile>` (from `xcrun notarytool store-credentials`) to notarize and staple the release.

## How it fits together

- `core/` (Go) holds all the logic. It scans repos, worktrees and branches, and indexes `~/.claude/projects` transcripts incrementally (cached in `~/.cache/wk`). It reads cmux state and runs git and cmux actions with safety checks. The CLI is built from it.
- `app/` (SwiftUI) is a thin UI. It keeps one `wk serve` process (NDJSON over stdio) and refreshes on file-system events.

## License

[MIT](LICENSE)

# gitplus

Personal custom `git` subcommands. Git treats any executable named `git-<name>`
on your `PATH` as `git <name>`, so these work like built-ins once installed.

These are shortcuts to speed up a PR-based dev cycle: `git sweep` clears out
merged branches faster than asking an LLM to do it by hand; `git pr` + `git
done` is a quick way to check out and test a coworker's branch and clean up
afterward. If you don't work with PRs, there's probably not much here for you
— but if you work with a team, it's worth a look.

## Install

**Homebrew** (recommended):

```bash
brew tap raocow/tap
brew install gitplus
```

This also installs the [GitHub CLI](https://cli.github.com) (`gh`)
automatically — it's a hard dependency of the formula, needed for `git pr`
and `git haspr`.

**From source** (for local development, or if you're not on Homebrew):

```bash
git clone https://github.com/raocow/gitplus ~/gitplus
cd ~/gitplus
./install.sh                 # symlinks bin/git-* into ~/.local/bin
# (pass a dir to link elsewhere, e.g. ./install.sh ~/bin)
```

`./install.sh` symlinks, so a later `git pull` here updates the commands in
place. Make sure the target dir is on your `PATH`. You'll need the
[GitHub CLI](https://cli.github.com) (`gh`) yourself this way — `install.sh`
installs it via Homebrew if missing (and prints manual instructions
otherwise); not fatal, so the other commands install fine without it.

## zsh completion

`install.sh` also symlinks a set of plain zsh completion functions into
`<target>/../share/zsh/site-functions` — real Tab-completion for every
command below (real branches, real open PRs — nothing generated or guessed,
same principle as `cd` completing real directories). No `source` line, no
compinit-ordering requirement: these autoload the standard way, so they just
work once that directory is on your `$fpath`.

`git new` is built specifically to fix chronically-verbose LLM-authored
branch names: `git new <TAB>` cycles through short *words already used in
this repo's existing branch names*, so composing a name is a few Tab presses
instead of typing a sentence — and it works no matter what's driving your
terminal (Claude, Codex, you by hand), since it fires on the completion
itself, not on any tool choosing to cooperate.

If `install.sh` doesn't detect that zsh's own `_git` wins, it prints a
one-time setup snippet. The subtlety: these are `git <subcommand>`
completions, so completing their arguments goes through whatever `_git` is
first on `fpath`. zsh's own `_git` dispatches to `_git-<cmd>` user functions
(how these work); the `_git` that **Homebrew's `git` formula** ships does
**not** — it sends unknown subcommands' arguments to plain file completion.
And `brew shellenv` prepends Homebrew's `site-functions` dir, so by default
brew's `_git` wins and `git pr list <TAB>` / `git new <TAB>` just list files.
The fix puts zsh's own function dirs back in front (so its `_git` wins) while
keeping the completion dir on `fpath`:

```zsh
typeset -U fpath
fpath=(/usr/share/zsh/${ZSH_VERSION}/functions /usr/share/zsh/site-functions "$COMPLETION_DIR" $fpath)
autoload -Uz compinit && compinit
```

(`$COMPLETION_DIR` is `install.sh`'s target, e.g.
`~/.local/share/zsh/site-functions`; with the Homebrew formula it's already
on `fpath` and you can drop it.)

## Commands

| Command | What it does |
|---|---|
| [`git sweep`](#git-sweep) | Delete local branches already merged into the base |
| [`git wsweep`](#git-wsweep) | Remove worktrees (and their branches) already merged into the base |
| [`git sync`](#git-sync) | Rebase branch(es) onto the base and push |
| [`git pr`](#git-pr) | List, check out, or merge PRs |
| [`git new`](#git-new) | Create + switch to a branch, with short-name Tab-completion |
| [`git haspr`](#git-haspr) | Check whether a branch already has a PR |
| [`git done`](#git-done) | Switch back to base, fast-forward it, delete the branch you left |
| [`git wt`](#git-wt) | Check out a branch here, freeing it from another worktree first |
| [`git release`](#git-release) | Tag the current commit and publish a GitHub release for it |

Each takes `-h` for a short usage summary, or `--help` to open its full man
page (installed to `share/man/man1` by `install.sh` and by Homebrew).

### `git sweep`

```
git sweep [<branch>...] [-f|--force] [-n|--dry-run] [-b|--base <name>]
```

- Fetches first and compares against the base's **remote tip**
  (`origin/<base>`) — works without pulling main, and from any branch.
- Safe by default: only deletes branches verified merged into that tip (via
  `merge-base`), so no unmerged work is lost — and unlike a bare
  `git branch -d`, it isn't fooled by a stale local base.
- `-f`/`--force` widens the scope to **every** local branch except base and
  current, and force-deletes (`-D`) — also clears never-PR'd, squash-merged,
  or genuinely unmerged branches (this can delete unmerged work — preview
  with `-n` first).
- Naming one or more branches sweeps just those instead of the whole repo —
  same safety rule (skipped unless merged, unless `-f`). Refuses to name the
  base or current branch.

### `git wsweep`

```
git wsweep [-f|--force] [-n|--dry-run] [-b|--base <name>]
```

The worktree analogue of `git sweep`:

- Removes worktrees whose **HEAD is already merged** into the base's remote
  tip, **and deletes the underlying branch** — same as running `git sweep`
  right after, since you're almost always done with both at once. A
  detached-HEAD worktree has no branch, so only the worktree goes.
- Safe by default (verified with `merge-base`; judged by the worktree's HEAD,
  so branch-backed and detached worktrees both work). The main worktree and
  the one you're in are never touched (or deleted).
- `-f`/`--force` removes **every** other worktree regardless of merge status
  — including ones with uncommitted changes (those changes are discarded).
  Branches are **not** deleted in force mode — that's two separately
  destructive actions to compound into one flag; run `git sweep -f`
  afterward if you want those gone too. Preview with `-n` first.

### `git sync`

```
git sync [<ids...>] [-x|--exclude <ids...>] [-a|--all] [-n|--dry-run] [-b|--base <name>]
```

- Rebases branch(es) onto `origin/<default>` and pushes:
  `fetch → rebase → push --force-with-lease`. Bare `git sync` does the
  current branch.
- **Targets mirror `git pr merge`**: a PR number, head branch, URL, or an
  `824-830`-style range, all mixable. A numeric/URL target resolves to the
  PR's head branch via `gh`; a plain branch name is used as-is, offline.
  `-x`/`--exclude` drops branch(es)/PR(s) from an explicit list or `--all`
  (same forms, ranges included).
- On the base branch (or a target that *is* the base), it acts as a safe pull
  instead — `fetch → rebase origin/<base>`, no push.
- **A rebase that can't complete automatically is handled like
  `git pr merge`**: it's aborted (branch left untouched, never
  half-rebased), skipped, and listed at the end as needing manual
  resolution — resolve one by hand with
  `git checkout <branch> && git rebase origin/<base>`.
- `--all`/`-a` sweeps the whole repo: fast-forwards local base, **prunes**
  branches already merged into it, and rebases + pushes the rest.
  Purely-local (never-pushed) branches are rebased but not pushed;
  squash-merged branches look unmerged so they're rebased, not pruned (use
  `git sweep -f` for those).
- Guards against dirty trees. No `--method` — sync only ever rebases.

### `git pr`

```
git pr                            list your open PRs ("<url> -- <title>")
git pr -nt                        list them as bare URLs (--no-title)
git pr -c                         also copy the listing to the clipboard (--copy)
git pr <n|branch|url|.|@>         check out that PR, updated to its latest
git pr list <id...>               show title/link instead of checking out
git pr merge <id...>              merge the given PR(s)
git pr merge --all|-a             merge every mergeable PR YOU authored
git pr ... -x|--exclude <id...>   exclude PR(s) from any of the above
git pr merge ... -n|--dry-run     preview the merge plan, change nothing
```

Requires the GitHub CLI (`gh`).

- **List** (bare `git pr`) shows your open PRs; `-nt`/`--no-title` prints
  bare URLs, one per line, for piping. `-c`/`--copy` also copies the listing
  to the clipboard — works with any listing form (`list`, checkout-multi,
  `-nt`), not `merge`.
- **Check out** a PR with its number, head branch, URL, or `.`/`@` (the
  branch you're on) — this runs `gh pr checkout`, which creates the branch or
  fast-forwards an existing one, so you're never on a stale copy. Falls back
  to `refs/pull/<n>/head` for a merged/closed PR whose branch was deleted,
  or — offline — to a local branch stamped with the PR number (switched to
  as-is, not updated). If the branch is already checked out in another
  worktree, it's freed from there first (see `git wt`) instead of refusing.
- **Inspect without checking out**: `git pr list <id...>` shows the
  title/link for any number of PRs, any author, any state. `.`/`@` works
  here too. (`git pr <id> <id>` — 2+ ids, a range, or `-x`, no `list` — does
  the same thing, kept for old muscle memory.)
- **Merge**: `git pr merge <id...>` merges exactly the PRs you name, whoever
  authored them — naming them is explicit, so it's not scoped to you.
  `git pr merge --all`/`-a` (no ids) is a broad sweep, so it's scoped to PRs
  **you authored** — it never touches anyone else's, and neither form ever
  bypasses branch protection.
  - Acts by default (it touches GitHub) — pass `-n`/`--dry-run` to preview
    the plan first.
  - Merges in an order that minimizes conflicts (least-entangled first, by
    shared changed files — a plain adjacency count, no LLM involved).
  - For each PR: a clean one merges directly; one needing an update is
    rebased in a scratch worktree (never touching your current branch) and
    pushed; blocked, draft, or unresolvable PRs are skipped.
  - `--method merge|squash|rebase` overrides the merge method (default: the
    repo's own). Branches aren't auto-deleted — run `git sweep` after.

### `git new`

```
git new <name> [-b|--base <base>]
```

Creates `<name>` and switches to it (`git switch -c`, from the current
branch unless `-b`/`--base` is given). The real point is Tab-completion: with
the zsh completions enabled, `git new <TAB>` cycles through short words
already used in this repo's branch names, so composing a short name takes a
few Tab presses instead of typing a sentence — and it works regardless of
what's driving the terminal, since it's the shell doing the completing, not
any tool choosing to cooperate.

### `git haspr`

```
git haspr [<branch>]
```

Requires the GitHub CLI (`gh`).

Checks whether a branch (current branch by default) already has a PR, in
**any state** — open, closed, or merged — so it catches one that already
landed or got closed before you create a duplicate. Prints the URL and state
and exits 0 if found; prints a clear message and exits 1 otherwise, so it's
usable in scripts: `git haspr || gh pr create`.

### `git wt`

```
git wt <branch|PR#|url|.|@>
```

A branch can only ever be checked out in **one worktree at a time** (a hard
git rule) — normally a hard stop: `git pr <id>`/`git sync <id>` just refuse
and tell you where it is. `git wt <id>` instead **frees it and checks it out
here**: it detaches the *other* worktree's HEAD at its current commit (safe —
doesn't touch that worktree's working tree or uncommitted changes at all,
just stops it holding the branch name) and switches to the branch in the
current worktree. A purely local operation — no shell integration needed,
since it never has to move you anywhere.

The id can be a branch name, PR number, PR URL, or `.`/`@` (the current
branch) — same grammar as `git pr`/`git sync`; a PR number/URL is resolved to
its head branch via `gh` first. `git pr <id>` uses the same free-it-first
logic internally, so `git pr 132` also just works even when #132's branch is
checked out elsewhere.

### `git done`

```
git done [-f|--force] [-n|--dry-run] [-b|--base <name>]
```

The bookend to `git pr`:

- Switches back to the base (`origin/<default>`, usually main),
  **fast-forwards it to origin** (so you land on an up-to-date main with the
  PR you just merged), and deletes the branch you left.
- Safe by default (`git branch -d`), so hopping back can't silently drop
  unmerged work — squash-merged branches look unmerged and are refused too;
  pass `-f`/`--force` (`git branch -D`) when you know the branch is done.
- The fast-forward is best-effort: skipped with a note if you're offline or
  local base has diverged (never a merge commit).
- On a detached HEAD, it just switches back to base. Already on the base, it
  just pulls (fetch + fast-forward — nothing to delete).

### `git release`

```
git release <version> [--notes <text>] [-n|--dry-run]
git release --major|--minor|--patch [--notes <text>] [-n|--dry-run]
```

Automates the flow a GitHub release actually needs: an annotated tag, a push
of that tag, and `gh release create` — a plain `git tag` + `git push origin
<tag>` alone does **not** create a visible GitHub Release, that's a separate
API call this always makes.

- The version is either explicit (`v1.3.0`) or derived by bumping the latest
  `vX.Y.Z` tag (`--major`/`--minor`/`--patch`).
- Release notes are either explicit (`--notes "..."`) or left to
  `gh release create --generate-notes` (summarizes PRs/commits since the last
  release) — version and notes are each independently automatic or manual.
- Refuses uncommitted changes (checked with `git status --porcelain`, so
  untracked files count too — not just `git diff --quiet`, which misses
  them) or a current branch that's diverged from its origin tracking branch.
- `-n`/`--dry-run` previews the version and notes source without tagging or
  pushing anything.

---

Genuinely shared logic (the color/step/warn output helpers, base-branch
resolution, PR-range expansion) lives once in `lib/gitplus-common.sh`,
which each command locates relative to its own real path (following the
symlink it's installed as) and sources — not copy-pasted per file. Only
things that are *coincidentally* similar but reasonably diverge per command
stay separate.

## Requirements

- `bash` (works on macOS's bash 3.2)
- `git`
- `gh` (GitHub CLI) — for `git pr`, `git haspr`, and `git release`, and for
  `git sync` only when a target is a PR number or URL (naming branches
  directly needs no `gh`). `install.sh` installs it via Homebrew if missing
  (and prints manual instructions on other platforms); not fatal, so the
  other commands install
  fine without it.

## Notes

- `git sweep` won't catch **squash-merged** branches (a squash isn't an
  ancestor of the base, so `-d` correctly refuses it) — delete those by hand,
  or with `git sweep -f`.
- `git sync` uses `--force-with-lease`, which still refuses to clobber remote
  commits you haven't fetched.

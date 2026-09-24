# gitplus-common.sh — shared helpers for the gp-* commands.
#
# Sourced, not executed — each script resolves its own real location
# (following symlinks, since these are installed as symlinks) and sources
# this file from the sibling `lib/` directory. One `source` of a small file
# is negligible next to the git/gh subprocesses these scripts already run, so
# this costs nothing measurable while removing real duplication (and, for
# resolve_base, a real inconsistency — see below).

# Colorized step output on a terminal (respects NO_COLOR). Every gp-* tool
# narrates its actions in this one consistent format: green ✓ for a
# completed step, yellow ! for a warning, dim for secondary detail, cyan for
# a branch name called out within a line (matches the cyan already used for
# completion headers in ~/.zshrc's zstyle config — same color, same role:
# marking a ref name so it doesn't blend into surrounding prose).
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  _ok=$'\033[32m'; _warn=$'\033[33m'; _dim=$'\033[2m'; _branch=$'\033[36m'; _off=$'\033[0m'
else
  _ok=''; _warn=''; _dim=''; _branch=''; _off=''
fi
step() { printf '%s✓%s %s\n' "$_ok" "$_off" "$1"; }
warn() { printf '%s!%s %s\n' "$_warn" "$_off" "$1" >&2; }

# Resolve the base branch name: an explicit $1, else origin's default, else
# a local main/master, else the current branch. This is the more thorough of
# two variants that used to diverge across the suite (sweep/wsweep had this
# fallback chain; sync/done used to just default to "main" outright, which
# breaks on a repo whose default isn't literally "main" and whose
# origin/HEAD symref is unset) — now unified to the robust version
# everywhere.
resolve_base() {
  local explicit="${1:-}"
  if [ -n "$explicit" ]; then echo "$explicit"; return; fi
  local base
  base=$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null \
    | sed 's#^remotes/##;s#^origin/##' || true)
  if [ -z "$base" ]; then
    local b
    for b in main master; do
      if git show-ref --verify --quiet "refs/heads/$b" \
         || git show-ref --verify --quiet "refs/remotes/origin/$b"; then
        base=$b; break
      fi
    done
  fi
  [ -n "$base" ] || base=$(git rev-parse --abbrev-ref HEAD)
  echo "$base"
}

# Expand "NNN-MMM" range tokens (PR numbers only) into individual ids. A
# token only counts as a range if it's ENTIRELY digits-hyphen-digits — a
# branch name like "task-42" has letters in it and passes through untouched.
# $1 is the caller's command name (for the error message), $2 the output
# array's name, the rest the input tokens.
expand_ranges() {
  local cmd="$1" out="$2"; shift 2
  local t lo hi tmp2
  for t in "$@"; do
    if printf '%s' "$t" | grep -qE '^[0-9]+-[0-9]+$'; then
      lo="${t%-*}"; hi="${t#*-}"
      [ "$lo" -gt "$hi" ] && { tmp2=$lo; lo=$hi; hi=$tmp2; }
      if [ $((hi - lo)) -gt 500 ]; then
        echo "$cmd: range '$t' spans more than 500 ids — that's probably a typo" >&2; exit 2
      fi
      while [ "$lo" -le "$hi" ]; do eval "$out+=(\"$lo\")"; lo=$((lo + 1)); done
    else
      eval "$out+=(\"\$t\")"
    fi
  done
}

# Standard entry guards, identical wording across the suite except the
# command name (passed as $1). `exit` here terminates the whole script, same
# as if it were written inline (source runs in the same shell, not a
# subshell).
require_git_repo() {
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
    echo "$1: not inside a git repository" >&2; exit 1; }
}

require_gh() {
  command -v gh >/dev/null 2>&1 || {
    echo "$1: needs the GitHub CLI ('gh') — https://cli.github.com" >&2; exit 1; }
}

# gh_scope_to_repo — point gh at the account bound to THIS directory, for the
# lifetime of this process only.
#
# gh has no per-repository authentication. Its "active account" is one global
# setting in ~/.config/gh/hosts.yml, shared by every terminal, script and
# agent on the machine; the only per-context lever it offers is the GH_TOKEN
# environment variable. devrig's ghswitch sets that per shell on cd, which
# works well — but only for INTERACTIVE shells, since a non-interactive one
# (a script, a cron job, an agent's tool call) never sources ~/.zshrc and so
# silently falls back to whatever the global account happens to be. That is
# the failure this closes: these commands resolve the account themselves, so
# `gp pr` in a repo bound to one identity uses that identity no matter what
# started it.
#
# Soft dependency: without devrig, or outside a bound directory, this is a
# no-op and gh behaves exactly as before. An already-set GH_TOKEN always
# wins, so an explicit override from the caller is never second-guessed.
# `command devrig` deliberately bypasses any devrig shell function.
gh_scope_to_repo() {
  [ -n "${GH_TOKEN:-}" ] && return 0
  command -v gh >/dev/null 2>&1 || return 0
  command -v gp-account >/dev/null 2>&1 || return 0
  local acct tok
  acct="$(gp-account _gh-for-dir "$PWD" 2>/dev/null)" || return 0
  [ -n "$acct" ] || return 0
  tok="$(gh auth token --user "$acct" 2>/dev/null)" || return 0
  [ -n "$tok" ] && export GH_TOKEN="$tok"
  return 0
}

# pr_merged_into <branch> <base> — prints the number of a MERGED pull request
# from <branch> into <base>, if there is one. Empty (and returns 1) otherwise.
#
# This exists because `git merge-base --is-ancestor` — the only honest LOCAL
# test for "did this land" — says NO for a squash- or rebase-merged branch,
# since a squash makes one brand-new commit and a rebase rewrites them all.
# Neither leaves the branch tip anywhere in the base's history. In a repo that
# squash-merges (GitHub's default for many teams), that means the ancestor
# test alone can NEVER approve deleting a branch, no matter how thoroughly
# merged it is. Asking GitHub is the authoritative answer.
#
# The --base filter is load-bearing, not decoration. A stacked PR is merged
# into its PARENT branch, not into the base, so its work has not reached the
# base at all — a plain "does a merged PR exist for this branch" check would
# happily approve deleting work that never landed. That exact case has come
# up here: a branch had a merged PR into an intermediate branch long before
# it had one into main.
pr_merged_into() {
  local branch="$1" base="$2" n
  gh_scope_to_repo
  command -v gh >/dev/null 2>&1 || return 1
  n="$(gh pr list --head "$branch" --base "$base" --state merged --limit 1 \
    --json number --jq '.[0].number // empty' 2>/dev/null || true)"
  [ -n "$n" ] || return 1
  printf '%s\n' "$n"
}

# merged_pr_heads_into <base> — the head branch name of every merged PR that
# reaches <base>, directly OR transitively through a chain of merged stacked
# PRs, one per line. The batch form of pr_merged_into, for callers that have
# to judge many branches at once (gp sweep): one API call regardless of
# branch count or stack depth, instead of one per branch. Prints nothing if
# gh is unavailable, so callers degrade to the ancestor test.
#
# Transitive because a squash- or rebase-merge breaks ancestry: if child C's
# PR was merged into intermediate branch P (base=P), and P's PR was later
# merged into <base> (base=<base>), C's commits are NOT reachable from
# <base> — a squash replaces P's whole history, C's included, with one new
# commit. The direct-only version of this check would miss C entirely once
# P is gone, even though C's work is fully landed. Fetching every merged
# PR's head/base pair once and closing over it locally catches any stack
# depth for the same single API call.
merged_pr_heads_into() {
  local base="$1" pairs
  gh_scope_to_repo
  command -v gh >/dev/null 2>&1 || return 0
  pairs="$(gh pr list --state merged --limit 500 \
    --json headRefName,baseRefName \
    --jq '.[] | "\(.headRefName)\t\(.baseRefName)"' 2>/dev/null)" || return 0
  [ -n "$pairs" ] || return 0
  awk -F'\t' -v base="$base" '
    { head[NR] = $1; from[NR] = $2; n = NR }
    END {
      reached[base] = 1
      changed = 1
      while (changed) {
        changed = 0
        for (i = 1; i <= n; i++) {
          if ((from[i] in reached) && !(head[i] in reached)) {
            reached[head[i]] = 1; changed = 1
          }
        }
      }
      for (h in reached) if (h != base) print h
    }
  ' <<EOF
$pairs
EOF
}

# worktree_path_for_branch <branch> — a branch can be checked out in at most
# one worktree at a time (a hard git rule, not a limitation of these tools),
# so any command that's about to check out/rebase-in-place a named branch
# needs to know up front whether it's already checked out SOMEWHERE ELSE.
# Prints that other worktree's path and returns 0 if so; prints nothing and
# returns 1 otherwise (not checked out anywhere else, or checked out right
# here — checking out a branch you're already on isn't a conflict).
#
# Reads `git worktree list --porcelain`, whose entries look like:
#   worktree /path/to/wt
#   HEAD <sha>
#   branch refs/heads/<name>
# (or `detached` instead of the branch line). Matching the branch line to the
# worktree path above it means walking the stream by hand rather than
# grepping in isolation.
worktree_path_for_branch() {
  local branch="$1" here wtpath found=""
  here="$(git rev-parse --show-toplevel 2>/dev/null)"
  while IFS= read -r line; do
    case "$line" in
      "worktree "*) wtpath="${line#worktree }" ;;
      "branch refs/heads/$branch")
        [ "$wtpath" != "$here" ] && found="$wtpath"
        ;;
    esac
  done < <(git worktree list --porcelain)
  [ -n "$found" ] && { printf '%s\n' "$found"; return 0; }
  return 1
}

# branch_in_worktree_named <name> — the branch checked out in the worktree
# called <name>, where <name> is either the worktree's directory name or its
# full path. Lets a command address a worktree the way you actually think of
# it ("the modloop worktree") instead of requiring the branch name, which is
# often the thing you're trying to look up in the first place. Prints nothing
# and returns 1 if no worktree matches, or if the one that does is detached.
branch_in_worktree_named() {
  local want="$1" wantp="" wtpath="" line
  # `git worktree list` reports PHYSICAL paths, so a path argument has to be
  # resolved the same way before comparing: on macOS /tmp and /var are
  # themselves symlinks (/private/tmp, /private/var), and an unresolved path
  # under either would never match. Only attempted for something that looks
  # like a path; a bare worktree name is matched by basename below.
  case "$want" in
    */*) [ -d "$want" ] && wantp="$(cd -P "$want" 2>/dev/null && pwd)" ;;
  esac
  while IFS= read -r line; do
    case "$line" in
      "worktree "*) wtpath="${line#worktree }" ;;
      "branch refs/heads/"*)
        # Braces are load-bearing: && and || are equal-precedence and
        # left-associative in shell, so without them the -n test would bind
        # to the wrong side and change what this matches.
        if [ "$wtpath" = "$want" ] \
           || { [ -n "$wantp" ] && [ "$wtpath" = "$wantp" ]; } \
           || [ "${wtpath##*/}" = "$want" ]; then
          printf '%s\n' "${line#branch refs/heads/}"
          return 0
        fi
        ;;
    esac
  done < <(git worktree list --porcelain)
  return 1
}

# free_branch_from_other_worktree <branch> — if <branch> is checked out in a
# worktree OTHER than the current one, detach that worktree's HEAD at its
# current commit so the branch is free to check out here instead. Detaching
# is safe: `git checkout --detach HEAD` doesn't touch the working tree or
# index at all — but leaving uncommitted work sitting there also means it
# never comes with you, which is its own problem when the whole point of
# switching is to work on that branch. If that worktree is dirty (tracked or
# untracked changes), they're stashed there instead of just left in place.
#
# Sets $_freed_worktree_stash to a marker identifying that stash if one was
# created (empty otherwise). The stash's base tree is <branch>'s, not
# whatever the caller happens to be on right now, so it must not be popped
# until the caller has actually checked <branch> out HERE — that's
# apply_freed_worktree_stash()'s job, called once that succeeds. A caller
# that stores this stash away is responsible for eventually resolving it one
# way or the other; see gp-switch and gp-pr for the exit-trap pattern that
# guarantees a failed checkout afterward still surfaces it instead of
# stranding it silently.
#
# No-op (prints nothing, returns 0) if the branch isn't checked out anywhere
# else. Returns 1 with a message on stderr if the detach itself fails.
free_branch_from_other_worktree() {
  local branch="$1" wt
  _freed_worktree_stash=""
  wt="$(worktree_path_for_branch "$branch")" || return 0
  if [ -n "$(git -C "$wt" status --porcelain 2>/dev/null)" ]; then
    local marker="gp: freeing $branch from $wt"
    if git -C "$wt" stash push --include-untracked --quiet -m "$marker" 2>/dev/null; then
      _freed_worktree_stash="$marker"
    else
      warn "'$branch' has uncommitted changes in $wt that couldn't be stashed — detaching it there anyway (nothing is lost, just no longer on that branch name)"
    fi
  fi
  if ! git -C "$wt" checkout --quiet --detach HEAD >/dev/null 2>&1; then
    echo "couldn't free '$branch' from $wt — resolve by hand" >&2
    return 1
  fi
  step "freed '$branch' from $wt (now detached there)"
}

# apply_freed_worktree_stash — call once the branch free_branch_from_other_worktree
# just freed is actually checked out HERE. Pops the SPECIFIC stash entry it
# created, matched by the marker message rather than "the top of the stash
# stack" — stash entries are a single list shared across every worktree of a
# repo, so something else stashed in the meantime must never be popped by
# mistake. No-op if free_branch_from_other_worktree didn't stash anything.
#
# A pop that conflicts is reported, not silently swallowed: git itself leaves
# the stash entry in place and the conflict markers in the working tree when
# that happens, so nothing is lost there either — just needs resolving by
# hand.
apply_freed_worktree_stash() {
  [ -n "${_freed_worktree_stash:-}" ] || return 0
  local marker="$_freed_worktree_stash" ref
  _freed_worktree_stash=""
  ref="$(git stash list --format='%gd %gs' 2>/dev/null | grep -F "$marker" | head -1 | cut -d' ' -f1)"
  if [ -z "$ref" ]; then
    warn "expected the stashed changes from the other worktree but couldn't find them — check 'git stash list'"
    return 1
  fi
  if git stash pop --quiet "$ref" 2>/dev/null; then
    step "restored the uncommitted changes that were on the other worktree"
  else
    echo "the uncommitted changes from the other worktree didn't apply cleanly — resolve the conflict markers, then 'git stash drop' once you're done with that entry" >&2
    return 1
  fi
}

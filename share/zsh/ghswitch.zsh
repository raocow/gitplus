# gitplus: point the GitHub CLI at the right account for whatever directory
# this shell is in, using a PER-SHELL token rather than gh's global setting.
#
# Why per-shell: gh's "active account" (what `gh auth switch` sets) is a
# single setting shared by every terminal, session, and background agent on
# the machine. With more than one account in play, any of them switching it
# yanks the identity out from under all the others mid-task — the failure
# looks like a baffling "Unauthorized"/"Enterprise Managed User" error in a
# session that never touched its own auth. An earlier version of this file
# switched globally on every cd and so was itself a cause of that.
#
# Instead this exports GH_TOKEN for THIS shell only. gh honors it over the
# active account, so each terminal gets its own identity, concurrent sessions
# can't clobber each other, and gh's global setting is never written at all.
# Leaving a bound directory unsets it again — a clean restore, which the
# global version fundamentally couldn't do.
#
# Tradeoff worth knowing: the token sits in this shell's environment (visible
# to child processes and to `ps -E` as your own user) rather than only in the
# keychain. That's the standard GH_TOKEN mechanism CI uses, but it is a real
# difference from the keychain-only default.
#
# Note git is unaffected either way: it authenticates through the osxkeychain
# credential helper (or an ssh alias — see `git account`), not through gh's
# active account, so `git push`/`git fetch` never depended on this.
#
# Unbound directories are bound AUTOMATICALLY, on evidence rather than a
# guess: the accounts differ in which repos they can reach, so the first one
# with PUSH access to this repo is bound and reported. Nothing happens when
# no account has push access (a public repo you only have READ on is never
# auto-bound) or outside a GitHub repo. That probe costs a network call, so
# it runs only for an unbound directory, once per directory per shell.
#
# Enable by adding to ~/.zshrc:
#   source "$(brew --prefix)/share/zsh/ghswitch.zsh"

typeset -gA _gitplus_ghswitch_seen
typeset -gA _gitplus_tok_cache
typeset -g  _gitplus_gh_account=""

_gitplus_ghswitch() {
  command -v gh >/dev/null 2>&1 || return 0
  command -v git-account >/dev/null 2>&1 || return 0

  # `git-account` throughout: the wrapper function below calls back into
  # this hook, so going through it here would recurse forever.
  local want; want="$(command git-account _gh-for-dir "$PWD" 2>/dev/null)"

  if [[ -n "$want" ]]; then
    [[ "$_gitplus_gh_account" == "$want" ]] && return 0
    local tok="${_gitplus_tok_cache[$want]:-}"
    if [[ -z "$tok" ]]; then
      tok="$(gh auth token --user "$want" 2>/dev/null)"
      [[ -n "$tok" ]] && _gitplus_tok_cache[$want]="$tok"
    fi
    # Not logged in as that account — leave whatever's in effect alone rather
    # than half-applying. `git account check` reports this properly.
    [[ -n "$tok" ]] || return 0
    export GH_TOKEN="$tok"
    _gitplus_gh_account="$want"
    return 0
  fi

  # Unbound: drop any token this hook set, so gh falls back to its own active
  # account instead of silently using the last directory's identity.
  if [[ -n "$_gitplus_gh_account" ]]; then
    unset GH_TOKEN
    _gitplus_gh_account=""
  fi

  [[ -n "${_gitplus_ghswitch_seen[$PWD]:-}" ]] && return 0
  _gitplus_ghswitch_seen[$PWD]=1
  local pick
  pick="$(command git-account _access-for-dir "$PWD" first 2>/dev/null)"
  [[ -n "$pick" ]] || return 0
  local root; root="$(git rev-parse --show-toplevel 2>/dev/null)" || return 0
  [[ -n "$root" ]] || return 0
  command git-account bind "$pick" "$root" >/dev/null 2>&1 || return 0
  print -u2 "gitplus: bound ${root:t} to '$pick' (the account with push access here) — change it with: git-account bind <name> ${root}"
  _gitplus_ghswitch   # apply the binding we just made to this shell
}

# `git-account bind`/`add --dir` can change which account applies to the
# current directory, but it runs as a subprocess and so can't export into this
# shell. Re-running the hook afterward applies it immediately, instead of the
# binding appearing to do nothing until the next cd.
git-account() {
  command git-account "$@"
  local rc=$?
  # Guarded because this wrapper can outlive its hook. Tooling that snapshots
  # and replays a shell's functions (Claude Code does exactly this) can
  # restore this wrapper into a shell where _gitplus_ghswitch was never
  # defined, and then every call prints "command not found" after its real
  # output — seen for real with the devrig version of this. A missing hook
  # just means no re-evaluation, which is the harmless outcome.
  typeset -f _gitplus_ghswitch >/dev/null 2>&1 && _gitplus_ghswitch
  return $rc
}

autoload -U add-zsh-hook 2>/dev/null
add-zsh-hook chpwd _gitplus_ghswitch
_gitplus_ghswitch  # run once for the current directory

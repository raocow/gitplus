# gwt <branch> — cd to whichever worktree already has <branch> checked out.
#
# `git wt` (bin/git-wt) resolves the path; a plain script can never change
# its parent shell's directory, so this thin function does the actual `cd`.
# Not a `git <verb>` on purpose, for the same reason — going through git's
# subcommand dispatch would still just be a subprocess.
gwt() {
  local target
  target="$(git wt "$1" 2>&1)" || { print -r -- "$target" >&2; return 1 }
  builtin cd -- "$target"
}

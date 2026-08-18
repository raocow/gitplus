#!/usr/bin/env bash
# Runs every command under /bin/bash — macOS's bash 3.2 — looking for the one
# failure mode that version has and newer bash doesn't.
#
# Why this exists: under `set -u`, bash 3.2 treats "${arr[@]}" on an EMPTY
# array as an unbound-variable error and dies; bash 4+ returns nothing and
# carries on. So a script that works perfectly on a machine with Homebrew
# bash first on PATH can abort instantly on a stock macOS one. That shipped:
# `gp pr merge -a` died with "line 800: exclude_ids[@]: unbound variable" on
# a second machine while being fine on the development machine, and stayed
# invisible through several releases because every test run here used bash 5.
#
# The fix everywhere is the guarded form ${arr[@]+"${arr[@]}"}. This test
# calls the commands for real (against a stub gh, in a throwaway repo) rather
# than just syntax-checking, because an unbound array only errors when the
# line actually executes.
#
# Run: test/bash32.sh
set -uo pipefail

BIN="$(cd "$(dirname "$0")/.." && pwd)/bin"
BASH32=/bin/bash
pass=0; fail=0

if [ ! -x "$BASH32" ]; then
  echo "skip: no $BASH32 on this system"; exit 0
fi
case "$("$BASH32" --version | head -1)" in
  *"version 3."*) ;;
  *) echo "note: $BASH32 is not 3.x — running anyway, but this is a weaker check" ;;
esac

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
FB="$TMP/bin"; mkdir -p "$FB"

# Stub gh: enough shape for each command to get past resolution and into the
# code paths that touch arrays. Never talks to the network.
cat > "$FB/gh" <<'STUB'
#!/usr/bin/env bash
a=("$@"); j="${a[*]}"
if [ "${a[0]}" = pr ] && [ "${a[1]}" = list ]; then
  case "$j" in *headRefName*) echo "" ;; *) printf '5\n6\n' ;; esac; exit 0
fi
if [ "${a[0]}" = pr ] && [ "${a[1]}" = view ]; then
  n="${a[2]}"
  case "$j" in
    *headRefName,baseRefName,isDraft,title*) printf 'br-%s\tmain\tfalse\tTitle %s\n' "$n" "$n"; exit 0 ;;
    *number,url,title,state*) printf '%s\thttps://x/pull/%s\tTitle %s\tOPEN\n' "$n" "$n" "$n"; exit 0 ;;
    *number,state,title*) printf '%s\tMERGED\tTitle %s\n' "$n" "$n"; exit 0 ;;
    *mergeStateStatus*) echo CLEAN; exit 0 ;;
    *files*) echo "f-$n.txt"; exit 0 ;;
    *number*) echo "$n"; exit 0 ;;
    *title*) echo "Title $n"; exit 0 ;;
  esac
  exit 1
fi
case "${a[0]} ${a[1]}" in
  "pr merge"|"pr close"|"pr checkout") exit 0 ;;
  "pr revert") echo "https://x/pull/99"; exit 0 ;;
  "repo view") echo MERGE; exit 0 ;;
  "auth status") echo "  Logged in to github.com account tester (keyring)"; exit 0 ;;
  "auth token") echo faketoken; exit 0 ;;
  "search prs") echo ""; exit 0 ;;
esac
exit 1
STUB
chmod +x "$FB/gh"

R="$TMP/repo"; git init -q -b main "$R" >/dev/null 2>&1
cd "$R"
git commit -q --allow-empty -m init
git remote add origin "$R"
git checkout -q -b work

check() {  # check <command> [args...]
  local name="$*" out
  out="$(PATH="$FB:$PATH" "$BASH32" "$BIN/gp-$1" "${@:2}" 2>&1)"
  case "$out" in
    *"unbound variable"*)
      fail=$((fail + 1))
      printf '  FAIL %s\n       %s\n' "$name" "$(printf '%s' "$out" | grep 'unbound variable' | head -1)" ;;
    *) pass=$((pass + 1)); printf '  ok   %s\n' "$name" ;;
  esac
}

echo "== every command under $("$BASH32" --version | head -1 | sed 's/GNU bash, //') =="
# Deliberately includes the no-argument and single-argument forms: the bug
# class shows up precisely when an optional array (excludes, targets, skipped,
# plan) was never appended to.
check pr
check pr list 5
check pr merge -a
check pr merge 5 6
check pr merge 5 -x 6
check pr merge 5-6 -n
check pr close 5
check pr close --all
check pr unmerge 5
check pr -g
check pr 5
check sync -n
check sync 5 -n
check sync -a -n
check sweep -n
check sweep -rn
check sweep -f -n
check done -n
check haspr
check swap main
check new tmpbranch
check wsweep -n
check account list
check account check

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]

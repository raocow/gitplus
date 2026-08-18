#!/usr/bin/env bash
# End-to-end test for `gp account`, run entirely inside a throwaway $HOME.
#
# This exists because the account commands write to ~/.ssh/config and
# ~/.gitconfig — the two files where a bad edit hurts most. Everything is
# redirected via HOME plus the GITPLUS_* overrides, so a run can never touch your
# real config. Run: test/account.sh
set -uo pipefail

ACCT="$(cd "$(dirname "$0")/.." && pwd)/bin/gp-account"
pass=0 fail=0

ok()   { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
bad()  { fail=$((fail + 1)); printf '  FAIL %s\n' "$1"; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (want '$3', got '$2')"; fi; }
has()  { if grep -qF "$2" "$3" 2>/dev/null; then ok "$1"; else bad "$1"; fi; }
# Match captured output with a bash pattern instead of piping into `grep -q`:
# grep exits on the first match, upstream gp-account takes SIGPIPE, and `pipefail`
# then reports the whole pipeline as failed even though nothing went wrong.
saw()  { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" ;; esac; }

# Resolve physically: on macOS mktemp hands back a /var path that is really
# /private/var, and git matches includeIf against real paths (see _acct_abspath).
TMP="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP"
export GITPLUS_SSH_CONFIG="$TMP/.ssh/config"
export GITPLUS_GITCONFIG="$TMP/.gitconfig"
export GITPLUS_SSH_KEY_DIR="$TMP/.ssh"
export GITPLUS_RC="$TMP/.zshrc"
# Keep the test's own git calls from reading the developer's real config.
export GIT_CONFIG_GLOBAL="$TMP/.gitconfig"
export GIT_CONFIG_NOSYSTEM=1

echo "== add =="
mkdir -p "$TMP/code/work"
"$ACCT" add work --email me@work.com --dir "$TMP/code/work" >/dev/null 2>&1
[ -f "$TMP/.ssh/id_ed25519_work" ]     && ok "private key created"  || bad "private key created"
[ -f "$TMP/.ssh/id_ed25519_work.pub" ] && ok "public key created"   || bad "public key created"
has "ssh host alias written"  "Host github.com-work"  "$GITPLUS_SSH_CONFIG"
has "IdentitiesOnly set"      "IdentitiesOnly yes"    "$GITPLUS_SSH_CONFIG"
has "ssh sentinel written"    "# gitplus:account:work BEGIN" "$GITPLUS_SSH_CONFIG"
has "identity file written"   "me@work.com"           "$TMP/.gitconfig-work"
has "includeIf written"       "gitdir:$TMP/code/work/" "$GITPLUS_GITCONFIG"
check "ssh config perms" "$(stat -f '%Lp' "$GITPLUS_SSH_CONFIG" 2>/dev/null || stat -c '%a' "$GITPLUS_SSH_CONFIG")" "600"

echo "== idempotence =="
before="$(cat "$GITPLUS_SSH_CONFIG")"
"$ACCT" add work --email me@work.com >/dev/null 2>&1
check "re-add does not duplicate ssh block" "$(cat "$GITPLUS_SSH_CONFIG")" "$before"
check "one sentinel only" "$(grep -c '# gitplus:account:work BEGIN' "$GITPLUS_SSH_CONFIG")" "1"

echo "== identity actually applies =="
git init -q "$TMP/code/work/repo" 2>/dev/null
check "git resolves the bound identity" \
  "$(git -C "$TMP/code/work/repo" config user.email)" "me@work.com"

echo "== list / key =="
out="$("$ACCT" list)"
saw "list shows account"     "$out" "work"
saw "list shows bound dir"   "$out" "code/work"
saw "key prints pubkey"      "$("$ACCT" key work)" "ssh-ed25519"

echo "== check: healthy =="
if "$ACCT" check >/dev/null 2>&1; then ok "check passes when healthy"
else bad "check passes when healthy"; fi
saw "check verifies end-to-end" "$("$ACCT" check 2>&1)" "verified"

echo "== check: catches the rename =="
# The whole reason this feature exists: move the bound directory and the
# includeIf silently stops applying. check must notice.
mv "$TMP/code/work" "$TMP/code/work-renamed"
if "$ACCT" check >/dev/null 2>&1; then bad "check fails after rename"
else ok "check fails after rename"; fi
saw "check reports BROKEN" "$("$ACCT" check 2>&1)" "BROKEN"

echo "== second account coexists =="
"$ACCT" add personal --email me@home.com >/dev/null 2>&1
out="$("$ACCT" list)"
saw "work still listed"     "$out" "work"
saw "personal now listed"   "$out" "personal"

echo "== validation =="
"$ACCT" add "bad name" --email x@y.com >/dev/null 2>&1 \
  && bad "rejects invalid name" || ok "rejects invalid name"
"$ACCT" add nomail >/dev/null 2>&1 \
  && bad "requires --email" || ok "requires --email"
"$ACCT" bind ghost /tmp >/dev/null 2>&1 \
  && bad "bind rejects unknown account" || ok "bind rejects unknown account"

echo "== --gh-user =="
"$ACCT" add work --email me@work.com --gh-user work-gh >/dev/null 2>&1
has "gh user recorded"  "# gitplus:ghuser:work work-gh"  "$GITPLUS_SSH_CONFIG"
out="$("$ACCT" list)"
saw "list shows gh user" "$out" "gh: work-gh"

before="$(cat "$GITPLUS_SSH_CONFIG")"
"$ACCT" add work --email me@work.com --gh-user work-gh >/dev/null 2>&1
check "re-add same gh-user does not duplicate" "$(cat "$GITPLUS_SSH_CONFIG")" "$before"

out="$("$ACCT" add work --email me@work.com --gh-user someone-else 2>&1)"
saw "conflicting gh-user warns instead of overwriting" "$out" "already set to 'work-gh'"
check "conflicting gh-user left the original in place" "$(cat "$GITPLUS_SSH_CONFIG")" "$before"

echo "== acct_gh_for_dir (internal resolver, used by the ghswitch feature) =="
# Fresh account + directory, dedicated to these tests — 'work' is bound to
# $TMP/code/work, which the earlier rename-detection section already moved
# away from, so reusing it here would test a path that was never bound.
mkdir -p "$TMP/code/outer/sub"
"$ACCT" add outer --email outer@work.com --gh-user outer-gh \
  --dir "$TMP/code/outer" >/dev/null 2>&1
check "resolves the bound dir itself" \
  "$("$ACCT" _gh-for-dir "$TMP/code/outer")" "outer-gh"
check "resolves a subdirectory of the bound dir" \
  "$("$ACCT" _gh-for-dir "$TMP/code/outer/sub")" "outer-gh"
check "unrelated directory resolves to nothing" \
  "$("$ACCT" _gh-for-dir "$TMP")" ""

mkdir -p "$TMP/code/outer/nested"
"$ACCT" add nested --email nested@work.com --gh-user nested-gh \
  --dir "$TMP/code/outer/nested" >/dev/null 2>&1
check "nested binding is more specific and wins" \
  "$("$ACCT" _gh-for-dir "$TMP/code/outer/nested")" "nested-gh"
check "outside the nested binding still resolves to the outer one" \
  "$("$ACCT" _gh-for-dir "$TMP/code/outer/sub")" "outer-gh"

echo "== check: gh user verification =="
FAKEBIN="$TMP/fakebin"; mkdir -p "$FAKEBIN"

# No gh on PATH: check should say so, not blow up or silently pass. Use bare
# system dirs (real core utils gp-account itself needs — grep/sed/git — but gh is
# always Homebrew-installed, never bundled there) rather than an empty PATH,
# which would also break gp-account's own use of those utilities.
out="$(PATH="/usr/bin:/bin" "$ACCT" check 2>&1)"
saw "no gh installed is reported, not silent" "$out" "can't verify (gh CLI not installed)"

# Fake gh reporting the account as logged in.
cat > "$FAKEBIN/gh" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = auth ] && [ "$2" = status ]; then
  echo "  ✓ Logged in to github.com account work-gh (keyring)"
  exit 0
fi
exit 1
EOF
chmod +x "$FAKEBIN/gh"
out="$(PATH="$FAKEBIN:$PATH" "$ACCT" check 2>&1)"
saw "logged-in gh user passes check" "$out" "gh user  : ok (work-gh logged in)"

# Fake gh reporting a DIFFERENT set of logged-in accounts.
cat > "$FAKEBIN/gh" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = auth ] && [ "$2" = status ]; then
  echo "  ✓ Logged in to github.com account someone-unrelated (keyring)"
  exit 0
fi
exit 1
EOF
if PATH="$FAKEBIN:$PATH" "$ACCT" check >/dev/null 2>&1; then
  bad "not-logged-in gh user fails check"
else
  ok "not-logged-in gh user fails check"
fi
out="$(PATH="$FAKEBIN:$PATH" "$ACCT" check 2>&1)"
saw "check reports NOT LOGGED IN" "$out" "NOT LOGGED IN as work-gh"

echo "== bind never touches gh's global active account =="
# gh's active account is machine-wide: writing it from here would yank the
# identity out from under every other terminal/agent session. Applying a new
# binding to the current shell is ghswitch's job, per-shell via GH_TOKEN.
SWITCHED_TO="$TMP/switched-to"
cat > "$FAKEBIN/gh" <<EOF
#!/usr/bin/env bash
if [ "\$1" = auth ] && [ "\$2" = switch ]; then
  echo "\$4" > "$SWITCHED_TO"
  exit 0
fi
exit 1
EOF
chmod +x "$FAKEBIN/gh"

mkdir -p "$TMP/code/instant"
rm -f "$SWITCHED_TO"
out="$(cd "$TMP/code/instant" && PATH="$FAKEBIN:$PATH" "$ACCT" bind work "$TMP/code/instant" 2>&1)"
saw "bind still reports the binding" "$out" "bound:"
check "bind does NOT switch the global account, even from inside the dir" \
  "$(cat "$SWITCHED_TO" 2>/dev/null)" ""

mkdir -p "$TMP/code/elsewhere" "$TMP/code/nothere"
rm -f "$SWITCHED_TO"
(cd "$TMP/code/nothere" && PATH="$FAKEBIN:$PATH" "$ACCT" bind work "$TMP/code/elsewhere" >/dev/null 2>&1)
check "no global switch when binding another dir either" "$(cat "$SWITCHED_TO" 2>/dev/null)" ""

echo "== _access-for-dir (which account can actually push here) =="
# A real git repo with a real origin, so the remote parsing is exercised for
# real rather than mocked. Only `gh` itself is faked.
mkdir -p "$TMP/code/probe"
git init -q "$TMP/code/probe"
git -C "$TMP/code/probe" remote add origin https://github.com/acme/widget.git

# work-gh has WRITE, outer-gh only READ. READ must NOT count: on any public
# repo every logged-in account gets READ, so counting it would make every
# public repo look like a match for the wrong account.
mk_gh() {  # mk_gh <perm-for-work-gh> <perm-for-outer-gh>
  cat > "$FAKEBIN/gh" <<EOF
#!/usr/bin/env bash
if [ "\$1" = auth ] && [ "\$2" = token ]; then
  echo "tok-\$4"; exit 0
fi
if [ "\$1" = repo ] && [ "\$2" = view ]; then
  case "\$GH_TOKEN" in
    tok-work-gh)  echo "$1"; exit 0 ;;
    tok-outer-gh) echo "$2"; exit 0 ;;
  esac
  exit 1
fi
exit 1
EOF
  chmod +x "$FAKEBIN/gh"
}

mk_gh WRITE READ
out="$(PATH="$FAKEBIN:$PATH" "$ACCT" _access-for-dir "$TMP/code/probe" 2>&1)"
check "push access -> account returned" "$out" "work"

mk_gh READ READ
out="$(PATH="$FAKEBIN:$PATH" "$ACCT" _access-for-dir "$TMP/code/probe" 2>&1)"
check "read-only everywhere -> no match (public-repo guard)" "$out" ""

mk_gh ADMIN WRITE
out="$(PATH="$FAKEBIN:$PATH" "$ACCT" _access-for-dir "$TMP/code/probe" 2>&1)"
check "two with push access -> both listed" "$(printf '%s\n' "$out" | grep -c .)" "2"
out="$(PATH="$FAKEBIN:$PATH" "$ACCT" _access-for-dir "$TMP/code/probe" first 2>&1)"
check "'first' short-circuits to one" "$(printf '%s\n' "$out" | grep -c .)" "1"

# Non-GitHub and non-repo directories must not probe at all.
mk_gh ADMIN ADMIN
git init -q "$TMP/code/gitlab"
git -C "$TMP/code/gitlab" remote add origin https://gitlab.com/acme/widget.git
out="$(PATH="$FAKEBIN:$PATH" "$ACCT" _access-for-dir "$TMP/code/gitlab" 2>&1)"
check "non-GitHub remote -> no match" "$out" ""
mkdir -p "$TMP/code/plaindir"
out="$(PATH="$FAKEBIN:$PATH" "$ACCT" _access-for-dir "$TMP/code/plaindir" 2>&1)"
check "not a git repo -> no match" "$out" ""

# gp account's own ssh alias form is still github.com and must be understood.
git init -q "$TMP/code/aliasremote"
git -C "$TMP/code/aliasremote" remote add origin git@github.com-work:acme/widget.git
mk_gh WRITE READ
out="$(PATH="$FAKEBIN:$PATH" "$ACCT" _access-for-dir "$TMP/code/aliasremote" 2>&1)"
check "github.com-<account> ssh alias understood" "$out" "work"

echo "== legacy devrig: sentinels are still read =="
# This command used to be `devrig account`, and it wrote its markers with a
# `devrig:` prefix. Those lines are in people's live ~/.ssh/config and
# ~/.gitconfig right now, so failing to read them would make every existing
# account and binding silently vanish — the one way this move could quietly
# destroy a working setup. Writes use `gitplus:`; both must resolve.
LEGACY="$TMP/legacy"; mkdir -p "$LEGACY/.ssh" "$LEGACY/code/old"
cat > "$LEGACY/.ssh/config" <<EOF
# devrig:account:legacy BEGIN
Host github.com-legacy
  HostName github.com
  User git
  IdentityFile $LEGACY/.ssh/id_ed25519_legacy
# devrig:account:legacy END
# devrig:ghuser:legacy legacy-gh
EOF
cat > "$LEGACY/.gitconfig" <<EOF
# devrig:bind:legacy BEGIN $LEGACY/code/old
[includeIf "gitdir:$LEGACY/code/old/"]
	path = $LEGACY/.gitconfig-legacy
# devrig:bind:legacy END $LEGACY/code/old
EOF
printf '[user]\n\temail = legacy@old.com\n\tname = legacy\n' > "$LEGACY/.gitconfig-legacy"
lg() { GITPLUS_SSH_CONFIG="$LEGACY/.ssh/config" GITPLUS_GITCONFIG="$LEGACY/.gitconfig" \
       GITPLUS_SSH_KEY_DIR="$LEGACY/.ssh" "$ACCT" "$@"; }
saw "legacy account is listed"        "$(lg list)" "legacy"
saw "legacy binding is listed"        "$(lg list)" "$LEGACY/code/old"
saw "legacy gh-user is read"          "$(lg list)" "legacy-gh"
check "legacy binding resolves for a dir" "$(lg _gh-for-dir "$LEGACY/code/old")" "legacy-gh"
# ...and re-adding must not duplicate a block written under the old prefix.
before="$(cat "$LEGACY/.ssh/config")"
lg add legacy --email legacy@old.com >/dev/null 2>&1
check "re-add doesn't duplicate a legacy block" "$(cat "$LEGACY/.ssh/config")" "$before"

echo ""
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]

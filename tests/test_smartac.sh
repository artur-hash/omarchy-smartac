#!/usr/bin/env bash
# Backend tests. Every external command the backend touches is faked on PATH,
# so nothing here reaches the network or the real keyring.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0; FAIL=0

setup() {
  TMP=$(mktemp -d)
  export SECRET_STORE="$TMP/secret"
  export PATH="$TMP/bin:$PATH"
  mkdir -p "$TMP/bin"
  cat >"$TMP/bin/secret-tool" <<'FAKE'
#!/usr/bin/env bash
case "$1" in
  store)  cat > "$SECRET_STORE" ;;
  lookup) [[ -f $SECRET_STORE ]] || exit 1; cat "$SECRET_STORE" ;;
  clear)  rm -f "$SECRET_STORE" ;;
esac
FAKE
  chmod +x "$TMP/bin/secret-tool"
}

teardown() { rm -rf "$TMP"; }

ok()    { PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
bad()   { FAIL=$((FAIL+1)); printf '  FAIL  %s\n        %s\n' "$1" "$2"; }
check() { [[ $2 == "$3" ]] && ok "$1" || bad "$1" "expected [$3], got [$2]"; }

test_token_set_reads_stdin() {
  setup
  printf 'tok-abc' | "$ROOT/bin/smartac" token set >/dev/null 2>&1
  check "token set stores what came on stdin" "$(cat "$SECRET_STORE")" "tok-abc"
  teardown
}

test_token_never_in_argv() {
  setup
  # Refused outright, not quietly accepted: /proc/<pid>/cmdline exposes an
  # argument to every process on the session for the length of the call.
  out=$("$ROOT/bin/smartac" token set tok-in-argv 2>&1); rc=$?
  check "token set rejects an argument" "$rc" "2"
  [[ $out == *stdin* ]] && ok "the refusal names stdin" || bad "refusal message" "got [$out]"
  teardown
}

test_token_status_and_clear() {
  setup
  printf 'tok-abc' | "$ROOT/bin/smartac" token set >/dev/null 2>&1
  check "status reports a token" "$("$ROOT/bin/smartac" token status --json | jq -r .hasToken)" "true"
  "$ROOT/bin/smartac" token clear >/dev/null 2>&1
  check "status reports none after clear" "$("$ROOT/bin/smartac" token status --json | jq -r .hasToken)" "false"
  teardown
}

test_token_set_reads_stdin
test_token_never_in_argv
test_token_status_and_clear

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]

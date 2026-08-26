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

# Fake curl: records its arguments, records stdin, prints the fixture, then the
# status code on its own line — the shape the real curl produces with -w '\n%{http_code}'.
fake_curl() {
  local status="$1" body_file="$2"
  cat >"$TMP/bin/curl" <<FAKE
#!/usr/bin/env bash
printf '%s ' "\$@" >> "$TMP/curl.args"
cat > "$TMP/curl.stdin"
cat "$body_file"
printf '\n%s' "$status"
FAKE
  chmod +x "$TMP/bin/curl"
}

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

test_devices_filters_by_capability() {
  setup
  printf 'tok' | "$ROOT/bin/smartac" token set >/dev/null 2>&1
  fake_curl 200 "$ROOT/tests/fixtures/devices.json"
  out=$("$ROOT/bin/smartac" devices --json)
  check "only the AC is listed"   "$(jq -r '.devices | length' <<<"$out")" "1"
  check "the AC's id survives"    "$(jq -r '.devices[0].id' <<<"$out")"    "ac-1"
  check "the AC's label survives" "$(jq -r '.devices[0].label' <<<"$out")" "Sala"
  teardown
}

test_devices_sends_bearer_token() {
  setup
  printf 'tok-xyz' | "$ROOT/bin/smartac" token set >/dev/null 2>&1
  fake_curl 200 "$ROOT/tests/fixtures/devices.json"
  "$ROOT/bin/smartac" devices --json >/dev/null
  grep -q "Bearer tok-xyz" "$TMP/curl.stdin" \
    && ok "the request carries the bearer token via stdin" \
    || bad "bearer token" "not in the recorded curl stdin"
  teardown
}

test_token_absent_from_argv() {
  setup
  printf 'tok-secret' | "$ROOT/bin/smartac" token set >/dev/null 2>&1
  fake_curl 200 "$ROOT/tests/fixtures/devices.json"
  "$ROOT/bin/smartac" devices --json >/dev/null
  grep -q "tok-secret" "$TMP/curl.args" \
    && bad "token exposed" "found in curl arguments, but should be in stdin only" \
    || ok "token is absent from curl arguments"
  teardown
}

test_401_clears_the_token() {
  setup
  printf 'tok-bad' | "$ROOT/bin/smartac" token set >/dev/null 2>&1
  fake_curl 401 /dev/null
  "$ROOT/bin/smartac" devices --json >/dev/null 2>&1; rc=$?
  check "a 401 exits 3" "$rc" "3"
  check "a 401 clears the stored token" \
        "$("$ROOT/bin/smartac" token status --json | jq -r .hasToken)" "false"
  teardown
}

test_no_token_is_its_own_exit_code() {
  setup
  "$ROOT/bin/smartac" devices --json >/dev/null 2>&1; rc=$?
  check "no token exits 2" "$rc" "2"
  teardown
}

test_status_shape() {
  setup
  printf 'tok' | "$ROOT/bin/smartac" token set >/dev/null 2>&1
  jq -s '.[0] * .[1]' "$ROOT/tests/fixtures/status.json" \
     <(echo '{"state":"ONLINE"}') >"$TMP/both.json"
  fake_curl 200 "$TMP/both.json"
  out=$("$ROOT/bin/smartac" status --json --device ac-1)
  check "power"       "$(jq -r .power <<<"$out")"       "on"
  check "temperature" "$(jq -r .temperature <<<"$out")" "24.5"
  check "setpoint"    "$(jq -r .setpoint <<<"$out")"    "22"
  check "unit"        "$(jq -r .unit <<<"$out")"        "C"
  check "online"      "$(jq -r .online <<<"$out")"      "true"
  teardown
}

test_status_reports_an_offline_device() {
  setup
  printf 'tok' | "$ROOT/bin/smartac" token set >/dev/null 2>&1
  jq -s '.[0] * .[1]' "$ROOT/tests/fixtures/status.json" \
     <(echo '{"state":"OFFLINE"}') >"$TMP/both.json"
  fake_curl 200 "$TMP/both.json"
  out=$("$ROOT/bin/smartac" status --json --device ac-1)
  check "an OFFLINE device reports online:false" "$(jq -r .online <<<"$out")" "false"
  teardown
}

test_status_missing_capability_is_null_not_absent() {
  setup
  printf 'tok' | "$ROOT/bin/smartac" token set >/dev/null 2>&1
  echo '{"state":"ONLINE","components":{"main":{"switch":{"switch":{"value":"off"}}}}}' >"$TMP/partial.json"
  fake_curl 200 "$TMP/partial.json"
  out=$("$ROOT/bin/smartac" status --json --device ac-1)
  # null, not absent: the UI distinguishes "this device has no thermometer"
  # from "the field never arrived", and only one deserves a message.
  check "temperature is null" "$(jq -r '.temperature' <<<"$out")"    "null"
  check "the key is present"  "$(jq 'has("temperature")' <<<"$out")" "true"
  teardown
}

test_status_requires_device() {
  setup
  printf 'tok' | "$ROOT/bin/smartac" token set >/dev/null 2>&1
  "$ROOT/bin/smartac" status --json >/dev/null 2>&1
  check "status without --device exits 2" "$?" "2"
  teardown
}

test_token_set_reads_stdin
test_token_never_in_argv
test_token_status_and_clear
test_devices_filters_by_capability
test_devices_sends_bearer_token
test_token_absent_from_argv
test_401_clears_the_token
test_no_token_is_its_own_exit_code
test_status_shape
test_status_reports_an_offline_device
test_status_missing_capability_is_null_not_absent
test_status_requires_device

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]

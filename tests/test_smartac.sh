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

# Smart fake curl for tests that need to distinguish /health from /status.
# Checks the request path and returns different bodies accordingly.
fake_curl_paths() {
  local status="$1" health_file="$2" status_file="$3"
  cat >"$TMP/bin/curl" <<FAKE
#!/usr/bin/env bash
printf '%s ' "\$@" >> "$TMP/curl.args"
cat > "$TMP/curl.stdin"

# Check the URL in the arguments to determine which response to return.
if printf '%s ' "\$@" | grep -q "/health"; then
  cat "$health_file"
elif printf '%s ' "\$@" | grep -q "/status"; then
  cat "$status_file"
else
  # Fallback
  cat "$health_file"
fi

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
  echo '{"state":"ONLINE"}' >"$TMP/health.json"
  fake_curl_paths 200 "$TMP/health.json" "$ROOT/tests/fixtures/status.json"
  out=$("$ROOT/bin/smartac" status --json --device ac-1)
  check "power"       "$(jq -r .power <<<"$out")"       "on"
  check "temperature" "$(jq -r .temperature <<<"$out")" "24.5"
  check "setpoint"    "$(jq -r .setpoint <<<"$out")"    "22"
  check "unit"        "$(jq -r .unit <<<"$out")"        "C"
  check "online"      "$(jq -r .online <<<"$out")"      "true"
  teardown
}

test_status_online_comes_from_health() {
  setup
  printf 'tok' | "$ROOT/bin/smartac" token set >/dev/null 2>&1
  # health says ONLINE, status has no state field at top level.
  # This proves that online:true comes from /health, not /status.
  echo '{"state":"ONLINE"}' >"$TMP/health.json"
  echo '{"components":{"main":{"switch":{"switch":{"value":"on"}}}}}' >"$TMP/status.json"
  fake_curl_paths 200 "$TMP/health.json" "$TMP/status.json"
  out=$("$ROOT/bin/smartac" status --json --device ac-1)
  check "online from ONLINE health" "$(jq -r .online <<<"$out")" "true"
  teardown
}

test_status_reports_an_offline_device() {
  setup
  printf 'tok' | "$ROOT/bin/smartac" token set >/dev/null 2>&1
  # health says OFFLINE, status is irrelevant
  echo '{"state":"OFFLINE"}' >"$TMP/health.json"
  fake_curl_paths 200 "$TMP/health.json" "$ROOT/tests/fixtures/status.json"
  out=$("$ROOT/bin/smartac" status --json --device ac-1)
  check "an OFFLINE device reports online:false" "$(jq -r .online <<<"$out")" "false"
  teardown
}

test_status_missing_capability_is_null_not_absent() {
  setup
  printf 'tok' | "$ROOT/bin/smartac" token set >/dev/null 2>&1
  echo '{"state":"ONLINE"}' >"$TMP/health.json"
  echo '{"components":{"main":{"switch":{"switch":{"value":"off"}}}}}' >"$TMP/status.json"
  fake_curl_paths 200 "$TMP/health.json" "$TMP/status.json"
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

test_status_preserves_401_exit_code_from_health() {
  setup
  printf 'tok-bad' | "$ROOT/bin/smartac" token set >/dev/null 2>&1
  # A 401 from the health call should exit with code 3, not 1
  fake_curl 401 /dev/null
  "$ROOT/bin/smartac" status --json --device ac-1 >/dev/null 2>&1; rc=$?
  check "a 401 on health exits 3" "$rc" "3"
  teardown
}

test_status_guards_malformed_health() {
  setup
  printf 'tok' | "$ROOT/bin/smartac" token set >/dev/null 2>&1
  # Invalid JSON in health response should die with proper error
  echo 'not valid json' >"$TMP/health.json"
  fake_curl_paths 200 "$TMP/health.json" "$ROOT/tests/fixtures/status.json"
  out=$("$ROOT/bin/smartac" status --json --device ac-1 2>&1); rc=$?
  [[ $rc -ne 0 ]] && ok "malformed health causes non-zero exit" || bad "exit code" "got 0"
  [[ $out == *"error"* ]] && ok "error is in JSON format" || bad "error format" "got [$out]"
  teardown
}

test_power_sends_the_switch_command() {
  setup
  printf 'tok' | "$ROOT/bin/smartac" token set >/dev/null 2>&1
  echo '{"results":[{"status":"ACCEPTED"}]}' >"$TMP/ok.json"
  fake_curl 200 "$TMP/ok.json"
  "$ROOT/bin/smartac" power on --device ac-1 >/dev/null
  args=$(cat "$TMP/curl.args")
  grep -q '"capability":"switch"' <<<"$args" && ok "capability is switch"   || bad "capability" "$args"
  grep -q '"command":"on"'        <<<"$args" && ok "command is on"          || bad "command" "$args"
  grep -q 'devices/ac-1/commands' <<<"$args" && ok "hits the commands path" || bad "path" "$args"
  teardown
}

test_temp_sends_a_numeric_setpoint() {
  setup
  printf 'tok' | "$ROOT/bin/smartac" token set >/dev/null 2>&1
  echo '{"results":[{"status":"ACCEPTED"}]}' >"$TMP/ok.json"
  fake_curl 200 "$TMP/ok.json"
  "$ROOT/bin/smartac" temp 22 --device ac-1 >/dev/null
  args=$(cat "$TMP/curl.args")
  grep -q '"command":"setCoolingSetpoint"' <<<"$args" \
    && ok "command is setCoolingSetpoint" || bad "command" "$args"
  # 22, not "22" — the API rejects the quoted form. Asserted on the bytes that
  # went out, not on the shape of the jq call that produced them.
  grep -q '"arguments":\[22\]' <<<"$args" \
    && ok "the argument is a JSON number" || bad "arguments" "$args"
  teardown
}

test_temp_rejects_non_numeric() {
  setup
  printf 'tok' | "$ROOT/bin/smartac" token set >/dev/null 2>&1
  "$ROOT/bin/smartac" temp cold --device ac-1 >/dev/null 2>&1
  check "a non-numeric temperature exits 2" "$?" "2"
  teardown
}

test_power_rejects_other_words() {
  setup
  printf 'tok' | "$ROOT/bin/smartac" token set >/dev/null 2>&1
  "$ROOT/bin/smartac" power maybe --device ac-1 >/dev/null 2>&1
  check "power only accepts on/off" "$?" "2"
  teardown
}

test_power_device_flag_missing_value() {
  setup
  printf 'tok' | "$ROOT/bin/smartac" token set >/dev/null 2>&1
  timeout 2 "$ROOT/bin/smartac" power on --device >/dev/null 2>&1
  check "power with bare --device exits 2, not hang" "$?" "2"
  teardown
}

test_status_device_flag_missing_value() {
  setup
  printf 'tok' | "$ROOT/bin/smartac" token set >/dev/null 2>&1
  timeout 2 "$ROOT/bin/smartac" status --json --device >/dev/null 2>&1
  check "status with bare --device exits 2, not hang" "$?" "2"
  teardown
}

test_parse_error_emits_exactly_one_json_object() {
  setup
  printf 'tok' | "$ROOT/bin/smartac" token set >/dev/null 2>&1
  err_output=$("$ROOT/bin/smartac" power on --device ac-1 --bogus 2>&1 >/dev/null)
  # Count the number of lines in stderr (one JSON object per line expected)
  line_count=$(printf '%s' "$err_output" | grep -c '^{.*}$')
  check "parse error emits exactly one JSON object" "$line_count" "1"
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
test_status_online_comes_from_health
test_status_reports_an_offline_device
test_status_missing_capability_is_null_not_absent
test_status_requires_device
test_status_preserves_401_exit_code_from_health
test_status_guards_malformed_health
test_power_sends_the_switch_command
test_temp_sends_a_numeric_setpoint
test_temp_rejects_non_numeric
test_power_rejects_other_words
test_power_device_flag_missing_value
test_status_device_flag_missing_value
test_parse_error_emits_exactly_one_json_object

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]

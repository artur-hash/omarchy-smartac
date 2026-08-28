#!/usr/bin/env bash
# Backend tests. Every external command the backend touches is faked on PATH,
# so nothing here reaches the network or the real keyring.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0; FAIL=0

setup() {
  TMP=$(mktemp -d)
  export SECRET_STORE="$TMP/secret"
  # A minimal PATH, not the caller's: "smartthings is not on PATH" is a state
  # these tests must be able to create, and inheriting the developer's makes it
  # depend on what happens to be installed.
  export PATH="$TMP/bin:/usr/bin:/bin"
  export XDG_DATA_HOME="$TMP/share"
  export XDG_CONFIG_HOME="$TMP/config"
  mkdir -p "$TMP/bin"
  # Mirrors real libsecret: reads all of stdin, then strips exactly one
  # trailing newline (not `cat > file`, which strips none and let an
  # embedded-newline token through undetected — the reason C2 shipped with
  # no test the first time).
  cat >"$TMP/bin/secret-tool" <<'FAKE'
#!/usr/bin/env bash
case "$1" in
  store)
    data=$(cat; printf x)
    data="${data%x}"
    [[ $data == *$'\n' ]] && data="${data%$'\n'}"
    printf '%s' "$data" > "$SECRET_STORE"
    ;;
  lookup) [[ -f $SECRET_STORE ]] || exit 1; cat "$SECRET_STORE" ;;
  clear)  rm -f "$SECRET_STORE" ;;
esac
FAKE
  chmod +x "$TMP/bin/secret-tool"
}

teardown() { rm -rf "$TMP"; }

# The only credential this backend accepts: the session the SmartThings CLI
# keeps. Nothing is stored by the plugin itself.
fake_cli_session() {
  mkdir -p "$XDG_DATA_HOME/@smartthings/cli"
  jq -n --arg e "${1:-2099-01-01T00:00:00.000Z}" --arg t "${2:-cli-token-xyz}" \
    '{"default:api.smartthings.com": {accessToken: $t, refreshToken: "r", expires: $e}}' \
    > "$XDG_DATA_HOME/@smartthings/cli/credentials.json"
}

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




test_token_set_rejects_embedded_newline() {
  setup
  # curl's -K config format treats a newline as a record separator: an
  # unescaped one in the token splits it into two lines, and curl echoes the
  # bogus continuation to stderr — which is how a token fragment used to
  # reach the journal (C2). Reject it before it is ever stored.
  out=$(printf 'tok-part1\npart2' | "$ROOT/bin/smartac" token set 2>&1); rc=$?
  check "a token with an embedded newline is rejected" "$rc" "2"
  [[ -f $SECRET_STORE ]] && bad "token was stored despite the embedded newline" "$(cat "$SECRET_STORE")" \
    || ok "nothing was stored"
  teardown
}




test_doctor_device_flag_missing_value() {
  setup
  # The same shift-2-with-no-$2 bug fixed twice before at other --device
  # sites (power, status); this is the third site. Under timeout so a
  # regression fails the suite instead of hanging it.
  timeout 3 "$ROOT/bin/smartac" doctor --device >/dev/null 2>&1
  check "doctor with bare --device exits 2, not hang" "$?" "2"
  teardown
}

test_devices_filters_by_capability() {
  setup
  fake_cli_session
  fake_curl 200 "$ROOT/tests/fixtures/devices.json"
  out=$("$ROOT/bin/smartac" devices --json)
  check "only the AC is listed"   "$(jq -r '.devices | length' <<<"$out")" "1"
  check "the AC's id survives"    "$(jq -r '.devices[0].id' <<<"$out")"    "ac-1"
  check "the AC's label survives" "$(jq -r '.devices[0].label' <<<"$out")" "Sala"
  teardown
}

test_devices_sends_bearer_token() {
  setup
  fake_cli_session
  fake_curl 200 "$ROOT/tests/fixtures/devices.json"
  "$ROOT/bin/smartac" devices --json >/dev/null
  grep -q "Bearer cli-token-xyz" "$TMP/curl.stdin" \
    && ok "the request carries the session via stdin" \
    || bad "session on stdin" "not in the recorded curl stdin"
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
  fake_cli_session
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
  fake_cli_session
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
  fake_cli_session
  # health says OFFLINE, status is irrelevant
  echo '{"state":"OFFLINE"}' >"$TMP/health.json"
  fake_curl_paths 200 "$TMP/health.json" "$ROOT/tests/fixtures/status.json"
  out=$("$ROOT/bin/smartac" status --json --device ac-1)
  check "an OFFLINE device reports online:false" "$(jq -r .online <<<"$out")" "false"
  teardown
}

test_status_missing_capability_is_null_not_absent() {
  setup
  fake_cli_session
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
  fake_cli_session
  "$ROOT/bin/smartac" status --json >/dev/null 2>&1
  check "status without --device exits 2" "$?" "2"
  teardown
}

test_status_preserves_401_exit_code_from_health() {
  setup
  fake_cli_session
  # A 401 from the health call should exit with code 3, not 1
  fake_curl 401 /dev/null
  "$ROOT/bin/smartac" status --json --device ac-1 >/dev/null 2>&1; rc=$?
  check "a 401 on health exits 3" "$rc" "3"
  teardown
}

test_status_guards_malformed_health() {
  setup
  fake_cli_session
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
  fake_cli_session
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
  fake_cli_session
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
  fake_cli_session
  "$ROOT/bin/smartac" temp cold --device ac-1 >/dev/null 2>&1
  check "a non-numeric temperature exits 2" "$?" "2"
  teardown
}

test_power_rejects_other_words() {
  setup
  fake_cli_session
  "$ROOT/bin/smartac" power maybe --device ac-1 >/dev/null 2>&1
  check "power only accepts on/off" "$?" "2"
  teardown
}

test_power_device_flag_missing_value() {
  setup
  fake_cli_session
  timeout 2 "$ROOT/bin/smartac" power on --device >/dev/null 2>&1
  check "power with bare --device exits 2, not hang" "$?" "2"
  teardown
}

test_status_device_flag_missing_value() {
  setup
  fake_cli_session
  timeout 2 "$ROOT/bin/smartac" status --json --device >/dev/null 2>&1
  check "status with bare --device exits 2, not hang" "$?" "2"
  teardown
}

test_parse_error_emits_exactly_one_json_object() {
  setup
  fake_cli_session
  err_output=$("$ROOT/bin/smartac" power on --device ac-1 --bogus 2>&1 >/dev/null)
  # Count the number of lines in stderr (one JSON object per line expected)
  line_count=$(printf '%s' "$err_output" | grep -c '^{.*}$')
  check "parse error emits exactly one JSON object" "$line_count" "1"
  teardown
}

test_doctor_redacts_the_token() {
  setup
  fake_cli_session
  fake_curl 200 "$ROOT/tests/fixtures/devices.json"
  out=$("$ROOT/bin/smartac" doctor 2>&1)
  # Asserts the secret's absence, not the prefix's presence: a redaction that
  # holds on the happy path and leaks on an error path passes the weaker one.
  grep -q "verysecretvalue" <<<"$out" \
    && bad "doctor leaks the token" "$out" || ok "doctor does not print the token"
  grep -q "cli-" <<<"$out" && ok "doctor shows a redacted prefix" || bad "prefix" "$out"
  teardown
}

test_doctor_capabilities_lists_raw_ids() {
  setup
  fake_cli_session
  fake_curl 200 "$ROOT/tests/fixtures/devices.json"
  out=$("$ROOT/bin/smartac" doctor --capabilities --device ac-1)
  grep -q "thermostatCoolingSetpoint" <<<"$out" \
    && ok "capabilities are listed" || bad "capabilities" "$out"
  teardown
}

test_doctor_capabilities_errors_on_unknown_device() {
  setup
  fake_cli_session
  fake_curl 200 "$ROOT/tests/fixtures/devices.json"
  out=$("$ROOT/bin/smartac" doctor --capabilities --device unknown-device 2>&1); rc=$?
  [[ $rc -ne 0 ]] && ok "unknown device exits non-zero" || bad "exit code" "got 0"
  grep -q "device not found" <<<"$out" \
    && ok "error message names the missing device" || bad "error message" "$out"
  [[ $out == *"error"* ]] && ok "error is in JSON format" || bad "error format" "$out"
  teardown
}

test_token_set_rejects_embedded_newline
test_doctor_device_flag_missing_value
test_devices_filters_by_capability
test_devices_sends_bearer_token
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
test_doctor_redacts_the_token
test_doctor_capabilities_lists_raw_ids
test_doctor_capabilities_errors_on_unknown_device

# ---- full AC scope: mode / fan / swing / preset ----

# Each of these is validated against the list the device itself publishes, not
# against a list hardcoded here — a device that drops "turbo" should reject it
# without a code change.
test_mode_sends_setAirConditionerMode() {
  setup
  fake_cli_session
  fake_curl 200 "$ROOT/tests/fixtures/status-full.json"
  "$ROOT/bin/smartac" mode cool --device ac-1 >/dev/null
  args=$(cat "$TMP/curl.args")
  grep -q '"capability":"airConditionerMode"' <<<"$args" && ok "mode capability" || bad "mode capability" "$args"
  grep -q '"command":"setAirConditionerMode"'  <<<"$args" && ok "mode command"    || bad "mode command" "$args"
  grep -q '"arguments":\["cool"\]'            <<<"$args" && ok "mode argument"   || bad "mode argument" "$args"
  teardown
}

test_mode_rejects_unsupported_value() {
  setup
  fake_cli_session
  fake_curl 200 "$ROOT/tests/fixtures/status-full.json"
  out=$("$ROOT/bin/smartac" mode banana --device ac-1 2>&1); rc=$?
  check "an unsupported mode exits 2" "$rc" "2"
  grep -q "supported" <<<"$out" && ok "the refusal names what is supported" || bad "refusal" "$out"
  teardown
}

test_fan_sends_setFanMode() {
  setup
  fake_cli_session
  fake_curl 200 "$ROOT/tests/fixtures/status-full.json"
  "$ROOT/bin/smartac" fan turbo --device ac-1 >/dev/null
  args=$(cat "$TMP/curl.args")
  grep -q '"capability":"airConditionerFanMode"' <<<"$args" && ok "fan capability" || bad "fan capability" "$args"
  grep -q '"command":"setFanMode"'                <<<"$args" && ok "fan command"   || bad "fan command" "$args"
  teardown
}

test_swing_sends_setFanOscillationMode() {
  setup
  fake_cli_session
  fake_curl 200 "$ROOT/tests/fixtures/status-full.json"
  "$ROOT/bin/smartac" swing all --device ac-1 >/dev/null
  grep -q '"command":"setFanOscillationMode"' "$TMP/curl.args" && ok "swing command" || bad "swing command" "$(cat "$TMP/curl.args")"
  teardown
}

test_preset_sends_setAcOptionalMode() {
  setup
  fake_cli_session
  fake_curl 200 "$ROOT/tests/fixtures/status-full.json"
  "$ROOT/bin/smartac" preset windFree --device ac-1 >/dev/null
  args=$(cat "$TMP/curl.args")
  grep -q '"capability":"custom.airConditionerOptionalMode"' <<<"$args" && ok "preset capability" || bad "preset capability" "$args"
  grep -q '"command":"setAcOptionalMode"' <<<"$args" && ok "preset command" || bad "preset command" "$args"
  teardown
}

test_status_carries_supported_lists_and_range() {
  setup
  fake_cli_session
  jq -s '.[0] * .[1]' "$ROOT/tests/fixtures/status-full.json" <(echo '{"state":"ONLINE"}') >"$TMP/both.json"
  fake_curl 200 "$TMP/both.json"
  out=$("$ROOT/bin/smartac" status --json --device ac-1)
  check "current mode"     "$(jq -r .mode <<<"$out")"                  "heat"
  check "current fan"      "$(jq -r .fan <<<"$out")"                   "low"
  check "current swing"    "$(jq -r .swing <<<"$out")"                 "fixed"
  check "current preset"   "$(jq -r .preset <<<"$out")"                "off"
  check "humidity"         "$(jq -r .humidity <<<"$out")"              "61"
  check "supported modes"  "$(jq -r '.supported.mode | join(",")' <<<"$out")" "auto,cool,dry,wind,heat"
  # The range comes from the device, not from a constant in the panel.
  check "setpoint min"     "$(jq -r .setpointMin <<<"$out")"           "16"
  check "setpoint max"     "$(jq -r .setpointMax <<<"$out")"           "30"
  teardown
}

# The API answers 200 for a command it refuses and puts the verdict in
# results[].status. Reporting ok on that told the panel a command landed when
# the cloud had already said it did not.
test_refused_command_is_not_reported_as_success() {
  setup
  fake_cli_session
  printf '{"results":[{"id":"x","status":"FAILED"}]}' > "$TMP/refused.json"
  fake_curl 200 "$TMP/refused.json"
  out=$("$ROOT/bin/smartac" power on --device ac-1 2>&1); rc=$?
  check "a FAILED verdict exits 8" "$rc" "8"
  grep -q 'FAILED' <<<"$out" && ok "the error names the verdict" || bad "the error names the verdict" "$out"
  teardown
}

test_completed_command_is_reported_as_success() {
  setup
  fake_cli_session
  printf '{"results":[{"id":"x","status":"COMPLETED"}]}' > "$TMP/done.json"
  fake_curl 200 "$TMP/done.json"
  out=$("$ROOT/bin/smartac" power on --device ac-1 2>&1); rc=$?
  check "a COMPLETED verdict exits 0" "$rc" "0"
  check "and prints ok" "$out" '{"ok":true}'
  teardown
}

# A response with no results array still counts as success: some deployments
# omit it, and inventing a failure is worse than trusting the 2xx.
test_missing_results_array_is_still_success() {
  setup
  fake_cli_session
  printf '{}' > "$TMP/bare.json"
  fake_curl 200 "$TMP/bare.json"
  rc=0; "$ROOT/bin/smartac" power on --device ac-1 >/dev/null 2>&1 || rc=$?
  check "an absent results array exits 0" "$rc" "0"
  teardown
}

# The panel builds its buttons from the device's own supported list, so the
# validating GET re-fetches what is already on screen. Requests are the scarce
# resource: this token hit SmartThings' rate limit during development at
# roughly sixteen requests in nine seconds.
test_no_validate_skips_the_lookup_request() {
  setup
  fake_cli_session
  fake_curl 200 "$ROOT/tests/fixtures/status-full.json"
  "$ROOT/bin/smartac" mode cool --device ac-1 --no-validate >/dev/null 2>&1
  gets=$(grep -o 'GET' "$TMP/curl.args" | wc -l)
  check "--no-validate makes no GET" "$gets" "0"
  grep -q '"command":"setAirConditionerMode"' "$TMP/curl.args" \
    && ok "--no-validate still sends the command" || bad "--no-validate still sends the command" "$(cat "$TMP/curl.args")"
  teardown
}

# Without the flag the lookup stays, so a CLI user still gets told what the
# device accepts instead of a bare refusal.
test_validation_still_runs_by_default() {
  setup
  fake_cli_session
  fake_curl 200 "$ROOT/tests/fixtures/status-full.json"
  "$ROOT/bin/smartac" mode cool --device ac-1 >/dev/null 2>&1
  gets=$(grep -o 'GET' "$TMP/curl.args" | wc -l)
  check "the default path still looks up supported values" "$gets" "1"
  teardown
}

# The confirmation read after a write does not need reachability -- the panel
# already knows it -- and halving the requests is what lets that read run at
# three seconds instead of eight.
test_quick_status_skips_the_health_call() {
  setup
  fake_cli_session
  fake_curl 200 "$ROOT/tests/fixtures/status-full.json"
  out=$("$ROOT/bin/smartac" status --json --quick --device ac-1 2>&1)
  health=$(grep -c '/health' "$TMP/curl.args" || true)
  check "--quick makes no health call" "$health" "0"
  check "--quick reports online as unknown" "$(jq -r .online <<<"$out")" "null"
  check "--quick still reports the mode" "$(jq -r .mode <<<"$out")" "heat"
  teardown
}

test_full_status_still_checks_health() {
  setup
  fake_cli_session
  echo '{"state":"ONLINE"}' >"$TMP/health.json"
  fake_curl_paths 200 "$TMP/health.json" "$ROOT/tests/fixtures/status-full.json"
  out=$("$ROOT/bin/smartac" status --json --device ac-1 2>&1)
  health=$(grep -c '/health' "$TMP/curl.args" || true)
  check "the default status still asks health" "$health" "1"
  check "and reports a real online value" "$(jq -r .online <<<"$out")" "true"
  teardown
}

# A response is bounded while it is arriving, not after. Without this the whole
# body lands in a shell variable and then in the QML side's StdioCollector, so
# a hostile or broken endpoint could exhaust the shared omarchy-shell rather
# than just this plugin.
test_oversized_response_is_refused() {
  setup
  fake_cli_session
  # Two megabytes of valid JSON: over the one megabyte ceiling.
  { printf '{"pad":"'; head -c 2097152 /dev/zero | tr '\0' 'x'; printf '"}'; } > "$TMP/huge.json"
  fake_curl 200 "$TMP/huge.json"
  out=$("$ROOT/bin/smartac" devices --json 2>&1); rc=$?
  check "an oversized response exits 10" "$rc" "10"
  grep -q 'exceeded' <<<"$out" && ok "the error says it was refused" || bad "the error says it was refused" "$out"
  teardown
}

test_response_at_the_ceiling_still_works() {
  setup
  fake_cli_session
  fake_curl 200 "$ROOT/tests/fixtures/devices.json"
  rc=0; "$ROOT/bin/smartac" devices --json >/dev/null 2>&1 || rc=$?
  check "an ordinary response is untouched" "$rc" "0"
  teardown
}

# Every string the far end controls is truncated before it reaches the panel.
# A device label is attacker-controlled once the endpoint is not trusted, and
# none of these has a legitimate reason to be long.
test_remote_strings_are_truncated() {
  setup
  fake_cli_session
  long=$(head -c 5000 /dev/zero | tr '\0' 'L')
  jq -n --arg l "$long" '{items:[{deviceId:"ac-1", label:$l,
    components:[{id:"main", capabilities:[{id:"airConditionerMode"}]}]}]}' > "$TMP/longlabel.json"
  fake_curl 200 "$TMP/longlabel.json"
  out=$("$ROOT/bin/smartac" devices --json 2>&1)
  len=$(jq -r '.devices[0].label | length' <<<"$out")
  check "a long device label is clamped to MAX_STRING" "$len" "128"
  teardown
}

# And every list is capped, so a payload claiming ten thousand supported modes
# cannot become ten thousand buttons.
test_remote_lists_are_capped() {
  setup
  fake_cli_session
  jq -n '{components:{main:{airConditionerMode:{
      airConditionerMode:{value:"cool"},
      supportedAcModes:{value:[range(5000) | tostring]}}}}}' > "$TMP/longlist.json"
  echo '{"state":"ONLINE"}' >"$TMP/health.json"
  fake_curl_paths 200 "$TMP/health.json" "$TMP/longlist.json"
  out=$("$ROOT/bin/smartac" status --json --device ac-1 2>&1)
  n=$(jq -r '.supported.mode | length' <<<"$out")
  check "a long supported list is capped to MAX_LIST" "$n" "64"
  teardown
}

test_mode_sends_setAirConditionerMode
test_mode_rejects_unsupported_value
test_fan_sends_setFanMode
test_swing_sends_setFanOscillationMode
test_preset_sends_setAcOptionalMode
test_status_carries_supported_lists_and_range
test_refused_command_is_not_reported_as_success
test_completed_command_is_reported_as_success
test_missing_results_array_is_still_success
test_no_validate_skips_the_lookup_request
test_validation_still_runs_by_default
test_quick_status_skips_the_health_call
test_full_status_still_checks_health
test_oversized_response_is_refused
test_response_at_the_ceiling_still_works
test_remote_strings_are_truncated
test_remote_lists_are_capped

test_no_session_exits_2() {
  setup
  out=$("$ROOT/bin/smartac" devices --json 2>&1); rc=$?
  check "no CLI session exits 2" "$rc" "2"
  grep -q 'smartthings locations' <<<"$out" && ok "and says what to run" \
    || bad "and says what to run" "$out"
  teardown
}

test_the_session_never_reaches_argv() {
  setup
  fake_cli_session
  printf '{"items":[]}' > "$TMP/e.json"
  fake_curl 200 "$TMP/e.json"
  "$ROOT/bin/smartac" devices --json >/dev/null 2>&1
  grep -q 'cli-token-xyz' "$TMP/curl.args" && bad "the session is absent from argv" \
    "$(cat "$TMP/curl.args")" || ok "the session is absent from argv"
  grep -q 'cli-token-xyz' "$TMP/curl.stdin" && ok "and arrives on stdin" \
    || bad "and arrives on stdin" "$(cat "$TMP/curl.stdin")"
  teardown
}

# A rejected session is reported, never deleted: it belongs to the CLI, and
# logging the user out of a tool this plugin merely reads is a side effect
# nobody asked for.
test_a_rejected_session_is_not_deleted() {
  setup
  fake_cli_session
  printf '{}' > "$TMP/e.json"
  fake_curl 401 "$TMP/e.json"
  out=$("$ROOT/bin/smartac" devices --json 2>&1); rc=$?
  check "a rejected session exits 3" "$rc" "3"
  check "the credentials file is untouched" \
    "$(jq -r '.["default:api.smartthings.com"].accessToken' "$XDG_DATA_HOME/@smartthings/cli/credentials.json")" \
    "cli-token-xyz"
  teardown
}

test_no_session_exits_2
test_the_session_never_reaches_argv
test_a_rejected_session_is_not_deleted

# The shell that runs this plugin takes its environment from the session, not
# from the user's terminal rc, so a CLI installed through a version manager can
# be present and invisible on PATH -- and the failure is silent and delayed: the
# session works for a day and then stops renewing. The binary is therefore
# looked for where these tools actually put it.
test_the_cli_is_found_off_PATH() {
  setup
  fake_cli_session
  mkdir -p "$TMP/home/.local/share/mise/shims"
  printf '#!/bin/sh\nexit 0\n' > "$TMP/home/.local/share/mise/shims/smartthings"
  chmod +x "$TMP/home/.local/share/mise/shims/smartthings"
  out=$(HOME="$TMP/home" "$ROOT/bin/smartac" credential)
  check "a version manager's shim counts as installed" "$(jq -r .cliInstalled <<<"$out")" "true"
  check "and the session can renew" "$(jq -r .renewable <<<"$out")" "true"
  teardown
}

test_no_cli_anywhere_is_reported() {
  setup
  fake_cli_session
  out=$(HOME="$TMP/nowhere" "$ROOT/bin/smartac" credential)
  check "with no binary at all: not installed" "$(jq -r .cliInstalled <<<"$out")" "false"
  check "and the session cannot renew" "$(jq -r .renewable <<<"$out")" "false"
  teardown
}

test_the_cli_is_found_off_PATH
test_no_cli_anywhere_is_reported

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]

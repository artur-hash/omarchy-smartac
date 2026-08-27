// Unit tests for Model.js. Run: node tests/test_model.js
const assert = require("assert");
const path = require("path");
const M = require(path.join(__dirname, "..", "Model.js"));

const tests = [];
function test(name, fn) { tests.push([name, fn]); }

test("parseStatus reads a full payload", () => {
  const s = M.parseStatus('{"power":"on","temperature":24.5,"setpoint":22,"unit":"C","online":true}');
  assert.strictEqual(s.ok, true);
  assert.strictEqual(s.power, "on");
  assert.strictEqual(s.temperature, 24.5);
});

test("parseStatus survives half a line without throwing", () => {
  // The backend is a child process; a crash mid-write leaves exactly this.
  assert.strictEqual(M.parseStatus('{"power":"on"').ok, false);
  assert.strictEqual(M.parseStatus('{"power":"on"').power, "off");
});

test("parseStatus treats an empty read as not-ok", () => {
  assert.strictEqual(M.parseStatus("").ok, false);
});

test("parseStatus treats an error object as not-ok", () => {
  assert.strictEqual(M.parseStatus('{"error":"no token stored"}').ok, false);
});

test("parseStatus carries offline through", () => {
  assert.strictEqual(M.parseStatus('{"power":"on","temperature":24,"online":false}').online, false);
});

test("barLabel shows the room temperature when on", () => {
  assert.strictEqual(M.barLabel({ok: true, power: "on", temperature: 24}), "24°");
});

test("barLabel rounds rather than truncating", () => {
  assert.strictEqual(M.barLabel({ok: true, power: "on", temperature: 24.6}), "25°");
});

test("barLabel keeps showing the room while the unit is off", () => {
  // Superseded a test that asserted the opposite. The device reports its
  // temperature sensor whether it is cooling or not, so blanking the bar on
  // power state discarded a live reading; on/off is carried by opacity.
  assert.strictEqual(M.barLabel({ok: true, power: "off", temperature: 24}), "24°");
});

test("barLabel is empty when the temperature is unknown", () => {
  assert.strictEqual(M.barLabel({ok: true, power: "on", temperature: null}), "");
});

test("clampSetpoint holds the range", () => {
  assert.strictEqual(M.clampSetpoint(30, 16, 30), 30);
  assert.strictEqual(M.clampSetpoint(31, 16, 30), 30);
  assert.strictEqual(M.clampSetpoint(15, 16, 30), 16);
});

test("nextInterval doubles while the device is off", () => {
  assert.strictEqual(M.nextInterval({ok: true, power: "off"}, 90000, 0), 180000);
  assert.strictEqual(M.nextInterval({ok: true, power: "on"}, 90000, 0), 90000);
});

test("an attended poll keeps its cadence while the unit is off", () => {
  // The doubling spares requests on a bar label nobody is reading. With the
  // panel open the user is clicking, and this hardware moves its own settings
  // -- a mode change drops the preset -- so halving the cadence there is
  // backwards.
  assert.strictEqual(M.nextInterval({ok: true, power: "off"}, 20000, 0, true), 20000);
  assert.strictEqual(M.nextInterval({ok: true, power: "off"}, 90000, 0, false), 180000);
});

test("attention never overrides the rate-limit backoff", () => {
  assert.strictEqual(M.nextInterval({ok: true, power: "off"}, 20000, 2, true), 80000);
});

test("nextInterval backs off exponentially and caps at ten minutes", () => {
  assert.strictEqual(M.nextInterval({ok: false}, 90000, 1), 180000);
  assert.strictEqual(M.nextInterval({ok: false}, 90000, 2), 360000);
  assert.strictEqual(M.nextInterval({ok: false}, 90000, 9), 600000);
});

test("parseStatus rejects arrays", () => {
  assert.strictEqual(M.parseStatus('[1,2,3]').ok, false);
});

test("parseStatus treats absent online as offline", () => {
  assert.strictEqual(M.parseStatus('{"power":"on","temperature":24}').online, false);
});

test("parseStatus treats null online as offline", () => {
  assert.strictEqual(M.parseStatus('{"power":"on","temperature":24,"online":null}').online, false);
});

test("parseStatus respects explicit online:true", () => {
  assert.strictEqual(M.parseStatus('{"power":"on","temperature":24,"online":true}').online, true);
});

test("parseStatus fuzz: never throws on malformed input", () => {
  var fuzzInputs = [
    null,
    undefined,
    123,
    '[1,2,3]',
    '   ',
    '{"power":123}',
    '{"temperature":"24"}',
    'not json',
    '{incomplete',
  ];
  for (var i = 0; i < fuzzInputs.length; i++) {
    var result = M.parseStatus(fuzzInputs[i]);
    assert(typeof result === "object", "fuzz input should return object");
    assert(typeof result.ok === "boolean", "result.ok should be boolean");
  }
});

test("parseStatus carries the new AC fields", () => {
  const s = M.parseStatus(JSON.stringify({
    power:"on", temperature:24.5, setpoint:22, unit:"C", online:true,
    mode:"heat", fan:"low", swing:"fixed", preset:"off", humidity:61,
    supported:{mode:["auto","cool"],fan:["low"],swing:["fixed"],preset:["off","windFree"]},
    setpointMin:16, setpointMax:30
  }));
  assert.strictEqual(s.mode, "heat");
  assert.strictEqual(s.humidity, 61);
  assert.deepStrictEqual(s.supported.preset, ["off","windFree"]);
  assert.strictEqual(s.setpointMin, 16);
});

test("parseStatus defaults the new fields safely when absent", () => {
  // A device without these capabilities must not make the panel render
  // controls it cannot drive.
  const s = M.parseStatus('{"power":"on","online":true}');
  assert.strictEqual(s.mode, null);
  assert.deepStrictEqual(s.supported.mode, []);
  assert.strictEqual(s.setpointMin, null);
});

test("parseStatus rejects a non-array supported list", () => {
  const s = M.parseStatus('{"power":"on","online":true,"supported":{"mode":"cool"}}');
  assert.deepStrictEqual(s.supported.mode, []);
});

test("setpointRange prefers the device's own bounds", () => {
  assert.deepStrictEqual(M.setpointRange({setpointMin:18, setpointMax:28, unit:"C"}), [18,28]);
});

test("setpointRange falls back per unit when the device is silent", () => {
  assert.deepStrictEqual(M.setpointRange({setpointMin:null, setpointMax:null, unit:"C"}), [16,30]);
  assert.deepStrictEqual(M.setpointRange({setpointMin:null, setpointMax:null, unit:"F"}), [61,86]);
});

test("setpointRange ignores an inverted device range", () => {
  // A device reporting max < min would otherwise make every setpoint clamp to
  // the wrong end, which is the Fahrenheit bug in a new costume.
  assert.deepStrictEqual(M.setpointRange({setpointMin:30, setpointMax:16, unit:"C"}), [16,30]);
});

test("heatIndex returns air temperature below the formula's valid range", () => {
  // Rothfusz is only defined at/above ~27C. Below it, humidity barely shifts
  // perception, and pretending otherwise would invent a number.
  assert.strictEqual(M.heatIndex(21, 59), 21);
  assert.strictEqual(M.heatIndex(25, 80), 25);
});

test("heatIndex matches the NWS table where the formula applies", () => {
  // 32C / 70% is 41C on the NWS chart; allow a degree for rounding.
  const hi = M.heatIndex(32, 70);
  assert.ok(hi >= 40 && hi <= 42, "expected ~41, got " + hi);
});

test("heatIndex rises with humidity at fixed temperature", () => {
  assert.ok(M.heatIndex(30, 80) > M.heatIndex(30, 40));
});

test("heatIndex returns null on unusable input", () => {
  assert.strictEqual(M.heatIndex(null, 60), null);
  assert.strictEqual(M.heatIndex(28, null), null);
  assert.strictEqual(M.heatIndex("hot", 60), null);
});

test("feelsLike is null when it would just repeat the air temperature", () => {
  // Showing "21C, feels like 21C" is noise, not information.
  assert.strictEqual(M.feelsLike({temperature: 21, humidity: 59}), null);
  assert.ok(M.feelsLike({temperature: 32, humidity: 70}) !== null);
});

test("barLabel shows the room temperature even when the AC is off", () => {
  // The sensor keeps reporting with the unit off, so blanking the bar threw
  // away information the device was still providing.
  assert.strictEqual(M.barLabel({ok: true, power: "off", temperature: 21}), "21°");
  assert.strictEqual(M.barLabel({ok: true, power: "on", temperature: 24}), "24°");
});

test("barLabel is still empty when there is no reading at all", () => {
  assert.strictEqual(M.barLabel({ok: true, power: "off", temperature: null}), "");
  assert.strictEqual(M.barLabel({ok: false, power: "on", temperature: 24}), "");
});

let failed = 0;
for (const [name, fn] of tests) {
  try { fn(); console.log(`ok    ${name}`); }
  catch (e) { failed++; console.error(`FAIL  ${name}\n      ${e.message}`); }
}

console.log(`\n${tests.length - failed} passed, ${failed} failed`);
process.exit(failed ? 1 : 0);

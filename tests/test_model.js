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

test("barLabel is empty when off", () => {
  assert.strictEqual(M.barLabel({ok: true, power: "off", temperature: 24}), "");
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

test("nextInterval backs off exponentially and caps at ten minutes", () => {
  assert.strictEqual(M.nextInterval({ok: false}, 90000, 1), 180000);
  assert.strictEqual(M.nextInterval({ok: false}, 90000, 2), 360000);
  assert.strictEqual(M.nextInterval({ok: false}, 90000, 9), 600000);
});

let failed = 0;
for (const [name, fn] of tests) {
  try { fn(); console.log(`ok    ${name}`); }
  catch (e) { failed++; console.error(`FAIL  ${name}\n      ${e.message}`); }
}
console.log(`\n${tests.length - failed} passed, ${failed} failed`);
process.exit(failed ? 1 : 0);

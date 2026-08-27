// Parsing and formatting for the SmartThings AC widget.
//
// Qt-free on purpose, so tests/test_model.js runs it under node. Anything that
// needs Qt.locale() belongs in the QML, not here.

var MAX_INTERVAL_MS = 10 * 60 * 1000

// Fahrenheit fallbacks are 16-30C converted and rounded. They are a fallback
// only: a device that publishes its own bounds always wins, because the
// hardcoded pair was right for one unit by luck and wrong in general.
var FALLBACK_RANGE = { C: [16, 30], F: [61, 86] }

function emptyState() {
  return {
    ok: false, power: "off", temperature: null, setpoint: null, unit: "C", online: false,
    mode: null, fan: null, swing: null, preset: null, humidity: null,
    supported: { mode: [], fan: [], swing: [], preset: [] },
    setpointMin: null, setpointMax: null
  }
}

function _num(v) { return (typeof v === "number" && isFinite(v)) ? v : null }
function _str(v) { return (typeof v === "string" && v !== "") ? v : null }
function _list(v) { return Array.isArray(v) ? v.filter(function (x) { return typeof x === "string" }) : [] }

// The bounds the temperature buttons clamp to. Device first, unit-appropriate
// fallback second, and an inverted device range is discarded rather than
// honoured — max < min would clamp every press to the wrong end.
function setpointRange(state) {
  var unit = (state && state.unit === "F") ? "F" : "C"
  var fb = FALLBACK_RANGE[unit]
  var lo = _num(state && state.setpointMin)
  var hi = _num(state && state.setpointMax)
  if (lo === null || hi === null || lo >= hi) return [fb[0], fb[1]]
  return [lo, hi]
}

// The backend is a child process. A crash mid-write leaves half a line on
// stdout, so every read goes through a parse that cannot throw.
function parseStatus(text) {
  var raw = String(text || "").trim()
  if (raw === "") return emptyState()
  try {
    var d = JSON.parse(raw)
    if (!d || typeof d !== "object" || Array.isArray(d) || d.error) return emptyState()
    return {
      ok: true,
      power: d.power === "on" ? "on" : "off",
      temperature: (typeof d.temperature === "number") ? d.temperature : null,
      setpoint: (typeof d.setpoint === "number") ? d.setpoint : null,
      unit: d.unit || "C",
      online: d.online === true,
      mode: _str(d.mode),
      fan: _str(d.fan),
      swing: _str(d.swing),
      preset: _str(d.preset),
      humidity: _num(d.humidity),
      supported: {
        mode:   _list(d.supported && d.supported.mode),
        fan:    _list(d.supported && d.supported.fan),
        swing:  _list(d.supported && d.supported.swing),
        preset: _list(d.supported && d.supported.preset)
      },
      setpointMin: _num(d.setpointMin),
      setpointMax: _num(d.setpointMax)
    }
  } catch (e) {
    return emptyState()
  }
}

// The bar shows the room temperature, and only when there is one. An empty
// string is "nothing to say" — the icon still renders.
// The room temperature, whenever there is one — including while the unit is
// off. The sensor keeps reporting either way, and blanking the bar on power
// state threw away a reading the device was still giving us. Opacity, not
// absence, is what carries on/off in the bar.
function barLabel(state) {
  if (!state || !state.ok) return ""
  if (typeof state.temperature !== "number") return ""
  return Math.round(state.temperature) + "°"
}

// Rothfusz regression, the NWS heat index, worked in Celsius.
//
// It is only defined at or above about 27C: below that, humidity barely moves
// perceived temperature, and the regression starts returning nonsense. Rather
// than extrapolate, this returns the air temperature there — which is what the
// NWS itself does — so a caller can always trust the number it gets back.
var HEAT_INDEX_MIN_C = 27

function heatIndex(tempC, humidity) {
  var t = Number(tempC), h = Number(humidity)
  if (!isFinite(t) || !isFinite(h)) return null
  if (typeof tempC !== "number" || typeof humidity !== "number") return null
  if (h < 0 || h > 100) return null
  if (t < HEAT_INDEX_MIN_C) return Math.round(t * 10) / 10

  var f = t * 9 / 5 + 32
  var hi = -42.379 + 2.04901523 * f + 10.14333127 * h
    - 0.22475541 * f * h - 0.00683783 * f * f - 0.05481717 * h * h
    + 0.00122874 * f * f * h + 0.00085282 * f * h * h - 0.00000199 * f * f * h * h

  // The two corrections the NWS applies at the edges of the table.
  if (h < 13 && f >= 80 && f <= 112) hi -= ((13 - h) / 4) * Math.sqrt((17 - Math.abs(f - 95)) / 17)
  else if (h > 85 && f >= 80 && f <= 87) hi += ((h - 85) / 10) * ((87 - f) / 5)

  return Math.round(((hi - 32) * 5 / 9) * 10) / 10
}

// The number worth showing next to the air temperature — null when it would
// merely repeat it. Below the formula's range the two are equal by definition,
// so this is also what keeps "21C, feels like 21C" off the screen.
function feelsLike(state) {
  if (!state) return null
  var t = state.temperature
  var hi = heatIndex(t, state.humidity)
  if (hi === null || typeof t !== "number") return null
  return (Math.abs(hi - t) >= 1) ? hi : null
}

function clampSetpoint(value, min, max) {
  var v = Number(value)
  if (!isFinite(v)) return min
  return Math.min(max, Math.max(min, v))
}

// A device that is off does not change temperature on its own, so polling it
// as often as a running one spends requests for nothing.
function nextInterval(state, baseMs, consecutiveFailures, attended) {
  var base = Number(baseMs) || 90000
  var fails = Number(consecutiveFailures) || 0
  if (fails > 0) return Math.min(MAX_INTERVAL_MS, base * Math.pow(2, fails))
  // The doubling spares requests on a bar label nobody is reading. Someone
  // watching the open panel is a different case: this hardware moves its own
  // settings -- a mode change drops the preset -- and halving the cadence
  // exactly when the user is clicking is backwards.
  if (!attended && state && state.ok && state.power !== "on") return base * 2
  return base
}

if (typeof module !== "undefined" && module.exports) {
  module.exports = { parseStatus, barLabel, clampSetpoint, nextInterval, emptyState, setpointRange, heatIndex, feelsLike, MAX_INTERVAL_MS }
}

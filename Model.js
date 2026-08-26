// Parsing and formatting for the SmartThings AC widget.
//
// Qt-free on purpose, so tests/test_model.js runs it under node. Anything that
// needs Qt.locale() belongs in the QML, not here.

var MAX_INTERVAL_MS = 10 * 60 * 1000

function emptyState() {
  return { ok: false, power: "off", temperature: null, setpoint: null, unit: "C", online: false }
}

// The backend is a child process. A crash mid-write leaves half a line on
// stdout, so every read goes through a parse that cannot throw.
function parseStatus(text) {
  var raw = String(text || "").trim()
  if (raw === "") return emptyState()
  try {
    var d = JSON.parse(raw)
    if (!d || typeof d !== "object" || d.error) return emptyState()
    return {
      ok: true,
      power: d.power === "on" ? "on" : "off",
      temperature: (typeof d.temperature === "number") ? d.temperature : null,
      setpoint: (typeof d.setpoint === "number") ? d.setpoint : null,
      unit: d.unit || "C",
      online: d.online !== false
    }
  } catch (e) {
    return emptyState()
  }
}

// The bar shows the room temperature, and only when there is one. An empty
// string is "nothing to say" — the icon still renders.
function barLabel(state) {
  if (!state || !state.ok) return ""
  if (state.power !== "on") return ""
  if (typeof state.temperature !== "number") return ""
  return Math.round(state.temperature) + "°"
}

function clampSetpoint(value, min, max) {
  var v = Number(value)
  if (!isFinite(v)) return min
  return Math.min(max, Math.max(min, v))
}

// A device that is off does not change temperature on its own, so polling it
// as often as a running one spends requests for nothing.
function nextInterval(state, baseMs, consecutiveFailures) {
  var base = Number(baseMs) || 90000
  var fails = Number(consecutiveFailures) || 0
  if (fails > 0) return Math.min(MAX_INTERVAL_MS, base * Math.pow(2, fails))
  if (state && state.ok && state.power !== "on") return base * 2
  return base
}

if (typeof module !== "undefined" && module.exports) {
  module.exports = { parseStatus, barLabel, clampSetpoint, nextInterval, emptyState, MAX_INTERVAL_MS }
}

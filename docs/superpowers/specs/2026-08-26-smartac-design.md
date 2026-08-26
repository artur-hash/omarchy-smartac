# SmartThings AC — design

**Date:** 2026-08-26
**Status:** approved, ready for implementation planning

## Purpose

Control an air conditioner from the Omarchy bar through the SmartThings
cloud API, without Home Assistant in between.

The first target device is a Samsung AR12BSEAAWKNAZ (WindFree, 2022). That
model has no local API — a LAN scan of the author's network found no host with
port 2878 or 8888 open, which is the local protocol older Samsung units expose.
Newer WindFree units are cloud-only, so the SmartThings REST API is the only
path that reaches the hardware.

The plugin is named for the API, not the vendor: any AC that SmartThings
exposes works the same way, and a Samsung-only name would turn away every other
user for no technical reason.

## Scope

**In scope (v1):**

- Power on/off
- Read and set target temperature
- Read current room temperature
- Token entry and device selection inside the plugin's own panel

**Out of scope (v1), in rough order of likely demand:**

- HVAC mode (cool / dry / wind / auto / heat)
- Fan speed
- More than one device at a time
- Scheduling
- Local control (impossible on the target hardware; see Purpose)

The structure below accommodates each of these without rework: the backend
already parses the full device status, and the panel is a list of controls.

## Non-goals

- **A daemon.** Push updates would remove polling, but cost a systemd unit,
  reconnection logic and webhook authentication. That is more moving parts than
  on/off and a temperature justify, and every one of them is a part a
  marketplace reviewer has to trust.
- **Storing the token in `shell.json`.** That file is configuration: users
  copy it between machines, paste it into issues, and check it into dotfile
  repos. A credential does not belong there.

## Architecture

```
keyring ──token──> bin/smartac ──HTTPS──> api.smartthings.com
                        │
                    JSON on stdout
                        │
                  BarWidget.qml  (Timer, plus an immediate read when the
                        │         panel opens)
                    Panel.qml
```

A separate backend process rather than `XMLHttpRequest` in QML, for three
reasons:

1. `omarchy-shell` is a long-lived process shared by every widget. A token read
   into QML lives in that process's memory for the whole session; read into a
   short-lived child, it lives for the length of one HTTP call.
2. An unhandled network error in QML degrades the whole bar. In a child
   process it degrades one exit code.
3. The backend is testable without starting a shell.

This also matches the ecosystem: `parm.clock` has `sync/`, `tormarchy` has its
binary, `hass` has a Python runtime.

### Components

| Path | Responsibility |
|---|---|
| `manifest.json` | `schemaVersion: 1`, `kinds: ["bar-widget"]`, id outside the reserved `omarchy.*` namespace |
| `bin/smartac` | All API access. Reads the token, emits JSON, never renders |
| `BarWidget.qml` | Bar entry: icon plus room temperature. Owns the poll timer |
| `Panel.qml` | Setup, device picker, and controls. Owns no network access |
| `Model.js` | Parsing and formatting. Pure, Qt-free, node-testable |
| `tests/` | Model under node; backend against a fake API |
| `README.md`, `LICENSE` | Required for a marketplace listing |

`bash` with `curl` and `jq` rather than Python: it is the smallest dependency
set that does the job, all three are already present on a default Omarchy
install, and it is what `tormarchy` — the best-engineered plugin surveyed —
uses.

**No systemd unit.** The QML owns the timer. This keeps removal to deleting a
directory, which is one of the marketplace's listing requirements.

## Backend interface

```
smartac devices --json     list devices exposing airConditionerMode
smartac status --json      state of the selected device
smartac power on|off
smartac temp <celsius>
smartac token set          read a token from stdin, store it in the keyring
smartac token clear        remove it
smartac doctor             report token, network, and device diagnostics
```

Every command exits non-zero on failure and writes a single JSON object with an
`error` key to stderr, so the QML never parses prose.

### Token handling

Stored in the login keyring via `secret-tool`, under service `smartac`.

`smartac token set` reads the token from **stdin**, never from an argument.
`/proc/<pid>/cmdline` is readable by any process running as the same user, so a
token passed as an argument is exposed to everything on the session for the
lifetime of the call. This is the single most important implementation
constraint in this document.

The token is never written to a config file, never logged, and never included
in `doctor` output beyond a redacted prefix.

## Configuration panel

The panel has three states, in sequence:

1. **No token** — the panel *is* the setup screen: numbered instructions to
   open `account.smartthings.com/tokens`, create a personal access token, and
   grant only the *devices* scopes (list, read, execute), followed by a masked
   field to paste it.
2. **Token, no device selected** — a picker listing devices from
   `smartac devices`, showing each device's label and room. The filter is the
   presence of the `airConditionerMode` capability, which is what distinguishes
   an AC from a thermostat or a heat pump in the SmartThings model.
3. **Configured** — power toggle, target temperature with `−`/`+`, current room
   temperature, and a gear to return to steps 1–2.

The selected device id is not a secret and lives in the widget's `shell.json`
entry, like every other widget setting.

## Polling

The bar polls every 90 seconds; the panel triggers an immediate read when it
opens. When the device is off, the interval doubles — a device that is off does
not change temperature on its own.

On HTTP 429, the interval backs off exponentially to a ceiling of 10 minutes
and resets on the first success. SmartThings enforces rate limits per token and
a widget in a bar runs all day.

## Error handling

| Condition | Behaviour |
|---|---|
| No token stored | Panel opens on the setup screen |
| HTTP 401 | Token cleared from the keyring, panel returns to setup, message says the token was rejected |
| HTTP 429 | Exponential backoff; last known state kept and marked stale |
| Network unreachable | Last known state kept and marked stale; controls disabled |
| Device offline | Icon unlit, controls disabled, panel says the device is unreachable |
| `jq` or `curl` missing | `doctor` names the missing command; panel shows it |

"Stale" is a visible state, not a silent one: a widget that shows a
plausible-but-old temperature is worse than one that admits it does not know.

## Testing

- **`Model.js`** — unit tests under node, as `parm.clock` does. Pure functions:
  parsing a device status payload, formatting the bar label, clamping a
  temperature to the device's advertised range.
- **`bin/smartac`** — tested against a fake `curl` on `PATH` that records each
  invocation and replies with fixtures, mirroring the fake-`gws` approach in
  `parm.clock`'s `test_mutate.py`. This covers argument construction, the
  stdin-only token path, and each error branch, with no network and no real
  token.
- **Manifest** — `omarchy plugin validate` in CI.

## Marketplace readiness

The listing requirements are: a public GitHub repository, a valid
`manifest.json` at the root, a README and a license, safe install and removal,
and passing automated validation of the submitted commit.

The validator additionally requires `schemaVersion` 1, a non-empty `kinds`
array, an `entryPoints` object whose paths are relative and exist, an id
outside `omarchy.*`, and no symlinks anywhere in the plugin folder.

Submission is through the marketplace's issue form and is a separate, later
decision — building to the bar does not commit to publishing.

## Open question

Which capabilities the target device actually exposes is unknown until a token
exists. `smartac doctor` prints the raw capability list, and that is the first
thing to run once the plugin can authenticate. If the device turns out not to
expose `thermostatCoolingSetpoint`, the temperature half of v1 needs rethinking
— power would still work.

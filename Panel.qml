import QtQuick
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Three states in sequence: no token, no device, configured. Owns no network
// access of its own — every call leaves through bin/smartac.
//
// Ui/Panel is pure open-state/IPC plumbing and paints nothing itself — every
// first-party panel in this shell (dropbox, tailscale, audio, network, ...)
// builds its own floating popup inline, anchored to the bar icon. This file
// is loaded by BarWidget.qml's Loader as a plain, unanchored child, so
// without a PopupCard of its own here nothing would ever appear on screen:
// content would render (if at all) clipped to the ~26px bar strip rather
// than as a floating card near the icon. `host` (BarWidget.qml's root Item,
// injected by the Loader) stands in for the "button" every other panel
// anchors to.
Panel {
  id: panel

  moduleName: "arturhash.smartac"
  ipcTarget: "arturhash.smartac"   // enables `omarchy-shell arturhash.smartac toggle`

  property QtObject host: null
  property Item anchorButton: null   // the visible bar button, set by BarWidget
  property color foreground: Color.foreground     // bound by the Loader in BarWidget.qml
  property string fontFamily: Style.font.family   // bound by the Loader in BarWidget.qml
  property bool hasToken: false
  property var devices: []
  property string busy: ""
  property string actionError: ""

  // Bounds and the printed unit letter follow the device's own report
  // (state.unit) rather than assuming Celsius. Fahrenheit bounds are the
  // Celsius range (16–30, the WindFree's advertised span) converted and
  // rounded to whole degrees: 16°C≈61°F, 30°C=86°F.
  readonly property string setpointUnit: (panel.host && panel.host.state && panel.host.state.unit) ? panel.host.state.unit : "C"
  readonly property bool isFahrenheit: setpointUnit === "F"
  readonly property int minSetpoint: isFahrenheit ? 61 : 16
  readonly property int maxSetpoint: isFahrenheit ? 86 : 30
  readonly property string bin: host ? host.pluginDir + "bin/smartac" : ""

  function refreshAll() {
    if (panel.bin === "") return
    tokenCheck.running = true
    if (host) host.refresh()
  }

  function run(args) {
    panel.actionError = ""
    action.command = [panel.bin].concat(args)
    action.running = true
  }

  function setTemp(value) {
    var v = Model.clampSetpoint(value, panel.minSetpoint, panel.maxSetpoint)
    panel.busy = "temp"
    panel.run(["temp", String(v), "--device", panel.host.deviceId])
  }

  // The shell, not this panel, owns settings: Bar.qml re-assigns host.settings
  // from shell.json on every layout apply (BarModel.applySettingsDelta), so a
  // plain local assignment here is overwritten and the pick never survives a
  // restart. shell.updateEntryInline is the only durable write path — same
  // pattern as parm.clock's cycleFormat and tripleu.tor's persistRecentExit.
  // Applied to host.settings locally too, so the picker's own screen updates
  // on the click itself rather than waiting on the round trip back down.
  function chooseDevice(id) {
    if (!panel.host) return
    var entry = { id: panel.host.moduleName }
    for (var key in panel.host.settings) if (key !== "id") entry[key] = panel.host.settings[key]
    entry.deviceId = id
    panel.host.settings = entry
    if (panel.host.bar && panel.host.bar.shell && typeof panel.host.bar.shell.updateEntryInline === "function")
      panel.host.bar.shell.updateEntryInline(panel.host.moduleName, entry)
    panel.refreshAll()
  }

  Process {
    id: tokenCheck
    command: [panel.bin, "token", "status", "--json"]
    stdout: StdioCollector { id: tokenOut; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode !== 0) { panel.hasToken = false; return }
      try { panel.hasToken = JSON.parse(String(tokenOut.text)).hasToken === true }
      catch (e) { panel.hasToken = false }
      if (panel.hasToken) deviceList.running = true
    }
  }

  Process {
    id: deviceList
    command: [panel.bin, "devices", "--json"]
    stdout: StdioCollector { id: devOut; waitForEnd: true }
    onExited: function(exitCode) {
      panel.devices = []
      // Exit 3 means the backend got a 401 and has already deleted the token
      // from the keyring. Without re-reading it here the panel kept hasToken
      // true against a credential that no longer exists, showed an empty
      // picker instead of the setup screen, and left no way to enter a new
      // token short of restarting the shell.
      if (exitCode === 3) { panel.hasToken = false; panel.actionError = "The token was rejected. Enter a new one."; return }
      if (exitCode !== 0) return
      try { panel.devices = JSON.parse(String(devOut.text)).devices || [] }
      catch (e) { panel.devices = [] }
    }
  }

  Process {
    id: action
    stderr: StdioCollector { id: actionErr; waitForEnd: true }
    onExited: function(exitCode) {
      panel.busy = ""
      if (exitCode !== 0) {
        var msg = ""
        try { msg = JSON.parse(String(actionErr.text || "")).error || "" } catch (e) {}
        panel.actionError = msg !== "" ? msg : "Command failed."
      }
      panel.refreshAll()
    }
  }

  // The token goes in on stdin. As an argument it would land in
  // /proc/<pid>/cmdline, readable by every process on this session — the same
  // reason the shell's own network panel pipes 802.1X secrets this way.
  Process {
    id: tokenSet
    stderr: StdioCollector { id: tokenSetErr; waitForEnd: true }
    property string pending: ""
    command: [panel.bin, "token", "set"]
    stdinEnabled: true
    onStarted: {
      write(tokenSet.pending)
      tokenSet.pending = ""
      // Closing stdin is required — the backend's `secret-tool store` reads
      // until EOF and would otherwise hang. But this is an imperative write
      // over a declared property, so it does not reset itself: saveToken has
      // to turn it back on before every run, or the second token of the
      // session reaches the backend with empty stdin and is rejected as
      // "token is empty". That is the bug where a correct token pasted after
      // a rejected one only worked again after a shell restart, because the
      // restart rebuilt the Process with its declared value.
      stdinEnabled = false
    }
    onExited: function(exitCode) {
      // The only screen where the user types something and needs to be told
      // it was refused. The backend rejects empty, whitespace-only and
      // control-character tokens; without this those all looked like nothing
      // happening at all.
      if (exitCode !== 0) {
        var msg = "Could not save the token."
        try { msg = JSON.parse(String(tokenSetErr.text)).error || msg } catch (e) {}
        panel.actionError = msg
        return
      }
      panel.actionError = ""
      panel.refreshAll()
    }
  }

  function saveToken(value) {
    // secret-tool strips only one trailing newline, and the backend now
    // rejects anything else it does not recognize as a plain token — a
    // clipboard paste routinely carries a trailing newline or pasted
    // whitespace, so trim it here rather than bounce the user to the
    // backend's refusal for something this harmless.
    var trimmed = String(value || "").trim()
    if (trimmed === "") return
    tokenSet.pending = trimmed
    tokenSet.stdinEnabled = true   // see onStarted: this does not reset itself
    tokenSet.running = true
    tokenField.text = ""
  }

  // KeyboardPanel, not PopupCard. PopupCard is a bare PopupWindow with no
  // keyboard-focus handling at all, so the token TextField inside it could
  // never take input — clicking it did nothing. KeyboardPanel is what every
  // first-party panel with an input uses (see the wifi passphrase field in
  // plugins/panels/network); it owns focus priming, anchored-to-icon
  // positioning, outside-click dismissal and the fade.
  KeyboardPanel {
    id: popup
    anchorItem: panel.anchorButton
    owner: panel
    bar: panel.bar
    open: panel.opened
    // Focus goes to the token field while there is no token, because that is
    // the only thing the user can do on that screen. Once configured, the key
    // catcher owns it for arrow-key navigation.
    focusTarget: panel.hasToken ? keyCatcher : tokenField
    contentWidth: popup.fittedContentWidth(Style.space(320))
    contentHeight: popup.fittedContentHeight(column.implicitHeight, Style.space(440))

    // AfterItem so the TextField in the focus chain gets its keys first; only
    // what the focused subtree ignores bubbles back here.
    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      Keys.priority: Keys.AfterItem
      blocked: !panel.hasToken
    }

    Flickable {
      anchors.fill: parent
      contentWidth: width
      contentHeight: column.implicitHeight
      clip: true
      boundsBehavior: Flickable.StopAtBounds
      flickableDirection: Flickable.VerticalFlick
      interactive: contentHeight > height

      Column {
        id: column
        width: parent.width
        spacing: Style.space(12)

        // Backend errors live above the three state blocks, not inside the
        // controls: the screen that most needs one is the setup screen, where
        // a rejected token used to look exactly like nothing happening.
        Text {
          visible: panel.actionError !== ""
          width: parent.width
          wrapMode: Text.WordWrap
          text: panel.actionError
          textFormat: Text.PlainText
          color: Color.urgent
          font.family: panel.fontFamily
          font.pixelSize: Style.font.caption
        }

        // ---- State 1: setup
        Column {
          visible: !panel.hasToken
          width: parent.width
          spacing: Style.space(8)

          PanelSectionHeader {
            width: parent.width
            text: "CONNECT SMARTTHINGS"
            foreground: panel.foreground
            fontFamily: panel.fontFamily
          }

          Text {
            width: parent.width
            wrapMode: Text.WordWrap
            textFormat: Text.PlainText
            color: Qt.darker(panel.foreground, 1.3)
            font.family: panel.fontFamily
            font.pixelSize: Style.font.bodySmall
            text: "1.  Open account.smartthings.com/tokens\n" +
                  "2.  Generate a new personal access token\n" +
                  "3.  Grant only the Devices scopes: list, read, execute\n" +
                  "4.  Paste it below. It is stored in your login keyring, never in a config file."
          }

          TextField {
            id: tokenField
            width: parent.width
            password: true
            placeholderText: "Personal access token"
            foreground: panel.foreground
            font.family: panel.fontFamily
            onAccepted: panel.saveToken(text)
          }

          Button {
            text: "Save"
            foreground: panel.foreground
            fontFamily: panel.fontFamily
            onClicked: panel.saveToken(tokenField.text)
          }
        }

        // ---- State 2: pick a device
        Column {
          visible: panel.hasToken && panel.host && panel.host.deviceId === ""
          width: parent.width
          spacing: Style.space(6)

          PanelSectionHeader {
            width: parent.width
            text: "PICK YOUR AIR CONDITIONER"
            foreground: panel.foreground
            fontFamily: panel.fontFamily
          }

          Text {
            visible: panel.devices.length === 0
            width: parent.width
            text: "No air conditioner found on this account."
            textFormat: Text.PlainText
            color: Qt.darker(panel.foreground, 1.5)
            font.family: panel.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          Repeater {
            model: panel.devices
            Button {
              required property var modelData
              width: parent.width
              text: modelData.label
              foreground: panel.foreground
              fontFamily: panel.fontFamily
              onClicked: panel.chooseDevice(modelData.id)
            }
          }
        }

        // ---- State 3: controls
        Column {
          visible: panel.hasToken && panel.host && panel.host.deviceId !== ""
          width: parent.width
          spacing: Style.space(10)

          Text {
            visible: panel.host && panel.host.stale
            width: parent.width
            wrapMode: Text.WordWrap
            text: "Showing the last known state — SmartThings is not answering."
            textFormat: Text.PlainText
            color: Color.urgent
            font.family: panel.fontFamily
            font.pixelSize: Style.font.caption
          }

          Text {
            visible: panel.host && panel.host.state.ok && !panel.host.state.online
            width: parent.width
            wrapMode: Text.WordWrap
            text: "This device is offline."
            textFormat: Text.PlainText
            color: Color.urgent
            font.family: panel.fontFamily
            font.pixelSize: Style.font.caption
          }


          Row {
            width: parent.width
            spacing: Style.space(10)
            Text {
              anchors.verticalCenter: parent.verticalCenter
              width: Style.space(80); text: "POWER"
              color: Qt.darker(panel.foreground, 1.6)
              font.family: panel.fontFamily; font.pixelSize: Style.font.caption; font.letterSpacing: 1
            }
            ToggleSwitch {
              anchors.verticalCenter: parent.verticalCenter
              // Network unreachable also disables controls (spec's error
              // table): BarWidget.qml deliberately keeps the last-good state
              // on a failed poll, so state.ok/online alone would still read
              // true. host.stale is what actually says the connection is
              // down.
              enabled: panel.busy === "" && !panel.host.stale && panel.host.state.ok && panel.host.state.online
              checked: panel.host.state.power === "on"
              foreground: panel.foreground
              // `checked` here still reflects the state *before* this click —
              // ToggleSwitch only emits toggled(), it never flips its own
              // `checked` (that is a binding to host.state, owned by the
              // widget's poller). Sending it back as the desired state would
              // just ask the backend to set what it already is; the actual
              // request is always the opposite of the current power state.
              onToggled: {
                panel.busy = "power"
                panel.run(["power", panel.host.state.power === "on" ? "off" : "on", "--device", panel.host.deviceId])
              }
            }
          }

          Row {
            width: parent.width
            spacing: Style.space(10)
            Text {
              anchors.verticalCenter: parent.verticalCenter
              width: Style.space(80); text: "TARGET"
              color: Qt.darker(panel.foreground, 1.6)
              font.family: panel.fontFamily; font.pixelSize: Style.font.caption; font.letterSpacing: 1
            }
            PanelActionButton {
              iconText: "-"; tooltipText: "Cooler"
              foreground: panel.foreground; fontFamily: panel.fontFamily
              enabled: panel.busy === "" && !panel.host.stale && panel.host.state.setpoint !== null && panel.host.state.online
              onClicked: panel.setTemp(panel.host.state.setpoint - 1)
            }
            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: panel.host.state.setpoint === null ? "—" : (panel.host.state.setpoint + "°" + panel.setpointUnit)
              color: panel.foreground
              font.family: panel.fontFamily; font.pixelSize: Style.font.body; font.bold: true
            }
            PanelActionButton {
              iconText: "+"; tooltipText: "Warmer"
              foreground: panel.foreground; fontFamily: panel.fontFamily
              enabled: panel.busy === "" && !panel.host.stale && panel.host.state.setpoint !== null && panel.host.state.online
              onClicked: panel.setTemp(panel.host.state.setpoint + 1)
            }
          }

          Row {
            width: parent.width
            spacing: Style.space(10)
            Text {
              anchors.verticalCenter: parent.verticalCenter
              width: Style.space(80); text: "ROOM"
              color: Qt.darker(panel.foreground, 1.6)
              font.family: panel.fontFamily; font.pixelSize: Style.font.caption; font.letterSpacing: 1
            }
            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: panel.host.state.temperature === null ? "—" : (panel.host.state.temperature + "°" + panel.setpointUnit)
              color: panel.foreground
              font.family: panel.fontFamily; font.pixelSize: Style.font.bodySmall
            }
          }

          Button {
            text: "Change device"
            foreground: panel.foreground
            fontFamily: panel.fontFamily
            onClicked: panel.chooseDevice("")
          }
        }
      }
    }
  }
}

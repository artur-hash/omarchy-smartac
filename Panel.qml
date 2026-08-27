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
  // The device's own bounds when it publishes them; the unit-appropriate
  // fallback only when it stays silent. The previous pair was a constant that
  // happened to match this unit and would have been wrong on another.
  readonly property var spRange: Model.setpointRange(panel.host ? panel.host.state : null)
  readonly property int minSetpoint: panel.spRange[0]
  readonly property int maxSetpoint: panel.spRange[1]

  property bool showMore: false

  // What the last write asked for, held until a later read either confirms it
  // or shows the device dropped it. This hardware silently ignores a command
  // that does not apply to its current state -- WindFree outside cool mode, a
  // setpoint while the unit is off -- and answers COMPLETED all the same, so
  // the only honest confirmation is reading the state back.
  property var pending: null        // { kind, value, label }
  property int verifyAttempts: 0

  // Gaps between confirmation reads, so the checks land at roughly 3, 5, 7 and
  // 11 seconds after the write. Measured on the hardware: a preset and a mode
  // change were both absent from the cloud at 1.4s and present by 3.0-3.2s, so
  // the first check usually settles it and the rest exist for a slow day. The
  // old single check at 8s was three times longer than anything needed.
  readonly property var verifyDelays: [3000, 1800, 2500, 4000]

  // A control the last write asked for but nothing has confirmed yet. It is
  // drawn selected so the click registers, and dimmed so the panel never claims
  // a state it has not read back -- the difference between "asked" and "done".
  function isPending(kind, value) {
    return panel.pending !== null && panel.pending.kind === kind
      && panel.pending.value === String(value)
  }

  // null whenever it would merely repeat the air temperature, which is every
  // reading below the heat index's valid range. See Model.feelsLike.
  readonly property var feels: Model.feelsLike(panel.host ? panel.host.state : null)

  readonly property var shownSetpoint: (panel.pending && panel.pending.kind === "temp")
    ? parseInt(panel.pending.value)
    : (panel.host ? panel.host.state.setpoint : null)
  readonly property string bin: host ? host.pluginDir + "bin/smartac" : ""

  // Refresh belongs here, not in the bar widget's togglePanel: the panel can
  // also be opened through Ui/Panel's own IpcHandler, which never touches the
  // widget. Hanging it off the widget meant an IPC-opened panel showed its
  // initial state — a stored token rendered as the setup screen.
  onOpenedChanged: if (panel.opened) { panel.pending = null; panel.refreshAll() }

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

  // mode / fan / swing / preset all take the same shape: one value, validated
  // by the backend against what the device published.
  function setEnum(kind, value) {
    if (!panel.host || panel.host.deviceId === "") return
    panel.busy = kind
    panel.pending = { kind: kind, value: String(value), label: kind }
    // --no-validate: these buttons are built from the device's own supported
    // list, so the backend's validating GET would re-fetch what is already on
    // screen. Requests are the scarce resource here, not correctness.
    panel.run([kind, value, "--device", panel.host.deviceId, "--no-validate"])
  }

  function setTemp(value) {
    var v = Model.clampSetpoint(value, panel.minSetpoint, panel.maxSetpoint)
    panel.busy = "temp"
    panel.pending = { kind: "temp", value: String(v), label: "temperature" }
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
        panel.pending = null
        panel.refreshAll()
        return
      }
      // The cloud accepting a command is not the device applying it, and the
      // reported state lags the write. Reading now returns the old value and
      // looks like a failure, so the read waits.
      panel.verifyAttempts = 0
      verifyTimer.interval = panel.verifyDelays[0]
      verifyTimer.restart()
    }
  }

  // Verification reads through its own process rather than host.refresh(),
  // which begins `if (reader.running) return` -- a poll already in flight made
  // the verification a silent no-op, and because nothing then changed state,
  // the pending write was never settled: the button kept showing the requested
  // value forever and the failure message never came.
  Process {
    id: verifier
    stdout: StdioCollector { id: verifyOut; waitForEnd: true }
    onExited: function(exitCode) {
      var st = Model.parseStatus(verifyOut.text)
      if (st.ok && panel.host) {
        // A quick read skips the reachability call, so it has nothing to say
        // about it. Carrying the last known value forward beats letting the
        // parser's default turn every confirmation into "device offline".
        st.online = panel.host.state.online
        // The panel paid for this read; the bar should not pay for it again.
        panel.host.state = st
      }
      panel.settlePending(st)
    }
  }

  // One read, a beat after the write. Measured against the hardware: a mode
  // change surfaced four to six seconds after the command returned and a preset
  // took eight, so a single read at six seconds would have called a working
  // preset broken. Two reads cost an extra pair of requests only when something
  // really did not apply.
  Timer {
    id: verifyTimer
    interval: 8000
    repeat: false
    onTriggered: {
      if (!panel.host || panel.host.deviceId === "") return
      // Come back rather than give up: dropping this tick would strand the
      // pending write with nothing left to settle it.
      if (verifier.running) { verifyTimer.interval = 1000; verifyTimer.restart(); return }
      if (panel.pending) panel.verifyAttempts = panel.verifyAttempts + 1
      verifier.command = [panel.bin, "status", "--json", "--quick", "--device", panel.host.deviceId]
      verifier.running = true
    }
  }

  function settlePending(st) {
    if (!panel.pending) return
    var want = panel.pending
    // A read that failed -- rate limited, network down -- says nothing about
    // whether the write landed. Try again if there are tries left rather than
    // quietly dropping the request on the floor.
    if (!st || !st.ok) {
      if (panel.verifyAttempts < panel.verifyDelays.length) {
        verifyTimer.interval = panel.verifyDelays[panel.verifyAttempts]
        verifyTimer.restart()
      } else {
        panel.pending = null
      }
      return
    }

    var got = want.kind === "temp" ? String(st.setpoint) : String(st[want.kind] || "")
    if (got === want.value) {
      panel.pending = null
      // One more read shortly after. Settings cascade on this hardware -- a mode
      // change drops the preset and each mode carries its own setpoint -- and
      // the confirming read is often too early to have seen the rest move.
      verifyTimer.interval = 4000
      verifyTimer.restart()
      return
    }

    // Escalating gaps rather than one long wait, so a slow answer costs time
    // only when it is actually slow.
    if (panel.verifyAttempts < panel.verifyDelays.length) {
      verifyTimer.interval = panel.verifyDelays[panel.verifyAttempts]
      verifyTimer.restart()
      return
    }

    panel.pending = null
    panel.actionError = "The device did not apply " + want.label + " " + want.value
      + ". It is still " + (got === "" || got === "null" ? "unchanged" : got)
      + " — this unit ignores settings that do not apply to its current state."
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

        // The application's name, the way every other panel on this bar
        // identifies itself. Not the device's — that changes with the picker,
        // and a title that moves is not a title.
        Item {
          width: parent.width
          height: Math.max(titleText.implicitHeight, powerBox.height)

          Text {
            id: titleText
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            text: "SmartThings AC"
            color: panel.foreground
            font.family: panel.fontFamily
            font.pixelSize: Style.font.body
            font.bold: true
          }

          // Filled when running, outlined when not. A switch reads as a
          // setting; this reads as the state of the machine in the room.
          Rectangle {
            id: powerBox
            visible: panel.hasToken && panel.host && panel.host.deviceId !== ""
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            width: Style.space(30); height: Style.space(30)
            radius: Style.cornerRadius
            readonly property bool waiting: panel.pending !== null && panel.pending.kind === "power"
            readonly property bool on: powerBox.waiting
              ? panel.pending.value === "on"
              : (panel.host && panel.host.state.power === "on")
            readonly property bool usable: panel.busy === "" && panel.host
              && panel.host.state.ok && panel.host.state.online
            color: on ? Style.selectedFillFor(panel.foreground, Color.accent) : "transparent"
            border.width: Style.spacing.hairline
            border.color: on ? Style.selectedBorderFor(panel.foreground, Color.accent)
                             : Qt.rgba(panel.foreground.r, panel.foreground.g, panel.foreground.b, 0.35)
            opacity: !usable ? 0.45 : (powerBox.waiting ? 0.5 : 1.0)

            Text {
              anchors.centerIn: parent
              text: "⏻"
              color: powerBox.on ? Style.selectedStateColor(panel.foreground, Color.accent)
                                 : Qt.darker(panel.foreground, 1.3)
              font.family: panel.fontFamily
              font.pixelSize: Style.font.bodySmall
            }

            MouseArea {
              anchors.fill: parent
              enabled: powerBox.usable
              cursorShape: Qt.PointingHandCursor
              onClicked: {
                var want = powerBox.on ? "off" : "on"
                panel.busy = "power"
                panel.pending = { kind: "power", value: want, label: "power" }
                panel.run(["power", want, "--device", panel.host.deviceId])
              }
            }
          }
        }

        PanelSeparator { width: parent.width; foreground: panel.foreground }

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

          // Each function gets its own bordered card. Before this everything sat in
          // one flat column and read as a single undifferentiated list.
          component Card: Rectangle {
            default property alias body: cardCol.children
            required property string heading
            width: parent.width
            height: cardCol.implicitHeight + Style.space(20)
            radius: Style.cornerRadius + 3
            color: Qt.rgba(panel.foreground.r, panel.foreground.g, panel.foreground.b, 0.04)
            border.width: Style.spacing.hairline
            border.color: Qt.rgba(panel.foreground.r, panel.foreground.g, panel.foreground.b, 0.13)

            Column {
              id: cardCol
              x: Style.space(10); y: Style.space(10)
              width: parent.width - Style.space(20)
              spacing: Style.space(6)

              Text {
                text: heading
                color: Qt.darker(panel.foreground, 1.6)
                font.family: panel.fontFamily
                font.pixelSize: Style.font.caption
                font.letterSpacing: 1
              }
            }
          }

          // A row of choices built from the list the device published. A capability
          // the device lacks publishes an empty list and the card disappears rather
          // than offering buttons the backend would refuse.
          component ChoiceFlow: Flow {
            required property string kind
            required property string current
            required property var options
            width: parent.width
            spacing: Style.space(4)
            Repeater {
              model: options
              Button {
                required property var modelData
                text: modelData
                foreground: panel.foreground
                fontFamily: panel.fontFamily
                selected: modelData === current || panel.isPending(kind, modelData)
                // Half strength until a read confirms it. The old build painted
                // a requested value exactly like a confirmed one, so a command
                // the device dropped looked like one it had honoured.
                opacity: panel.isPending(kind, modelData) ? 0.5 : 1.0
                enabled: panel.busy === "" && panel.host.state.online
                onClicked: panel.setEnum(kind, modelData)
              }
            }
          }

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

          // ---- Room: never hidden behind More. These readings are live whether or
          //      not the unit is running, and are the reason to glance at the panel.
          Card {
            heading: "ROOM"
            Row {
              width: parent.width
              spacing: Style.space(16)
              Text {
                text: panel.host.state.temperature === null
                  ? "—" : (panel.host.state.temperature + "°" + panel.host.state.unit)
                color: panel.foreground
                font.family: panel.fontFamily; font.pixelSize: Style.font.body; font.bold: true
              }
              Text {
                visible: panel.host.state.humidity !== null
                anchors.verticalCenter: parent.verticalCenter
                text: panel.host.state.humidity + "%"
                color: Qt.darker(panel.foreground, 1.35)
                font.family: panel.fontFamily; font.pixelSize: Style.font.bodySmall
              }
              Text {
                // Only when it actually differs from the air temperature — see
                // Model.feelsLike. Below ~27C the heat index equals it by definition.
                visible: panel.feels !== null
                anchors.verticalCenter: parent.verticalCenter
                text: "feels " + panel.feels + "°"
                color: Qt.darker(panel.foreground, 1.35)
                font.family: panel.fontFamily; font.pixelSize: Style.font.bodySmall
              }
            }
          }

          Card {
            heading: "TEMPERATURE"
            Row {
              anchors.horizontalCenter: parent.horizontalCenter
              spacing: Style.space(12)
              PanelActionButton {
                iconText: "-"; tooltipText: "Cooler"
                foreground: panel.foreground; fontFamily: panel.fontFamily
                enabled: panel.busy === "" && panel.shownSetpoint !== null && panel.host.state.online
                onClicked: panel.setTemp(panel.shownSetpoint - 1)
              }
              Text {
                anchors.verticalCenter: parent.verticalCenter
                text: panel.shownSetpoint === null
                  ? "—" : (panel.shownSetpoint + "°" + panel.host.state.unit)
                opacity: (panel.pending && panel.pending.kind === "temp") ? 0.5 : 1.0
                color: panel.foreground
                font.family: panel.fontFamily; font.pixelSize: Style.font.body; font.bold: true
              }
              PanelActionButton {
                iconText: "+"; tooltipText: "Warmer"
                foreground: panel.foreground; fontFamily: panel.fontFamily
                enabled: panel.busy === "" && panel.shownSetpoint !== null && panel.host.state.online
                onClicked: panel.setTemp(panel.shownSetpoint + 1)
              }
            }
          }

          Card {
            heading: "MODE"
            visible: panel.host.state.supported.mode.length > 0
            ChoiceFlow {
              kind: "mode"
              current: panel.host.state.mode || ""
              options: panel.host.state.supported.mode
            }
          }

          Card {
            heading: "FAN"
            visible: panel.host.state.supported.fan.length > 0
            ChoiceFlow {
              kind: "fan"
              current: panel.host.state.fan || ""
              options: panel.host.state.supported.fan
            }
          }

          // Its own centred row between the essentials and the rest, rather than one
          // more button in the stack where it read as just another control.
          Item {
            width: parent.width
            height: moreButton.implicitHeight + Style.space(4)
            Button {
              id: moreButton
              anchors.horizontalCenter: parent.horizontalCenter
              text: panel.showMore ? "Less  ▴" : "More  ▾"
              foreground: panel.foreground
              fontFamily: panel.fontFamily
              onClicked: panel.showMore = !panel.showMore
            }
          }

          Card {
            heading: "SWING"
            visible: panel.showMore && panel.host.state.supported.swing.length > 0
            ChoiceFlow {
              kind: "swing"
              current: panel.host.state.swing || ""
              options: panel.host.state.supported.swing
            }
          }

          Card {
            heading: "PRESET"
            visible: panel.showMore && panel.host.state.supported.preset.length > 0
            ChoiceFlow {
              kind: "preset"
              current: panel.host.state.preset || ""
              options: panel.host.state.supported.preset
            }
          }

          Button {
            visible: panel.showMore
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

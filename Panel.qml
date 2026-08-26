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

  property QtObject host: null
  property color foreground: Color.foreground     // bound by the Loader in BarWidget.qml
  property string fontFamily: Style.font.family   // bound by the Loader in BarWidget.qml
  property bool hasToken: false
  property var devices: []
  property string busy: ""

  readonly property int minSetpoint: 16
  readonly property int maxSetpoint: 30
  readonly property string bin: host ? host.pluginDir + "bin/smartac" : ""

  function refreshAll() {
    if (panel.bin === "") return
    tokenCheck.running = true
    if (host) host.refresh()
  }

  function run(args) {
    action.command = [panel.bin].concat(args)
    action.running = true
  }

  function setTemp(value) {
    var v = Model.clampSetpoint(value, panel.minSetpoint, panel.maxSetpoint)
    panel.busy = "temp"
    panel.run(["temp", String(v), "--device", panel.host.deviceId])
  }

  function chooseDevice(id) {
    panel.host.settings = Object.assign({}, panel.host.settings, { deviceId: id })
    panel.refreshAll()
  }

  Process {
    id: tokenCheck
    command: [panel.bin, "token", "status", "--json"]
    stdout: StdioCollector { id: tokenOut; waitForEnd: true }
    onExited: {
      try { panel.hasToken = JSON.parse(String(tokenOut.text)).hasToken === true }
      catch (e) { panel.hasToken = false }
      if (panel.hasToken) deviceList.running = true
    }
  }

  Process {
    id: deviceList
    command: [panel.bin, "devices", "--json"]
    stdout: StdioCollector { id: devOut; waitForEnd: true }
    onExited: {
      try { panel.devices = JSON.parse(String(devOut.text)).devices || [] }
      catch (e) { panel.devices = [] }
    }
  }

  Process {
    id: action
    onExited: { panel.busy = ""; panel.refreshAll() }
  }

  // The token goes in on stdin. As an argument it would land in
  // /proc/<pid>/cmdline, readable by every process on this session — the same
  // reason the shell's own network panel pipes 802.1X secrets this way.
  Process {
    id: tokenSet
    property string pending: ""
    command: [panel.bin, "token", "set"]
    stdinEnabled: true
    onStarted: {
      write(tokenSet.pending)
      tokenSet.pending = ""
      stdinEnabled = false
    }
    onExited: panel.refreshAll()
  }

  function saveToken(value) {
    if (!value || value.length === 0) return
    tokenSet.pending = value
    tokenSet.running = true
    tokenField.text = ""
  }

  PopupCard {
    id: popup
    anchorItem: panel.host
    owner: panel
    bar: panel.bar
    open: panel.opened
    contentWidth: popup.fittedContentWidth(Style.space(320))
    contentHeight: popup.fittedContentHeight(column.implicitHeight, Style.space(440))

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
              enabled: panel.busy === "" && panel.host.state.ok && panel.host.state.online
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
              enabled: panel.busy === "" && panel.host.state.setpoint !== null && panel.host.state.online
              onClicked: panel.setTemp(panel.host.state.setpoint - 1)
            }
            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: panel.host.state.setpoint === null ? "—" : (panel.host.state.setpoint + "°")
              color: panel.foreground
              font.family: panel.fontFamily; font.pixelSize: Style.font.body; font.bold: true
            }
            PanelActionButton {
              iconText: "+"; tooltipText: "Warmer"
              foreground: panel.foreground; fontFamily: panel.fontFamily
              enabled: panel.busy === "" && panel.host.state.setpoint !== null && panel.host.state.online
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
              text: panel.host.state.temperature === null ? "—" : (panel.host.state.temperature + "°")
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

import QtQuick
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Bar entry: an icon, plus the room temperature while the AC is running.
//
// Owns the poll timer, the backoff, and opening the panel — the panel's own
// `opened` is readonly, and the panel is torn down as it closes, so neither
// the timer nor the failure count could live there.
Item {
  id: root

  property QtObject bar: null
  property string moduleName: ""
  property var settings: ({})
  readonly property string deviceId: String(settings.deviceId || "")
  readonly property string pluginDir: Qt.resolvedUrl(".").toString().replace("file://", "")

  // Ui/Panel supplies neither of these; every plugin derives them from the bar.
  readonly property color contentForeground: bar ? bar.foreground : Color.foreground
  readonly property string contentFontFamily: bar ? bar.fontFamily : Style.font.family

  property var state: Model.emptyState()
  property int consecutiveFailures: 0
  readonly property string label: Model.barLabel(root.state)
  readonly property bool stale: root.consecutiveFailures > 0

  function open()  { if (panelLoader.item) panelLoader.item.controller.open = true }
  function close() { if (panelLoader.item) panelLoader.item.controller.open = false }
  function togglePanel() {
    if (!panelLoader.item) return
    var willOpen = !panelLoader.item.controller.open
    panelLoader.item.controller.open = willOpen
    if (willOpen) panelLoader.item.refreshAll()
  }

  function refresh() {
    if (root.deviceId === "") { root.state = Model.emptyState(); return }
    if (reader.running) return
    reader.command = [root.pluginDir + "bin/smartac", "status", "--json", "--device", root.deviceId]
    reader.running = true
  }

  Process {
    id: reader
    stdout: StdioCollector { id: readOut; waitForEnd: true }
    onExited: {
      var next = Model.parseStatus(readOut.text)
      if (next.ok) {
        root.state = next
        root.consecutiveFailures = 0
      } else {
        // Keep the last known state rather than blanking the bar, but stop
        // claiming it is current. Staleness is shown, never hidden.
        root.consecutiveFailures = root.consecutiveFailures + 1
      }
      poll.interval = Model.nextInterval(root.state, 90000, root.consecutiveFailures)
    }
  }

  Timer {
    id: poll
    interval: 90000
    repeat: true
    running: root.deviceId !== ""
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    // A fan glyph stands in for the temperature whenever Model.barLabel has
    // nothing to say (off, offline, or never configured). WidgetButton hides
    // itself when text is empty, but the spec is explicit that this widget
    // does the opposite: "the icon still renders" (Model.js) and "Icon
    // unlit" rather than absent (design spec, offline row) — so there is
    // always something to paint, and only opacity carries the state. The
    // literal snowflake "❄" renders as an illegible dot at bar size. The
    // obvious replacement, Nerd Font md-air_conditioner, turned out to be
    // its own version of the same bug: rendered at bar size it is a tiny fan
    // glyph with the literal text "A/C" baked into the artwork underneath
    // it, illegible for the same reason — verified by rendering the glyph
    // directly through the font, not just by eyeballing it small in an
    // editor. md-fan is the bare pinwheel alone, at the same visual weight
    // as the other plugins on this bar (e.g. 󰉼, 󰅁, 󰏫), and reads clearly at
    // bar size.
    text: root.label !== "" ? root.label : "󰈐"
    labelVisible: true
    // Dimmed when off, unreachable, or never configured. To someone glancing
    // at the bar those mean one thing: it is not cooling.
    opacity: (root.state.ok && root.state.online && root.state.power === "on") ? 1.0 : 0.55
    onPressed: function(b) { if (b === Qt.LeftButton) root.togglePanel() }
  }

  Loader {
    id: panelLoader
    source: Qt.resolvedUrl("Panel.qml")
    onLoaded: {
      item.host = root
      item.bar = root.bar
      item.foreground = Qt.binding(function() { return root.contentForeground })
      item.fontFamily = Qt.binding(function() { return root.contentFontFamily })
    }
  }
}

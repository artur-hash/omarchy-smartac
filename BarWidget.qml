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

  // Polling follows attention. Ninety seconds is right for a bar label nobody
  // is looking at, and far too slow with the panel open: this hardware changes
  // settings on its own -- a mode change drops the preset, each mode keeps its
  // own setpoint -- and until the next poll the panel showed a control the
  // device had already moved.
  readonly property bool panelOpen: panelLoader.item ? panelLoader.item.opened : false
  readonly property int pollBase: root.panelOpen ? 20000 : 90000
  readonly property string label: Model.barLabel(root.state)
  readonly property bool stale: root.consecutiveFailures > 0

  // The panel anchors its popup to this, not to the widget root. Ui/PopupCard
  // and Ui/KeyboardPanel both position from anchorItem's mapped geometry, and
  // the root Item is not the thing the user clicked — anchoring to it put the
  // panel at 0,0.
  readonly property alias anchorButton: button

  // Ui/Panel owns open/close/toggle; driving controller.open from outside
  // skipped whatever else those do. parm.clock and the first-party panels all
  // call the functions.
  function open()  { if (panelLoader.item) panelLoader.item.open() }
  function close() { if (panelLoader.item) panelLoader.item.close() }
  // The panel refreshes itself on open (see its onOpenedChanged), so this only
  // has to toggle — and the IPC path gets the same behaviour for free.
  function togglePanel() { if (panelLoader.item) panelLoader.item.toggle() }

  // Re-injected rather than set once on load: at onLoaded the button is not
  // yet inside the bar's window, so anchorItem.QsWindow is undefined and
  // KeyboardPanel resolves no screen — it then shows nothing, silently.
  function injectPanel() {
    var t = panelLoader.item
    if (!t) return
    t.host = root
    t.bar = root.bar
    t.anchorButton = button
  }
  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

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
    }
  }

  Timer {
    id: poll
    interval: Model.nextInterval(root.state, root.pollBase, root.consecutiveFailures, root.panelOpen)
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
      root.injectPanel()
      item.foreground = Qt.binding(function() { return root.contentForeground })
      item.fontFamily = Qt.binding(function() { return root.contentFontFamily })
    }
  }
}

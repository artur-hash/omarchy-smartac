import QtQuick
import qs.Ui

// Replaced in full by Task 9. Present so BarWidget.qml's Loader — which
// resolves this file eagerly, the moment the widget exists — has something
// to load rather than warning about a missing file on every shell restart
// between this task and the next.
Panel {
  id: panel
  property QtObject host: null
  property color foreground: "transparent"
  property string fontFamily: ""
  function refreshAll() {}
}

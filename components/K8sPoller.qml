import QtQuick
import Quickshell.Io

// Shared kubectl poller: runs `command` once on demand and on an interval
// while `active`. Emits finished(text, exitCode, stderrText).
// Both BarWidget (cheap summary) and Overlay (full topology) instantiate it.
Item {
  id: root

  property var command: []
  property int interval: 12000
  property bool active: false
  property bool running: false

  signal finished(string text, int exitCode, string err)

  function refresh() {
    if (!proc.running) proc.running = true
  }

  Process {
    id: proc
    command: root.command
    stdout: StdioCollector {
      id: outCol
      waitForEnd: true
    }
    stderr: StdioCollector {
      id: errCol
      waitForEnd: true
    }
    onStarted: root.running = true
    onExited: function(exitCode) {
      root.running = false
      root.finished(outCol.text, exitCode, errCol.text)
    }
  }

  Timer {
    interval: root.interval
    repeat: true
    running: root.active
    onTriggered: root.refresh()
  }

  onActiveChanged: {
    if (root.active) root.refresh()
  }
}

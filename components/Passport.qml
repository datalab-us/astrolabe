import QtQuick
import QtQuick.Layouts
import qs.Commons
import "../Model.js" as Model

// Right-side detail drawer for the selected node: identity, status,
// relationships, and actions. Logs / describe render in the overlay's
// output viewer; port-forward is managed (status pill up top, stop here);
// only "Open in terminal" (inside the viewer) spawns a terminal.
Rectangle {
  id: root

  property var node: null       // K8sGraph node object
  property var inEdges: []      // edges where node is `to`
  property var outEdges: []     // edges where node is `from`
  property int warnCount: 0
  property bool pfActive: false // a port-forward is running (overlay-owned)
  property string pfKey: ""     // node key the active forward belongs to
  property string copiedMsg: "" // transient "Copied ✓" feedback

  signal runCommand(string cmd)
  signal copyText(string value)
  signal showOutput(string title, var cmdArgs, string terminalCmd)
  signal togglePortForward()
  signal closed()

  visible: node !== null
  width: 320
  radius: Style.cornerRadius > 0 ? 12 : 0
  color: Color.menu.background
  border.width: 1
  border.color: Color.menu.border

  function edgeLabel(e) {
    var other = e.from === (node && node.id) ? e.to : e.from;
    var dir = e.from === (node && node.id) ? "→ " : "← ";
    return dir + e.type + " " + other;
  }

  Column {
    anchors.fill: parent
    anchors.margins: 16
    spacing: 10

    Row {
      width: parent.width
      spacing: 8
      Text {
        width: parent.width - 30
        text: node ? (node.kind + " / " + node.name) : ""
        color: Color.menu.text
        font.family: Style.font.family
        font.pixelSize: Style.font.title
        font.bold: true
        elide: Text.ElideRight
        wrapMode: Text.Wrap
      }
      Text {
        text: "✕"
        color: Color.muted
        font.pixelSize: 14
        MouseArea { anchors.fill: parent; onClicked: root.closed() }
      }
    }

    Text {
      width: parent.width
      visible: node && node.namespace !== ""
      text: node ? ("ns: " + node.namespace) : ""
      color: Color.muted
      font.family: Style.font.family
      font.pixelSize: Style.font.body
    }

    Row {
      spacing: 8
      Rectangle {
        width: 9; height: 9; radius: 4.5
        anchors.verticalCenter: parent.verticalCenter
        color: !node ? "#64748B"
          : node.status.level === "ok" ? "#34D399"
          : node.status.level === "warn" ? "#FBBF24"
          : node.status.level === "bad" ? "#FB7185" : "#64748B"
      }
      Text {
        text: node ? node.status.label : ""
        color: Color.menu.text
        font.family: Style.font.family
        font.pixelSize: Style.font.body
      }
    }

    // Key facts from the raw object.
    Column {
      width: parent.width
      spacing: 4
      visible: node !== null
      Text {
        width: parent.width
        text: node && node.detail.phase ? ("phase: " + node.detail.phase) : ""
        visible: text !== ""
        color: Color.menu.text
        font.family: Style.font.family
        font.pixelSize: Style.font.body
      }
      Text {
        width: parent.width
        text: node && node.detail.restarts !== undefined ? ("restarts: " + node.detail.restarts) : ""
        visible: node && node.kind === "Pod"
        color: Color.menu.text
        font.family: Style.font.family
        font.pixelSize: Style.font.body
      }
      Text {
        width: parent.width
        text: node && node.detail.node ? ("node: " + node.detail.node) : ""
        visible: text !== ""
        color: Color.menu.text
        font.family: Style.font.family
        font.pixelSize: Style.font.body
        elide: Text.ElideRight
      }
      Text {
        width: parent.width
        text: node && node.detail.containers ? ("containers: " + node.detail.containers.join(", ")) : ""
        visible: text !== ""
        color: Color.menu.text
        font.family: Style.font.family
        font.pixelSize: Style.font.body
        wrapMode: Text.Wrap
      }
      Text {
        width: parent.width
        text: node && node.detail.hosts ? ("hosts: " + node.detail.hosts.join(", ")) : ""
        visible: text !== ""
        color: Color.menu.text
        font.family: Style.font.family
        font.pixelSize: Style.font.body
        wrapMode: Text.Wrap
      }
    }

    Rectangle { width: parent.width; height: 1; color: Color.menu.border; opacity: 0.5 }

    Text {
      text: "RELATIONSHIPS"
      color: Color.muted
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      font.bold: true
      font.letterSpacing: 1
    }

    Column {
      width: parent.width
      spacing: 3
      Repeater {
        model: root.inEdges.concat(root.outEdges)
        Text {
          required property var modelData
          width: parent.width
          text: root.edgeLabel(modelData)
          color: Color.menu.text
          font.family: Style.font.family
          font.pixelSize: Style.font.bodySmall
          elide: Text.ElideRight
        }
      }
      Text {
        visible: root.inEdges.length + root.outEdges.length === 0
        text: "No linked resources."
        color: Color.muted
        font.family: Style.font.family
        font.pixelSize: Style.font.body
      }
    }

    Rectangle { width: parent.width; height: 1; color: Color.menu.border; opacity: 0.5 }

    Text {
      text: "ACTIONS"
      color: Color.muted
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      font.bold: true
      font.letterSpacing: 1
    }

    Text {
      width: parent.width
      visible: root.copiedMsg !== ""
      text: root.copiedMsg
      color: "#34D399"
      font.family: Style.font.family
      font.pixelSize: Style.font.bodySmall
    }

    GridLayout {
      width: parent.width
      columns: 2
      columnSpacing: 8
      rowSpacing: 8
      Repeater {
        model: [
          { label: "Logs", cmd: "logs", enabled: root.canShowLogs(),
            tip: "Show pod logs inside the plugin" },
          { label: "Describe", cmd: "describe", enabled: root.node !== null,
            tip: "Show kubectl describe output inside the plugin" },
          { label: root.isPfForNode() ? "Stop fwd" : "Port-fwd", cmd: "portfwd",
            enabled: root.canPortForward(),
            tip: "Forward localhost:8080 to this target's service port" },
          { label: "Copy describe", cmd: "copy", enabled: root.node !== null,
            tip: "Copy the kubectl describe command to the clipboard" }
        ]
        Rectangle {
          required property var modelData
          Layout.fillWidth: true
          height: 32
          radius: Style.cornerRadius > 0 ? 8 : 0
          color: "transparent"
          border.width: 1
          border.color: modelData.enabled ? Color.accent : Color.menu.border
          opacity: modelData.enabled ? 1.0 : 0.45
          Text {
            anchors.centerIn: parent
            text: parent.modelData.label
            color: Color.menu.text
            font.family: Style.font.family
            font.pixelSize: Style.font.body
          }
          MouseArea {
            anchors.fill: parent
            cursorShape: parent.modelData.enabled ? Qt.PointingHandCursor : Qt.ForbiddenCursor
            onClicked: {
              if (!parent.modelData.enabled) return
              var c = parent.modelData.cmd
              if (c === "logs") root.requestLogs()
              else if (c === "describe") root.requestDescribe()
              else if (c === "portfwd") root.togglePortForward()
              else if (c === "copy") root.copyDescribeCommand()
            }
          }
        }
      }
    }
    Timer {
      id: copyReset
      interval: 1500
      onTriggered: root.copiedMsg = ""
    }
  }

  function nodeKey() {
    if (!node) return ""
    return node.kind + "/" + (node.namespace || "") + "/" + node.name
  }

  function canShowLogs() {
    return node && node.kind === "Pod"
  }

  function canPortForward() {
    return node && (node.kind === "Service" || node.kind === "Pod")
  }

  function isPfForNode() {
    return root.pfActive && root.pfKey !== "" && root.pfKey === nodeKey()
  }

  function singleContainer() {
    return (node && node.detail.containers && node.detail.containers.length === 1)
      ? node.detail.containers[0] : ""
  }

  function displayName() {
    if (!node) return ""
    return node.kind + " " + (node.namespace ? node.namespace + "/" : "") + node.name
  }

  function requestLogs() {
    if (!canShowLogs()) return
    var c = singleContainer()
    var args = Model.logsArgs(node.namespace, node.name, c)
    root.showOutput("Logs: " + displayName(), args,
      Model.logsCommand(node.namespace, node.name, c))
  }

  function requestDescribe() {
    if (!node) return
    var args = Model.describeArgs(node.kind, node.namespace, node.name)
    root.showOutput("Describe: " + displayName(), args, actionCommand("describe"))
  }

  function copyDescribeCommand() {
    if (!node) return
    root.copyText(actionCommand("describe"))
    root.copiedMsg = "Copied describe command ✓"
    copyReset.restart()
  }

  // Builds the kubectl invocation for an action. Port-forward targets the
  // service (or pod) on 8080->80; the user edits ports in the terminal.
  function actionCommand(which) {
    if (!node) return ""
    if (which === "logs" && node.kind === "Pod") {
      var container = (node.detail.containers && node.detail.containers.length === 1)
        ? node.detail.containers[0] : ""
      return Model.logsCommand(node.namespace, node.name, container)
    }
    if (which === "portfwd" && (node.kind === "Service" || node.kind === "Pod")) {
      var tgt = node.kind === "Service" ? "svc/" + node.name : node.name
      return Model.portForwardCommand(node.namespace, tgt, 8080, 80)
    }
    return Model.describeCommand(node.kind, node.namespace, node.name)
  }
}

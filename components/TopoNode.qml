import QtQuick
import qs.Commons

// One topology node card. Positioned by the parent from K8sGraph.layout().
// Colors follow the Archify-derived semantic vocabulary (see Overlay).
Rectangle {
  id: root

  property string nodeId: ""
  property string nodeKind: ""
  property string nodeName: ""
  property string nodeNs: ""
  property string statusLevel: "unknown" // ok | warn | bad | unknown
  property string statusLabel: ""
  property bool selected: false
  property bool dimmed: false
  property color accent: "#94A3B8"
  property string fontFamily: Style.font.family

  signal pressed(string id)

  width: 190
  height: 64
  radius: Style.cornerRadius > 0 ? 8 : 0
  color: selected ? Qt.lighter(Color.background, 1.6) : Color.background
  border.width: selected ? 2 : 1
  border.color: selected ? accent : Qt.rgba(1, 1, 1, 0.14)
  opacity: dimmed ? 0.25 : 1.0

  Behavior on opacity { NumberAnimation { duration: 150 } }

  // Kind stripe.
  Rectangle {
    anchors.left: parent.left
    anchors.top: parent.top
    anchors.bottom: parent.bottom
    anchors.leftMargin: 1
    anchors.topMargin: 6
    anchors.bottomMargin: 6
    width: 4
    radius: 2
    color: root.accent
  }

  // Status dot.
  Rectangle {
    anchors.right: parent.right
    anchors.top: parent.top
    anchors.rightMargin: 8
    anchors.topMargin: 8
    width: 9
    height: 9
    radius: 4.5
    color: root.statusLevel === "ok" ? "#34D399"
      : root.statusLevel === "warn" ? "#FBBF24"
      : root.statusLevel === "bad" ? "#FB7185" : "#64748B"
  }

  Column {
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.verticalCenter: parent.verticalCenter
    anchors.leftMargin: 14
    anchors.rightMargin: 22
    spacing: 2

    Text {
      width: parent.width
      text: root.nodeKind.toUpperCase()
      color: root.accent
      font.family: root.fontFamily
      font.pixelSize: 10
      font.bold: true
      font.letterSpacing: 1
      elide: Text.ElideRight
    }
    Text {
      width: parent.width
      text: root.nodeName
      color: Color.foreground
      font.family: root.fontFamily
      font.pixelSize: 13
      font.bold: true
      elide: Text.ElideRight
    }
    Text {
      width: parent.width
      text: (root.nodeNs !== "" ? root.nodeNs + " · " : "") + root.statusLabel
      color: Qt.darker(Color.foreground, 1.35)
      font.family: root.fontFamily
      font.pixelSize: 11
      elide: Text.ElideRight
    }
  }

  MouseArea {
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onClicked: root.pressed(root.nodeId)
  }
}

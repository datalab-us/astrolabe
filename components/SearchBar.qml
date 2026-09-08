import QtQuick
import qs.Commons

// Single-line filter field. Emits textChanged; parent debounces the search.
Rectangle {
  id: root

  property string text: ""
  property string placeholder: "Search kind / ns / name  ( / )"
  readonly property bool hasFocus: input.activeFocus
  // Overlay passes its key catcher so Esc/Enter can hand keyboard control
  // back (u/d/+/-/R shortcuts live there, not in the field).
  property var keyTarget: null

  signal accepted()

  function release() {
    // V1: synchronous handoff only (mirrors open(), which is proven to work).
    if (keyTarget) keyTarget.forceActiveFocus()
  }

  height: 34
  radius: Style.cornerRadius > 0 ? 8 : 0
  color: Color.background
  border.width: 1
  border.color: input.activeFocus ? Color.accent : Qt.rgba(1, 1, 1, 0.16)

  function focusField() { input.forceActiveFocus() }
  function clear() { input.text = "" }

  Text {
    anchors.fill: parent
    anchors.leftMargin: 12
    verticalAlignment: Text.AlignVCenter
    visible: input.text === ""
    text: root.placeholder
    color: Color.muted
    font.family: Style.font.family
    font.pixelSize: Style.font.body
  }

  TextInput {
    id: input
    anchors.fill: parent
    anchors.leftMargin: 12
    anchors.rightMargin: 30
    verticalAlignment: TextInput.AlignVCenter
    color: Color.foreground
    font.family: Style.font.family
    font.pixelSize: Style.font.body
    selectByMouse: true
    onTextChanged: root.text = text
    Keys.onPressed: function(event) {
      if (event.key === Qt.Key_Escape) {
        if (input.text !== "") root.clear()
        else root.release()
        event.accepted = true
      } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
        root.accepted()
        root.release()
        event.accepted = true
      }
    }
  }

  Text {
    anchors.right: parent.right
    anchors.rightMargin: 10
    anchors.verticalCenter: parent.verticalCenter
    visible: input.text !== ""
    text: "✕"
    color: Color.muted
    font.pixelSize: 13
    MouseArea {
      anchors.fill: parent
      onClicked: root.clear()
    }
  }
}

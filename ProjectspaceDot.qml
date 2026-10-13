import QtQuick
import qs.Commons

// A projectspace's mark: its PROJECTSPACE_ICON glyph when it sets one, a dot
// in its color otherwise. Hollow when the attached folder is gone or its mise
// config does not load, so a broken attachment still reads as "attached".
Item {
  id: root

  property color color: "transparent"
  property string icon: ""
  property real size: Style.space(6)
  property bool hollow: false
  property string fontFamily: Style.font.family
  property real glyphSize: Style.font.body

  implicitWidth: icon !== "" ? glyph.implicitWidth : size
  implicitHeight: icon !== "" ? glyph.implicitHeight : size

  Rectangle {
    visible: root.icon === ""
    anchors.centerIn: parent
    width: root.size
    height: root.size
    radius: root.size / 2
    color: root.hollow ? "transparent" : root.color
    border.width: root.hollow ? Math.max(1, Math.round(root.size / 5)) : 0
    border.color: root.color
    antialiasing: true
  }

  Text {
    id: glyph
    visible: root.icon !== ""
    anchors.centerIn: parent
    textFormat: Text.PlainText
    text: root.icon
    color: root.color
    opacity: root.hollow ? 0.5 : 1
    font.family: root.fontFamily
    font.pixelSize: root.glyphSize
  }
}

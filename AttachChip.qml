import QtQuick
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// One choice in the projectspace picker: a dot and a name, selected when the
// workspace is attached to it. "None" has no dot.
BorderSurface {
  id: chip

  property string label: ""
  property color dotColor: "transparent"
  property string icon: ""
  property bool selected: false
  property color foreground: Commons.Color.foreground
  property string fontFamily: Style.font.family

  signal clicked()

  readonly property bool hot: mouse.containsMouse
  readonly property color accent: Commons.Color.accent

  implicitWidth: content.implicitWidth + Style.spacing.controlPaddingX * 2
  implicitHeight: content.implicitHeight + Style.spacing.sm * 2 + Style.space(2)
  radius: Style.cornerRadius
  color: selected ? Style.selectedFillFor(foreground, accent)
    : (hot ? Style.hoverFillFor(foreground, accent) : "transparent")
  borderSpec: selected ? Border.controlSpec("selected", foreground, accent)
    : (hot ? Border.controlSpec("hover-cursor", foreground, accent)
      : Border.controlSpec("normal", foreground, accent))

  Behavior on color { ColorAnimation { duration: Style.duration(60) } }

  Row {
    id: content
    anchors.centerIn: parent
    spacing: Style.space(6)

    ProjectspaceDot {
      visible: chip.dotColor.a > 0
      anchors.verticalCenter: parent.verticalCenter
      color: chip.dotColor
      icon: chip.icon
      size: Style.space(7)
      fontFamily: chip.fontFamily
      glyphSize: Style.font.bodySmall
    }

    Text {
      anchors.verticalCenter: parent.verticalCenter
      textFormat: Text.PlainText
      text: chip.label
      color: chip.foreground
      opacity: chip.selected || chip.hot ? 1 : 0.8
      font.family: chip.fontFamily
      font.pixelSize: Style.font.bodySmall
      font.bold: chip.selected
    }
  }

  MouseArea {
    id: mouse
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onClicked: chip.clicked()
  }
}

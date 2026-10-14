import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Ui
import "Model.js" as Model

// One workspace in the panel: its key, its projectspace mark, its name and how
// many windows it holds. The row under the cursor shows a rename button; while
// renaming, the name turns into a field. Clicking selects the row (its
// projectspace shows below); a double click goes to the workspace.
CursorSurface {
  id: row

  required property int wsId
  // The owning BarWidget: rows read its state and call back into it.
  property var panel

  readonly property var projectspace: Model.projectspaceFor(panel.spaces, wsId)
  readonly property string labelSource: Model.labelSource(wsId, panel.names, panel.spaces)
  readonly property bool active: panel.monitorActiveId === wsId
  readonly property int windows: panel.windowCount(wsId)
  // Windows the last session had here that are not open now.
  readonly property var restore: Model.restoreFor(panel.lastSession, wsId)
  readonly property int reopen: restore ? restore.missing : 0
  readonly property bool editing: panel.editingId === wsId
  readonly property bool picked: panel.cursorId === wsId
  readonly property color fg: panel.fg
  readonly property color dim: Qt.darker(fg, 1.5)

  hasCursor: picked && !editing
  current: active
  foreground: fg
  width: parent ? parent.width : implicitWidth
  implicitHeight: Math.max(Style.spacing.popupRowHeight, nameField.implicitHeight) + Style.space(4)

  MouseArea {
    anchors.fill: parent
    hoverEnabled: true
    acceptedButtons: Qt.LeftButton | Qt.RightButton
    cursorShape: Qt.PointingHandCursor
    onContainsMouseChanged: if (containsMouse && !row.panel.editingAny) row.panel.cursorId = row.wsId
    onClicked: function(mouse) {
      if (mouse.button === Qt.RightButton) row.panel.startRename(row.wsId)
      else row.panel.cursorId = row.wsId
    }
    onDoubleClicked: function(mouse) {
      if (mouse.button === Qt.LeftButton) row.panel.goTo(row.wsId)
    }
  }

  RowLayout {
    anchors.fill: parent
    anchors.leftMargin: Style.space(10)
    anchors.rightMargin: Style.space(4)
    spacing: Style.space(8)

    Text {
      textFormat: Text.PlainText
      text: Model.keyLabel(row.wsId)
      color: row.dim
      font.family: row.panel.fontFamily
      font.pixelSize: Style.font.bodySmall
      horizontalAlignment: Text.AlignHCenter
      Layout.preferredWidth: Style.space(10)
    }

    // Always laid out, so names line up whether or not a row is attached.
    Item {
      Layout.preferredWidth: Style.space(10)
      Layout.preferredHeight: Style.space(10)

      ProjectspaceDot {
        visible: row.projectspace !== null
        anchors.centerIn: parent
        color: row.projectspace ? row.projectspace.color : "transparent"
        icon: row.projectspace ? row.projectspace.icon : ""
        hollow: row.projectspace ? !row.projectspace.ok : false
        size: Style.space(8)
        fontFamily: row.panel.fontFamily
        glyphSize: Style.font.body
      }
    }

    Item {
      Layout.fillWidth: true
      Layout.preferredHeight: Math.max(nameText.implicitHeight, row.editing ? nameField.implicitHeight : 0)

      Text {
        id: nameText
        visible: !row.editing
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        textFormat: Text.PlainText
        // The key column already shows the number; an unnamed row says so.
        text: row.labelSource === "default" ? "unnamed" : Model.labelFor(row.wsId, row.panel.names, row.panel.spaces)
        color: row.fg
        opacity: row.labelSource === "default" ? 0.4 : 1
        font.italic: row.labelSource === "default"
        font.family: row.panel.fontFamily
        font.pixelSize: Style.font.body
        font.bold: row.active
        elide: Text.ElideRight
      }

      TextField {
        id: nameField
        visible: row.editing
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        foreground: row.fg
        font.family: row.panel.fontFamily
        font.pixelSize: Style.font.body
        verticalPadding: Style.spacing.xs
        horizontalPadding: Style.spacing.sm
        placeholderText: row.projectspace ? row.projectspace.name : "Workspace " + Model.keyLabel(row.wsId)

        property bool cancelled: false

        onVisibleChanged: {
          if (!visible) return
          cancelled = false
          text = row.panel.names[String(row.wsId)] || ""
          forceActiveFocus()
          selectAll()
        }
        Keys.onEscapePressed: function(event) {
          cancelled = true
          row.panel.endRename()
          event.accepted = true
        }
        onEditingFinished: {
          if (!row.editing || cancelled) return
          row.panel.setName(row.wsId, text)
          row.panel.endRename()
        }
      }
    }

    // A custom name hides the projectspace's own; it is shown alongside.
    Text {
      visible: row.projectspace !== null && row.labelSource === "custom" && !row.editing
      textFormat: Text.PlainText
      text: row.projectspace ? row.projectspace.name : ""
      color: row.projectspace ? row.projectspace.color : row.dim
      font.family: row.panel.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: true
      elide: Text.ElideRight
      Layout.maximumWidth: Style.space(110)
    }

    Text {
      visible: row.reopen > 0 && !row.editing
      textFormat: Text.PlainText
      text: "\uf1da " + row.reopen
      color: row.dim
      font.family: row.panel.fontFamily
      font.pixelSize: Style.font.caption
    }

    Text {
      visible: !row.editing
      textFormat: Text.PlainText
      text: row.windows > 0 ? String(row.windows) : "·"
      color: row.dim
      font.family: row.panel.fontFamily
      font.pixelSize: Style.font.caption
      horizontalAlignment: Text.AlignRight
      Layout.preferredWidth: Style.space(14)
    }

    PanelActionButton {
      iconText: ""
      tooltipText: "Rename (e)"
      foreground: row.fg
      fontFamily: row.panel.fontFamily
      fontSize: Style.font.bodySmall
      size: Style.space(22)
      opacity: row.picked && !row.editing ? 1 : 0
      enabled: row.picked && !row.editing
      onClicked: row.panel.startRename(row.wsId)
    }
  }
}

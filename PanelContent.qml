import QtQuick
import QtQuick.Layouts
import QtQuick.Window
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Model.js" as Model

// The panel's body: a tab per screen on top, the shown screen's ten workspaces
// on the left, the selected one's projectspace, open and saved windows on the
// right, settings and keys below. Lives apart from BarWidget so a preview can render it without a
// KeyboardPanel (tests/preview).
PanelKeyCatcher {
  id: keys

  // The owning BarWidget: its state, settings and actions.
  property var panel
  anchors.fill: parent
  implicitHeight: body.implicitHeight
  // Two columns when the card has room; a narrow screen stacks them.
  readonly property bool wide: width >= Style.space(660)
  readonly property int sideWidth: wide ? Style.space(330) : width
  readonly property int mainWidth: wide ? width - sideWidth - 2 * Style.spacing.panelGap - 1 : width
  readonly property color rule: Qt.rgba(panel.fg.r, panel.fg.g, panel.fg.b, 0.12)
  blocked: panel.editingAny

  onCloseRequested: panel.close()
  onTabRequested: function(direction) { panel.switchPanel(direction) }
  onMoveRequested: function(dx, dy) {
    if (dy !== 0) panel.cursorId = Model.moveCursor(panel.cursorId, dy, panel.rowIds)
    else panel.cycleAttachment(panel.cursorId, dx)
  }
  onActivateRequested: panel.goTo(panel.cursorId)
  onDeleteRequested: panel.clearRow(panel.cursorId)
  onTextKey: function(text, modifiers) {
    var ws = Model.workspaceForKey(text, panel.shownBlock)
    if (ws > 0) { panel.cursorId = ws; return }
    if (text === "[" || text === "]") { panel.switchScreen(text === "]" ? 1 : -1); return }
    if (text === "O") { panel.restoreWindows(0); return }
    var key = text.toLowerCase()
    if (key === "o") panel.restoreWindows(panel.cursorId)
    else if (key === "e") panel.startRename(panel.cursorId)
    else if (key === "t") panel.openTerminal(panel.cursorId)
    else if (key === "c") panel.editConfig(panel.cursorId)
    else if (key === "s") panel.saveWindows(panel.cursorId)
    else if (key === "r") panel.refresh()
  }

  // A press anywhere else while a name is being edited takes focus from the
  // field, which saves it, and goes on to whatever was pressed.
  MouseArea {
    anchors.fill: parent
    z: 1
    enabled: panel.editingAny
    acceptedButtons: Qt.AllButtons
    onPressed: function(mouse) {
      // Inside the field itself, it is only placing the text cursor.
      var field = keys.Window.activeFocusItem
      var inField = field && field !== keys && field.contains(field.mapFromItem(keys, mouse.x, mouse.y))
      if (!inField) keys.forceActiveFocus()
      mouse.accepted = false
    }
  }

  Column {
    id: body
    width: parent.width
    spacing: Style.spacing.panelGap

    PanelHero {
      width: parent.width
      title: "Projectspaces"
      // The workspace you are on, and its projectspace when the name hides it.
      meta: {
        var label = Model.labelFor(panel.monitorActiveId, panel.names, panel.spaces)
        var p = panel.activeProjectspace
        var parts = ["Workspace " + Model.keyLabel(panel.monitorActiveId), label]
        if (p && p.name !== label) parts.push(p.name)
        return parts.join("  ·  ")
      }
      foreground: panel.fg
      fontFamily: panel.fontFamily
      iconComponent: Component {
        Item {
          width: Style.font.display
          height: Style.font.display

          ProjectspaceDot {
            visible: panel.activeProjectspace !== null
            anchors.centerIn: parent
            color: panel.activeProjectspace ? panel.activeProjectspace.color : "transparent"
            icon: panel.activeProjectspace ? panel.activeProjectspace.icon : ""
            hollow: panel.activeProjectspace ? !panel.activeProjectspace.ok : false
            size: Style.space(16)
            fontFamily: panel.fontFamily
            glyphSize: Style.font.display
          }

          OpticalGlyph {
            visible: panel.activeProjectspace === null
            anchors.fill: parent
            text: ""
            fontFamily: panel.fontFamily
            fontSize: Style.font.display
            color: panel.fg
          }
        }
      }
    }

    PanelSeparator { foreground: panel.fg }

    // ---- a tab per screen, with more than one
    ButtonGroup {
      visible: panel.screenTabs.length > 1
      focusable: false
      options: panel.screenTabs.map(function(t) {
        return {
          value: String(t.block), icon: t.icon,
          label: t.plugged ? t.label : t.label + " (unplugged)",
          tooltip: t.plugged ? "Workspaces on " + t.label + " ([ ])" : t.label + " is unplugged: its attachments and names wait for it"
        }
      })
      value: String(panel.shownBlock)
      foreground: panel.fg
      fontFamily: panel.fontFamily
      fontSize: Style.font.bodySmall
      onChanged: function(value) { panel.showScreen(Number(value)) }
    }

    GridLayout {
      width: parent.width
      columns: keys.wide ? 3 : 1
      columnSpacing: Style.spacing.panelGap
      rowSpacing: Style.spacing.panelGap

      // ---- the workspaces
      Column {
        Layout.preferredWidth: keys.sideWidth
        Layout.alignment: Qt.AlignTop
        spacing: Style.space(2)

          Repeater {
            model: panel.rowIds

            WorkspaceRow {
              required property int modelData
              wsId: modelData
              panel: keys.panel
            }
          }
      }

      Rectangle {
        visible: keys.wide
        Layout.preferredWidth: 1
        Layout.fillHeight: true
        color: keys.rule
      }

      PanelSeparator {
        visible: !keys.wide
        Layout.preferredWidth: keys.mainWidth
        foreground: panel.fg
      }

      // ---- the selected workspace: its projectspace, what is open, what is saved
      Column {
        Layout.preferredWidth: keys.mainWidth
        Layout.alignment: Qt.AlignTop
        spacing: Style.spacing.panelGap

        // ---- its projectspace
        Column {
          id: detail
          width: parent.width
          spacing: Style.spacing.rowGap

          readonly property var p: panel.cursorProjectspace
          readonly property var envView: p ? Model.envRows(p.env, panel.home, 6) : ({ rows: [], hidden: 0 })
          readonly property string trustCommand: Model.trustCommand(p)

          RowLayout {
            width: parent.width
            spacing: Style.spacing.md

            PanelSectionHeader {
              Layout.fillWidth: true
              text: (panel.screenTabs.length > 1 ? panel.screenOf(Model.blockOf(panel.cursorId)) + " " : "Workspace ")
                + Model.keyLabel(panel.cursorId) + " projectspace"
              foreground: panel.fg
              fontFamily: panel.fontFamily
            }

            // Where it is, and how it tiles.
            Text {
              textFormat: Text.PlainText
              text: {
                var parts = []
                // The header names its screen; this says where it is only when
                // that is elsewhere, a guest of another monitor.
                var m = panel.monitorFor(panel.cursorId)
                if (m && panel.multiMonitor && m.label !== panel.screenOf(Model.blockOf(panel.cursorId))) parts.push(m.icon + "  " + m.label)
                if (live.entry && live.entry.layout) parts.push(Model.layoutLabel(live.entry.layout))
                return parts.join("  ·  ")
              }
              color: panel.dim
              font.family: panel.fontFamily
              font.pixelSize: Style.font.caption
            }
          }

          Flow {
            width: parent.width
            spacing: Style.spacing.md

            Repeater {
              model: Model.attachOptions(panel.spaces)

              AttachChip {
                required property var modelData
                label: modelData.name
                dotColor: modelData.color || "transparent"
                icon: modelData.home && panel.spaces.byHome[modelData.home] ? panel.spaces.byHome[modelData.home].icon : ""
                selected: (detail.p ? detail.p.home : "") === modelData.home
                foreground: panel.fg
                fontFamily: panel.fontFamily
                onClicked: panel.attach(panel.cursorId, modelData.home)
              }
            }
          }

          // A project on this screen only: the same slot on another screen is
          // offered when free, else that screen's tab to pick one. Where it
          // is on several already, the row's link icon says so.
          Flow {
            id: pairing
            width: parent.width
            spacing: Style.spacing.md
            visible: offers.length > 0

            readonly property var offers: {
              if (!detail.p || Model.pairedIds(panel.spaces, panel.cursorId).length > 0) return []
              var out = []
              var here = Model.blockOf(panel.cursorId)
              for (var i = 0; i < panel.screenTabs.length; i++) {
                var tab = panel.screenTabs[i]
                if (tab.block === here || !tab.plugged) continue
                var same = tab.block * Model.SLOTS + Model.slotOf(panel.cursorId)
                out.push({ block: tab.block, label: tab.label, id: Model.projectspaceFor(panel.spaces, same) ? -1 : same })
              }
              return out
            }

            Text {
              height: Style.space(22)
              verticalAlignment: Text.AlignVCenter
              textFormat: Text.PlainText
              text: "Only on this screen"
              color: panel.dim
              font.family: panel.fontFamily
              font.pixelSize: Style.font.caption
            }

            Repeater {
              model: pairing.offers

              Button {
                required property var modelData
                text: modelData.id > 0 ? "Attach on " + modelData.label + " " + Model.keyLabel(modelData.id) : "Pick a " + modelData.label + " workspace"
                tooltipText: modelData.id > 0
                  ? "Attach " + detail.p.name + " to " + modelData.label + "'s workspace " + Model.keyLabel(modelData.id) + " too, so both come up together"
                  : modelData.label + "'s workspace " + Model.keyLabel(panel.cursorId) + " has a projectspace; pick another there"
                iconText: modelData.id > 0 ? "+" : ""
                foreground: panel.fg
                fontFamily: panel.fontFamily
                fontSize: Style.font.caption
                bordered: true
                horizontalPadding: Style.space(6)
                verticalPadding: Style.space(2)
                onClicked: {
                  if (modelData.id > 0) panel.attach(modelData.id, detail.p.home)
                  else panel.showScreen(modelData.block)
                }
              }
            }
          }

          Text {
            width: parent.width
            visible: detail.p === null
            textFormat: Text.PlainText
            wrapMode: Text.WordWrap
            text: panel.spaces.projectspaces.length > 0
              ? "Attach one and everything launched on this workspace starts in its folder, with its mise env."
              : "No projectspaces yet: a projectspace is a folder under ~/Projects with a mise config at its root."
            color: panel.dim
            font.family: panel.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          Text {
            width: parent.width
            visible: detail.p !== null
            textFormat: Text.PlainText
            elide: Text.ElideMiddle
            text: detail.p ? Model.tildify(detail.p.config || detail.p.home, panel.home) : ""
            color: panel.dim
            font.family: panel.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          // A config that does not load says why, and offers the fix when
          // there is one.
          RowLayout {
            width: parent.width
            visible: detail.p !== null && !detail.p.ok
            spacing: Style.spacing.md

            Text {
              Layout.fillWidth: true
              textFormat: Text.PlainText
              wrapMode: Text.WordWrap
              text: detail.p ? (detail.p.missing ? "This folder is gone or no longer has a mise config. Launches here get no projectspace env." : detail.p.error.split(panel.home + "/").join("~/")) : ""
              color: panel.bar ? panel.bar.urgent : Commons.Color.urgent
              font.family: panel.fontFamily
              font.pixelSize: Style.font.bodySmall
            }

            Button {
              visible: detail.trustCommand !== ""
              text: "Trust"
              iconText: ""
              tooltipText: detail.trustCommand
              foreground: panel.fg
              fontFamily: panel.fontFamily
              fontSize: Style.font.bodySmall
              bordered: true
              horizontalPadding: Style.space(8)
              verticalPadding: Style.space(3)
              onClicked: panel.trust(detail.p)
            }
          }

          GridLayout {
            width: parent.width
            visible: detail.envView.rows.length > 0
            columns: 2
            columnSpacing: Style.spacing.lg
            rowSpacing: Style.space(3)

            Repeater {
              model: detail.envView.rows

              Text {
                required property var modelData
                required property int index
                Layout.row: index
                Layout.column: 0
                // Capped, so one long key does not squeeze every value.
                Layout.maximumWidth: Math.round(detail.width * 0.42)
                elide: Text.ElideRight
                textFormat: Text.PlainText
                text: modelData.key
                color: panel.dim
                font.family: panel.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
              }
            }

            Repeater {
              model: detail.envView.rows

              Text {
                required property var modelData
                required property int index
                Layout.row: index
                Layout.column: 1
                Layout.fillWidth: true
                textFormat: Text.PlainText
                text: modelData.value
                color: panel.fg
                elide: Text.ElideMiddle
                font.family: panel.fontFamily
                font.pixelSize: Style.font.caption
              }
            }
          }

          Text {
            visible: detail.envView.hidden > 0
            textFormat: Text.PlainText
            text: "+ " + detail.envView.hidden + " more  ·  omaprojectspace status --ws " + panel.cursorId
            color: panel.dim
            font.family: panel.fontFamily
            font.pixelSize: Style.font.caption
          }

          Row {
            visible: detail.p !== null && !detail.p.missing
            spacing: Style.spacing.md

            Button {
              text: "Terminal"
              iconText: ""
              tooltipText: "A terminal in " + (detail.p ? detail.p.name : "") + ", with its env (t)"
              foreground: panel.fg
              fontFamily: panel.fontFamily
              fontSize: Style.font.bodySmall
              bordered: true
              horizontalPadding: Style.space(8)
              verticalPadding: Style.space(3)
              onClicked: panel.openTerminal(panel.cursorId)
            }

            Button {
              visible: detail.p !== null && detail.p.config !== ""
              text: "Edit mise config"
              iconText: ""
              tooltipText: "Open " + (detail.p ? Model.tildify(detail.p.config, panel.home) : "") + " (c)"
              foreground: panel.fg
              fontFamily: panel.fontFamily
              fontSize: Style.font.bodySmall
              bordered: true
              horizontalPadding: Style.space(8)
              verticalPadding: Style.space(3)
              onClicked: panel.editConfig(panel.cursorId)
            }
          }
        }

        // ---- what is open on it now: where each window sits, then the list
        PanelSeparator { foreground: panel.fg }

        Column {
          id: live
          width: parent.width
          spacing: Style.spacing.rowGap

          readonly property var entry: Model.liveFor(panel.windowsInfo, panel.cursorId)
          readonly property var drawing: Model.layoutBoxes(entry, width, Style.space(120))
          readonly property int shown: 6

          RowLayout {
            width: parent.width
            spacing: Style.spacing.md

            PanelSectionHeader {
              Layout.fillWidth: true
              text: "Open now"
              foreground: panel.fg
              fontFamily: panel.fontFamily
            }

            Text {
              visible: live.entry !== null
              textFormat: Text.PlainText
              text: Model.windowsLabel(live.entry ? live.entry.windows.length : 0)
              color: panel.dim
              font.family: panel.fontFamily
              font.pixelSize: Style.font.caption
            }
          }

          Text {
            width: parent.width
            visible: live.entry === null
            textFormat: Text.PlainText
            text: "No windows on workspace " + Model.keyLabel(panel.cursorId) + "."
            color: panel.dim
            font.family: panel.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          // The layout in miniature: the screen's usable area as a frame, each
          // window as a box, the last focused one brighter. A scrolling
          // layout's off-screen columns sit outside the frame.
          Item {
            visible: live.entry !== null
            width: live.drawing.width
            height: live.drawing.height
            anchors.horizontalCenter: parent.horizontalCenter

            Rectangle {
              visible: live.drawing.view !== null
              x: live.drawing.view ? live.drawing.view.x : 0
              y: live.drawing.view ? live.drawing.view.y : 0
              width: live.drawing.view ? live.drawing.view.w : 0
              height: live.drawing.view ? live.drawing.view.h : 0
              color: Qt.rgba(panel.fg.r, panel.fg.g, panel.fg.b, 0.04)
              border.width: 1
              border.color: Qt.rgba(panel.fg.r, panel.fg.g, panel.fg.b, 0.35)
              radius: 2
            }

            Repeater {
              model: live.drawing.boxes

              Rectangle {
                required property var modelData
                x: modelData.x + 2
                y: modelData.y + 2
                width: Math.max(2, modelData.w - 4)
                height: Math.max(2, modelData.h - 4)
                radius: 2
                color: Qt.rgba(panel.fg.r, panel.fg.g, panel.fg.b, modelData.focused ? 0.22 : 0.1)
                border.width: 1
                border.color: Qt.rgba(panel.fg.r, panel.fg.g, panel.fg.b, modelData.focused ? 0.8 : 0.3)

                Text {
                  anchors.fill: parent
                  anchors.margins: Style.space(3)
                  visible: parent.width > Style.space(28) && parent.height > Style.space(14)
                  textFormat: Text.PlainText
                  text: modelData.name
                  color: panel.fg
                  opacity: modelData.focused ? 1 : 0.7
                  elide: Text.ElideRight
                  horizontalAlignment: Text.AlignHCenter
                  verticalAlignment: Text.AlignVCenter
                  font.family: panel.fontFamily
                  font.pixelSize: Style.font.caption
                }

                MouseArea {
                  anchors.fill: parent
                  cursorShape: Qt.PointingHandCursor
                  onClicked: panel.focusWindow(modelData.address)
                }
              }
            }
          }

          // Left to right as they sit; a click goes to the window.
          Repeater {
            model: live.entry ? live.entry.windows.slice(0, live.shown) : []

            CursorSurface {
              id: winRow
              required property var modelData
              width: live.width
              implicitHeight: Style.space(22)
              foreground: panel.fg
              hasCursor: hover.containsMouse

              MouseArea {
                id: hover
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: panel.focusWindow(winRow.modelData.address)
              }

              RowLayout {
                anchors.fill: parent
                anchors.leftMargin: Style.space(4)
                anchors.rightMargin: Style.space(4)
                spacing: Style.space(8)

                Text {
                  textFormat: Text.PlainText
                  text: winRow.modelData.kind === "terminal" ? "\uf120" : (winRow.modelData.kind === "browser" ? "\uf0ac" : "\uf2d0")
                  color: panel.dim
                  font.family: panel.fontFamily
                  font.pixelSize: Style.font.caption
                  Layout.preferredWidth: Style.space(12)
                  horizontalAlignment: Text.AlignHCenter
                }

                Text {
                  textFormat: Text.PlainText
                  text: winRow.modelData.name
                  color: panel.fg
                  elide: Text.ElideMiddle
                  font.family: panel.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  Layout.maximumWidth: Math.round(live.width * 0.45)
                }

                Text {
                  Layout.fillWidth: true
                  textFormat: Text.PlainText
                  text: winRow.modelData.title !== winRow.modelData.name ? winRow.modelData.title : ""
                  color: panel.dim
                  elide: Text.ElideRight
                  font.family: panel.fontFamily
                  font.pixelSize: Style.font.caption
                }

                Text {
                  visible: winRow.modelData.floating
                  textFormat: Text.PlainText
                  text: "floating"
                  color: panel.dim
                  font.family: panel.fontFamily
                  font.pixelSize: Style.font.caption
                }
              }
            }
          }

          Text {
            visible: live.entry !== null && live.entry.windows.length > live.shown
            textFormat: Text.PlainText
            text: live.entry ? "+ " + (live.entry.windows.length - live.shown) + " more" : ""
            color: panel.dim
            font.family: panel.fontFamily
            font.pixelSize: Style.font.caption
          }
        }

        // ---- the windows saved as its setup
        PanelSeparator { foreground: panel.fg }

        Column {
          id: session
          width: parent.width
          spacing: Style.spacing.rowGap

          readonly property var entry: Model.restoreFor(panel.windowsInfo, panel.cursorId)
          readonly property int shown: 6
          readonly property bool busy: panel.restoringId >= 0

          RowLayout {
            width: parent.width
            spacing: Style.spacing.md

            PanelSectionHeader {
              Layout.fillWidth: true
              text: "Saved windows"
              foreground: panel.fg
              fontFamily: panel.fontFamily
            }

            Text {
              visible: session.entry !== null
              textFormat: Text.PlainText
              text: session.entry ? "saved " + Model.savedLabel(session.entry.saved, Math.round(panel.now)) : ""
              color: panel.dim
              font.family: panel.fontFamily
              font.pixelSize: Style.font.caption
            }
          }

          Text {
            width: parent.width
            visible: session.entry === null
            textFormat: Text.PlainText
            wrapMode: Text.WordWrap
            text: "Nothing saved for workspace " + Model.keyLabel(panel.cursorId) + ". Open the windows it needs, then save: restore brings back whatever of them is missing."
            color: panel.dim
            font.family: panel.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          // What was open: a ring for what restore would reopen, a dot for what
          // is open again already.
          Repeater {
            model: session.entry ? session.entry.windows.slice(0, session.shown) : []

            RowLayout {
              required property var modelData
              width: session.width
              spacing: Style.space(8)

              Text {
                textFormat: Text.PlainText
                text: modelData.open ? "●" : "○"
                color: modelData.open ? panel.dim : panel.fg
                font.family: panel.fontFamily
                font.pixelSize: Style.font.caption
                Layout.preferredWidth: Style.space(10)
                horizontalAlignment: Text.AlignHCenter
              }

              Text {
                Layout.fillWidth: true
                textFormat: Text.PlainText
                text: modelData.name
                color: modelData.open ? panel.dim : panel.fg
                elide: Text.ElideMiddle
                font.family: panel.fontFamily
                font.pixelSize: Style.font.bodySmall
              }

              Text {
                textFormat: Text.PlainText
                text: modelData.elsewhere ? "open on " + Model.keyLabel(modelData.elsewhere) : (modelData.open ? "open" : "")
                color: panel.dim
                font.family: panel.fontFamily
                font.pixelSize: Style.font.caption
              }
            }
          }

          Text {
            visible: session.entry !== null && session.entry.windows.length > session.shown
            textFormat: Text.PlainText
            text: session.entry ? "+ " + (session.entry.windows.length - session.shown) + " more  ·  omaprojectspace windows" : ""
            color: panel.dim
            font.family: panel.fontFamily
            font.pixelSize: Style.font.caption
          }

          Row {
            spacing: Style.spacing.md

            Button {
              readonly property bool mine: panel.restoringId === panel.cursorId
              visible: session.entry !== null
              enabled: !session.busy && session.entry !== null && session.entry.missing > 0
              opacity: enabled || mine ? 1 : 0.45
              text: mine ? "Restoring…" : (session.entry && session.entry.missing > 0 ? "Restore " + session.entry.missing : "All open")
              iconText: ""
              iconSpinning: mine
              tooltipText: "Reopen the windows missing from workspace " + Model.keyLabel(panel.cursorId) + " (o)"
              foreground: panel.fg
              fontFamily: panel.fontFamily
              fontSize: Style.font.bodySmall
              bordered: true
              horizontalPadding: Style.space(8)
              verticalPadding: Style.space(3)
              onClicked: panel.restoreWindows(panel.cursorId)
            }

            Button {
              readonly property bool mine: panel.restoringId === 0
              visible: panel.windowsInfo.missing > (session.entry ? session.entry.missing : 0) || mine
              enabled: !session.busy
              opacity: enabled || mine ? 1 : 0.45
              text: mine ? "Restoring all…" : "Restore all " + panel.windowsInfo.missing
              iconText: ""
              iconSpinning: mine
              tooltipText: "Reopen what is missing on every workspace with saved windows (O)"
              foreground: panel.fg
              fontFamily: panel.fontFamily
              fontSize: Style.font.bodySmall
              bordered: true
              horizontalPadding: Style.space(8)
              verticalPadding: Style.space(3)
              onClicked: panel.restoreWindows(0)
            }

            // Saving replaces the workspace's setup with what is open on it now.
            Button {
              readonly property bool mine: panel.savingId === panel.cursorId
              enabled: live.entry !== null && panel.savingId < 0
              opacity: enabled || mine ? 1 : 0.45
              text: mine ? "Saving…" : (session.entry ? "Save again" : "Save")
              iconText: "\uf0c7"
              iconSpinning: mine
              tooltipText: "Save what is open on workspace " + Model.keyLabel(panel.cursorId) + " as its setup" + (session.entry ? ", replacing the saved one" : "") + " (s)"
              foreground: panel.fg
              fontFamily: panel.fontFamily
              fontSize: Style.font.bodySmall
              bordered: true
              horizontalPadding: Style.space(8)
              verticalPadding: Style.space(3)
              onClicked: panel.saveWindows(panel.cursorId)
            }

            Button {
              visible: session.entry !== null
              enabled: panel.savingId < 0
              text: "Forget"
              iconText: "\uf1f8"
              tooltipText: "Drop workspace " + Model.keyLabel(panel.cursorId) + "'s saved windows"
              foreground: panel.fg
              fontFamily: panel.fontFamily
              fontSize: Style.font.bodySmall
              bordered: true
              horizontalPadding: Style.space(8)
              verticalPadding: Style.space(3)
              onClicked: panel.forgetWindows(panel.cursorId)
            }
          }
        }
      }
    }

    PanelSeparator { foreground: panel.fg }

    // ---- reopen the saved windows at login
    Column {
      width: parent.width
      spacing: Style.spacing.rowGap

      RowLayout {
        width: parent.width
        spacing: Style.spacing.md

        Text {
          Layout.fillWidth: true
          textFormat: Text.PlainText
          text: "Reopen saved windows at login"
          color: panel.dim
          font.family: panel.fontFamily
          font.pixelSize: Style.font.bodySmall
          elide: Text.ElideRight
        }

        ToggleSwitch {
          checked: panel.restoreOnLogin
          foreground: panel.fg
          onToggled: panel.setRestoreOnLogin(!panel.restoreOnLogin)
        }
      }
    }

    PanelSeparator { foreground: panel.fg }

    Flow {
      width: parent.width
      spacing: Style.spacing.lg

      Repeater {
        model: (panel.screenTabs.length > 1 ? [["[ ]", "screen"]] : []).concat([
          ["↑↓", "pick"], ["↵", "go"], ["←→", "projectspace"], ["e", "rename"],
          ["x", "clear"], ["t", "terminal"], ["c", "config"], ["o", "restore"], ["s", "save"]
        ])

        Row {
          required property var modelData
          spacing: Style.space(4)

          Text {
            textFormat: Text.PlainText
            text: modelData[0]
            color: panel.fg
            font.family: panel.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
          }

          Text {
            textFormat: Text.PlainText
            text: modelData[1]
            color: panel.dim
            font.family: panel.fontFamily
            font.pixelSize: Style.font.caption
          }
        }
      }
    }
  }
}

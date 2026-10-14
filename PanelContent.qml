import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Model.js" as Model

// The panel's body: the ten workspaces on the left, the selected one's
// projectspace and last-session windows on the right, settings and keys
// below. Lives apart from BarWidget so a preview can render it without a
// KeyboardPanel (tests/preview).
PanelKeyCatcher {
  id: keys

  // The owning BarWidget: its state, settings and actions.
  property var panel
  anchors.fill: parent
  implicitHeight: body.implicitHeight
  // Two columns when the card has room; a narrow screen stacks them.
  readonly property bool wide: width >= Style.space(620)
  readonly property int sideWidth: wide ? Style.space(290) : width
  readonly property int mainWidth: wide ? width - sideWidth - 2 * Style.spacing.panelGap - 1 : width
  readonly property color rule: Qt.rgba(panel.fg.r, panel.fg.g, panel.fg.b, 0.12)
  blocked: panel.editingAny

  onCloseRequested: panel.close()
  onTabRequested: function(direction) { panel.switchPanel(direction) }
  onMoveRequested: function(dx, dy) {
    if (dy !== 0) panel.cursorId = Model.moveCursor(panel.cursorId, dy)
    else panel.cycleAttachment(panel.cursorId, dx)
  }
  onActivateRequested: panel.goTo(panel.cursorId)
  onDeleteRequested: panel.clearRow(panel.cursorId)
  onTextKey: function(text, modifiers) {
    var ws = Model.workspaceForKey(text)
    if (ws > 0) { panel.cursorId = ws; return }
    if (text === "O") { panel.restoreWindows(0); return }
    var key = text.toLowerCase()
    if (key === "o") panel.restoreWindows(panel.cursorId)
    else if (key === "e") panel.startRename(panel.cursorId)
    else if (key === "t") panel.openTerminal(panel.cursorId)
    else if (key === "c") panel.editConfig(panel.cursorId)
    else if (key === "s") panel.saveNow()
    else if (key === "r") panel.refresh()
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
            model: Model.WORKSPACE_IDS

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

      // ---- the selected workspace: its projectspace, its last-session windows
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

          PanelSectionHeader {
            text: "Workspace " + Model.keyLabel(panel.cursorId) + " projectspace"
            foreground: panel.fg
            fontFamily: panel.fontFamily
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

        // ---- the windows it had in the last session
        PanelSeparator {
          visible: session.visible
          foreground: panel.fg
        }

        Column {
          id: session
          width: parent.width
          spacing: Style.spacing.rowGap
          visible: panel.lastSession.workspaces.length > 0

          readonly property var entry: Model.restoreFor(panel.lastSession, panel.cursorId)
          readonly property int shown: 6
          readonly property bool busy: panel.restoringId >= 0

          RowLayout {
            width: parent.width
            spacing: Style.spacing.md

            PanelSectionHeader {
              Layout.fillWidth: true
              text: "Last session"
              foreground: panel.fg
              fontFamily: panel.fontFamily
            }

            Text {
              textFormat: Text.PlainText
              text: "saved " + Model.savedLabel(panel.lastSession.saved, Math.round(panel.now))
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
            text: "Nothing was open on workspace " + Model.keyLabel(panel.cursorId) + "."
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
              visible: panel.lastSession.missing > (session.entry ? session.entry.missing : 0) || mine
              enabled: !session.busy
              opacity: enabled || mine ? 1 : 0.45
              text: mine ? "Restoring all…" : "Restore all " + panel.lastSession.missing
              iconText: ""
              iconSpinning: mine
              tooltipText: "Reopen every missing window, each on its own workspace (O)"
              foreground: panel.fg
              fontFamily: panel.fontFamily
              fontSize: Style.font.bodySmall
              bordered: true
              horizontalPadding: Style.space(8)
              verticalPadding: Style.space(3)
              onClicked: panel.restoreWindows(0)
            }
          }
        }
      }
    }

    PanelSeparator { foreground: panel.fg }

    // ---- settings: the strip's under the workspaces, the windows' on the right
    GridLayout {
      width: parent.width
      columns: keys.wide ? 2 : 1
      columnSpacing: 2 * Style.spacing.panelGap + 1
      rowSpacing: Style.spacing.rowGap

      RowLayout {
        Layout.preferredWidth: keys.sideWidth
        Layout.alignment: Qt.AlignTop
        spacing: Style.spacing.md

        Text {
          Layout.fillWidth: true
          textFormat: Text.PlainText
          text: "Collapse strip after"
          elide: Text.ElideRight
          color: panel.dim
          font.family: panel.fontFamily
          font.pixelSize: Style.font.bodySmall
        }

        NumberField {
          foreground: panel.fg
          fontFamily: panel.fontFamily
          fontSize: Style.font.bodySmall
          fieldWidth: Style.space(80)
          value: panel.hoverOutDelayMs
          from: 0
          to: 5000
          stepSize: 50
          onModified: function(value) { panel.setHoverOutDelay(value) }
        }

        Text {
          textFormat: Text.PlainText
          text: "ms"
          color: panel.dim
          font.family: panel.fontFamily
          font.pixelSize: Style.font.bodySmall
        }
      }

      Column {
        Layout.preferredWidth: keys.mainWidth
        spacing: Style.spacing.rowGap

        RowLayout {
          width: parent.width
          spacing: Style.spacing.md

          Text {
            Layout.fillWidth: true
            textFormat: Text.PlainText
            text: "Reopen the last session's windows at login"
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

        // Auto-save runs every minute from Hyprland; this says it still does,
        // and `s` saves right now (the minute before a reboot).
        RowLayout {
          readonly property var status: Model.autosaveStatus(panel.lastSession, panel.now)
          width: parent.width
          spacing: Style.spacing.md

          Text {
            id: autosave
            Layout.fillWidth: true
            textFormat: Text.PlainText
            elide: Text.ElideRight
            text: parent.status.text
            color: parent.status.stale ? (panel.bar ? panel.bar.urgent : Commons.Color.urgent) : panel.dim
            font.family: panel.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          Button {
            text: panel.saving ? "Saving…" : "Save now"
            iconText: ""
            iconSpinning: panel.saving
            enabled: !panel.saving
            tooltipText: "Snapshot the windows on workspaces 1–10 now (s)"
            foreground: panel.fg
            fontFamily: panel.fontFamily
            fontSize: Style.font.bodySmall
            bordered: true
            horizontalPadding: Style.space(8)
            verticalPadding: Style.space(3)
            onClicked: panel.saveNow()
          }
        }
      }
    }

    PanelSeparator { foreground: panel.fg }

    Flow {
      width: parent.width
      spacing: Style.spacing.lg

      Repeater {
        model: [
          ["↑↓", "pick"], ["↵", "go"], ["←→", "projectspace"], ["e", "rename"],
          ["x", "clear"], ["t", "terminal"], ["c", "config"], ["o", "restore"], ["s", "save"]
        ]

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

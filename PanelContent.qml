import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Model.js" as Model

// The panel's body: the ten workspaces, the selected one's projectspace, and
// the keys that drive them. Lives apart from BarWidget so a preview can render
// it without a KeyboardPanel (tests/preview).
PanelKeyCatcher {
  id: keys

  // The owning BarWidget: its state, settings and actions.
  property var panel
  anchors.fill: parent
  implicitHeight: body.implicitHeight
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
    var key = text.toLowerCase()
    if (key === "e") panel.startRename(panel.cursorId)
    else if (key === "t") panel.openTerminal(panel.cursorId)
    else if (key === "c") panel.editConfig(panel.cursorId)
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

    Column {
      width: parent.width
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

    PanelSeparator { foreground: panel.fg }

    // ---- the selected row's projectspace
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
          : "No projectspaces yet: a projectspace is a folder under ~/Projects with a mise config at its panel."
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

    PanelSeparator { foreground: panel.fg }

    Flow {
      width: parent.width
      spacing: Style.spacing.lg

      Repeater {
        model: [
          ["↑↓", "pick"], ["↵", "go"], ["←→", "projectspace"], ["e", "rename"],
          ["x", "clear"], ["t", "terminal"], ["c", "config"]
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

    RowLayout {
      width: parent.width
      spacing: Style.spacing.md

      Text {
        Layout.fillWidth: true
        textFormat: Text.PlainText
        text: "Collapse the strip after"
        color: panel.dim
        font.family: panel.fontFamily
        font.pixelSize: Style.font.bodySmall
      }

      NumberField {
        foreground: panel.fg
        fontFamily: panel.fontFamily
        fontSize: Style.font.bodySmall
        fieldWidth: Style.space(96)
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
  }
}

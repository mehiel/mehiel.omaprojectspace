import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.Commons
import qs.Commons as Commons
// Makes the scanner index the copied plugin, so its files resolve their
// sibling types (see run).
import qs.plugin as Plugin

// Preview harness: the strip (hover forced on) and the panel body in an
// overlay that never takes keyboard focus, for screenshots while the real
// session keeps working. Driven by tests/preview/run.
ShellRoot {
  id: shell

  readonly property string repo: Quickshell.env("PREVIEW_REPO")
  readonly property string monitor: Quickshell.env("PREVIEW_MONITOR") || "DP-3"
  readonly property int cursor: Number(Quickshell.env("PREVIEW_CURSOR") || "7")
  // [["method", args...], ...] called on the widget once it has loaded its
  // projectspaces, to show the panel mid-interaction.
  readonly property var script: {
    try { return JSON.parse(Quickshell.env("PREVIEW_SCRIPT") || "[]") } catch (e) { return [] }
  }
  // The real panel caps its card at Style.space(780); PREVIEW_WIDTH narrows it.
  readonly property int panelWidth: Number(Quickshell.env("PREVIEW_WIDTH")) || Style.space(780)
  readonly property var settings: {
    try { return JSON.parse(Quickshell.env("PREVIEW_SETTINGS") || "{}") } catch (e) { return {} }
  }

  PanelWindow {
    screen: {
      var want = Quickshell.env("PREVIEW_SCREEN")
      for (var i = 0; i < Quickshell.screens.length; i++)
        if (Quickshell.screens[i].name === want) return Quickshell.screens[i]
      return Quickshell.screens[0]
    }
    anchors.top: true
    anchors.left: true
    margins.top: 40
    margins.left: 40
    implicitWidth: shell.panelWidth + 40
    implicitHeight: column.implicitHeight + 40
    color: Commons.Color.popups.background
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
    WlrLayershell.namespace: "omaprojectspace-preview"
    exclusionMode: ExclusionMode.Ignore

    QtObject {
      id: fakeBar
      property color foreground: Commons.Color.foreground
      property color barForeground: Commons.Color.foreground
      property color background: Commons.Color.bar.background
      property color urgent: Commons.Color.urgent
      property string fontFamily: Style.font.family
      property bool vertical: false
      property int barSize: 26
      property string position: "top"
      property var shell: null
      function run(command) { console.log("preview run: " + command) }
      function showTooltip(target, text) {}
      function hideTooltip(target) {}
      function switchPanelFrom(owner, direction) { return false }
      function requestPopout(owner) {}
      function releasePopout(owner) {}
      function registerClickTarget(target) {}
      function unregisterClickTarget(target) {}
    }

    Column {
      id: column
      x: 20
      y: 20
      width: shell.panelWidth
      spacing: 20

      Rectangle {
        width: parent.width
        height: 26
        color: Commons.Color.bar.background
        border.color: Qt.darker(Commons.Color.bar.background, 1.2)

        Loader {
          id: widget
          x: 8
          height: 26
          source: shell.repo + "/BarWidget.qml"
          onLoaded: {
            item.bar = fakeBar
            item.settings = shell.settings
            item.monitorOverride = shell.monitor
            item.areaHovered = true
            item.cursorId = shell.cursor
            scriptTimer.start()
          }
        }

        Timer {
          id: scriptTimer
          interval: 800
          onTriggered: {
            for (var i = 0; i < shell.script.length; i++) {
              var step = shell.script[i]
              widget.item[step[0]].apply(widget.item, step.slice(1))
              console.log("preview script: " + JSON.stringify(step))
            }
          }
        }
      }

      Loader {
        width: parent.width
        height: item ? item.implicitHeight : 0
        active: widget.status === Loader.Ready
        source: shell.repo + "/PanelContent.qml"
        onLoaded: item.panel = widget.item
      }
    }
  }
}

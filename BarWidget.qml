import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Model.js" as Model

// Named workspaces for the monitor this bar sits on, each optionally attached
// to a projectspace: a team folder whose mise env everything launched there
// gets (see bin/omaprojectspace and shim/uwsm-app). Collapsed to the active
// workspace; the others on this monitor reveal on hover. An attached
// workspace carries its projectspace's dot, and is named after it unless it
// has a name of its own. The panel (gear, right-click, SUPER+ALT+P) names
// workspaces, attaches them, and shows what each projectspace sets.
Panel {
  id: root

  ipcTarget: "mehiel.omaprojectspace"
  manageIpc: false

  // ---- settings
  // Custom names, keyed by workspace id as a string, persisted on this
  // widget's shell.json entry alongside hoverOutDelayMs.
  readonly property var names: root.settings && root.settings.names instanceof Object ? root.settings.names : ({})
  readonly property int hoverOutDelayMs: Math.max(0, Number(root.setting("hoverOutDelayMs", 120)))

  // updateEntryInline replaces the whole entry, so every write resends the
  // current settings in full. type/source are leftovers of the bar/modules
  // file this started as; a plugin entry must not carry them.
  function persistSettings(patch) {
    var entry = { id: root.moduleName || "mehiel.omaprojectspace" }
    var current = root.settings || {}
    for (var k in current) if (k !== "id" && k !== "type" && k !== "source") entry[k] = current[k]
    for (var p in patch) entry[p] = patch[p]
    root.settings = entry
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
      root.bar.shell.updateEntryInline(entry.id, entry)
  }

  function setName(id, value) {
    var next = {}
    for (var k in root.names) next[k] = root.names[k]
    var trimmed = String(value || "").trim()
    if (trimmed) next[String(id)] = trimmed
    else delete next[String(id)]
    root.persistSettings({ names: next })
  }

  function setHoverOutDelay(ms) {
    root.persistSettings({ hoverOutDelayMs: Math.max(0, Math.round(ms)) })
  }

  // ---- projectspaces
  // Everything about projectspaces comes from the CLI, which is also the only
  // writer of the attachments file; the widget never parses mise itself.
  readonly property string cli: String(Qt.resolvedUrl("bin/omaprojectspace")).replace(/^file:\/\//, "")
  readonly property string home: Quickshell.env("HOME")
  readonly property string configHome: Quickshell.env("XDG_CONFIG_HOME") || (home + "/.config")
  readonly property string attachmentsPath: (Quickshell.env("OMAPROJECTSPACE_CONFIG_DIR") || (configHome + "/omaprojectspace")) + "/attachments.json"

  property var spaces: Model.parseList("")
  property bool listQueued: false

  function refresh() {
    if (listProc.running) { listQueued = true; return }
    listProc.running = true
  }

  // A run that failed or was cut short keeps the last good state on screen.
  Process {
    id: listProc
    command: [root.cli, "list", "--json"]
    stdout: StdioCollector {
      onStreamFinished: {
        if (text.indexOf("\"projectspaces\"") !== -1) root.spaces = Model.parseList(text)
        if (!root.listQueued) return
        root.listQueued = false
        Qt.callLater(root.refresh)
      }
    }
  }

  // CLI calls that change something run one at a time, in order, and the
  // list refreshes after the last one.
  property var pendingRuns: []

  function runCli(args) {
    pendingRuns = pendingRuns.concat([[root.cli].concat(args)])
    if (!actionProc.running) runNext()
  }

  function runArgv(argv) {
    pendingRuns = pendingRuns.concat([argv])
    if (!actionProc.running) runNext()
  }

  function runNext() {
    if (pendingRuns.length === 0) { refresh(); return }
    actionProc.command = pendingRuns[0]
    pendingRuns = pendingRuns.slice(1)
    actionProc.running = true
  }

  Process {
    id: actionProc
    onExited: Qt.callLater(root.runNext)
  }

  function attach(id, homePath) {
    root.spaces = Model.withAttachment(root.spaces, id, homePath)
    if (homePath) runCli(["attach", String(id), homePath])
    else runCli(["detach", String(id)])
  }

  function cycleAttachment(id, step) {
    attach(id, Model.cycleAttachment(root.spaces, id, step))
  }

  // x takes off one layer at a time: the projectspace, then the custom name.
  function clearRow(id) {
    if (Model.projectspaceFor(root.spaces, id)) attach(id, "")
    else if (root.names[String(id)]) setName(id, "")
  }

  function trust(projectspace) {
    if (!projectspace || !projectspace.config) return
    runArgv(["mise", "trust", projectspace.config])
  }

  // The new window lands on the active workspace; the env and folder are the
  // chosen workspace's.
  function openTerminal(id) {
    var p = Model.projectspaceFor(root.spaces, id)
    if (!p || p.missing) return
    Util.execArgv(["env", "OMAPROJECTSPACE_WORKSPACE=" + id, "uwsm-app", "--", "xdg-terminal-exec", "--dir=" + p.home])
    root.close()
  }

  function editConfig(id) {
    var p = Model.projectspaceFor(root.spaces, id)
    if (!p || !p.config) return
    Util.execArgv(["omarchy-launch-editor", p.config])
    root.close()
  }

  // Picks up `omaprojectspace attach` from a terminal too. The CLI also pokes
  // the focused bar over IPC; this covers the other monitors.
  FileView {
    path: root.attachmentsPath
    watchChanges: true
    printErrors: false
    onFileChanged: root.refresh()
  }

  // mise configs change by hand; a slow tick keeps colors and env current
  // without anyone opening the panel.
  Timer {
    interval: 600000
    running: true
    repeat: true
    onTriggered: root.refresh()
  }

  Component.onCompleted: refresh()

  // ---- monitor and workspaces
  // One bar surface per output. QsWindow is this instance's PanelWindow;
  // Hyprland.monitorFor maps it onto the compositor monitor by name.
  readonly property var barWindow: root.QsWindow ? root.QsWindow.window : null
  readonly property var screen: barWindow ? barWindow.screen : null
  // Set only by the preview harness, to show another monitor's workspaces.
  property string monitorOverride: ""
  readonly property string screenName: monitorOverride !== "" ? monitorOverride : (screen ? String(screen.name || "") : "")
  readonly property var hyprMonitor: {
    if (screen && monitorOverride === "") {
      var matched = Hyprland.monitorFor(screen)
      if (matched) return matched
    }
    var values = Hyprland.monitors.values
    for (var i = 0; i < values.length; i++)
      if (values[i].name === screenName) return values[i]
    return null
  }
  readonly property int monitorActiveId: hyprMonitor && hyprMonitor.activeWorkspace ? hyprMonitor.activeWorkspace.id : -1
  // Only the focused monitor's instance answers IPC, so SUPER+ALT+P opens the
  // panel where you are.
  readonly property bool onFocusedMonitor: Hyprland.focusedMonitor !== null && Hyprland.focusedMonitor.name === screenName

  function workspaceById(id) {
    var values = Hyprland.workspaces.values
    for (var i = 0; i < values.length; i++)
      if (values[i].id === id) return values[i]
    return null
  }

  function windowCount(id) {
    var w = workspaceById(id)
    return w ? w.toplevels.values.length : 0
  }

  function workspaceMonitorName(workspace) {
    if (!workspace) return ""
    if (workspace.monitor && workspace.monitor.name) return String(workspace.monitor.name)
    // Quickshell sometimes leaves .monitor unset on a non-active workspace;
    // the IPC snapshot still has the connector name.
    var ipc = workspace.lastIpcObject
    if (ipc && ipc.monitor) return String(ipc.monitor)
    return ""
  }

  function onThisMonitor(workspace) {
    if (!workspace) return false
    // Until the layer surface has a screen, don't hide the strip.
    if (!screenName) return true
    var name = workspaceMonitorName(workspace)
    if (name) return name === screenName
    if (hyprMonitor && workspace.monitor === hyprMonitor) return true
    return workspace.id === monitorActiveId
  }

  readonly property var ids: {
    // Reading these makes a workspace moving monitors, or this output's
    // active workspace changing, rebuild the list.
    var _active = monitorActiveId
    var _monitors = Hyprland.monitors.values
    var values = Hyprland.workspaces.values
    var snapshot = []
    for (var i = 0; i < values.length; i++) {
      var w = values[i]
      if (!w) continue
      var _ipc = w.lastIpcObject
      snapshot.push({
        id: w.id,
        monitor: root.onThisMonitor(w) ? root.screenName : "\u0000elsewhere",
        windows: w.toplevels.values.length
      })
    }
    return Model.stripIds(snapshot, screenName, monitorActiveId)
  }

  // The active workspace holds the collapsed slot. When it is a special one
  // the strip does not list, the lowest listed one stands in.
  readonly property int primaryId: ids.indexOf(monitorActiveId) !== -1 ? monitorActiveId : (ids.length > 0 ? ids[0] : -1)
  readonly property var otherIds: ids.filter(function(id) { return id !== root.primaryId })

  // Quattro's dispatch takes Lua; the classic `dispatch workspace N` is a
  // parse error. Same call the stock Workspaces widget makes.
  function focusWorkspace(id) {
    if (root.bar) root.bar.run("hyprctl dispatch 'hl.dsp.focus({ workspace = \"" + id + "\" })'")
  }

  function goTo(id) {
    focusWorkspace(id)
    root.close()
  }

  function tooltipFor(id) {
    var p = Model.projectspaceFor(root.spaces, id)
    var head = Model.labelFor(id, root.names, root.spaces)
    var windows = Model.windowsLabel(root.windowCount(id))
    if (!p) return head + "  ·  " + windows
    var lines = [head + "  ·  " + windows, p.display || Model.tildify(p.home, root.home)]
    if (p.name !== head) lines[0] = head + "  ·  " + p.name + "  ·  " + windows
    if (!p.ok) lines.push(p.missing ? "Folder is gone" : "mise: " + p.error)
    return lines.join("\n")
  }

  // ---- strip hover
  // Two hover sources: the module as a whole, and the individual labels. A
  // label exit only arms the grace timer, and the timer gives up on it if
  // the pointer is still over the module, so walking slowly across the gap
  // between two labels never collapses the strip under the cursor.
  property bool areaHovered: false
  property bool labelHovered: false
  readonly property bool hovered: areaHovered || labelHovered
  readonly property bool revealOthers: (hovered || root.opened) && otherIds.length > 0
  readonly property bool revealSettings: hovered || root.opened

  function setAreaHovered(isHovered) {
    areaHovered = isHovered
    if (isHovered) hideTimer.stop()
    else hideTimer.restart()
  }

  function setLabelHovered(isHovered) {
    if (isHovered) { labelHovered = true; hideTimer.stop() }
    else hideTimer.restart()
  }

  Timer {
    id: hideTimer
    interval: root.hoverOutDelayMs
    onTriggered: if (!root.areaHovered) root.labelHovered = false
  }

  HoverHandler {
    onHoveredChanged: root.setAreaHovered(hovered)
  }

  // ---- look
  readonly property bool vertical: bar && bar.vertical
  readonly property int barSize: bar ? bar.barSize : 26
  readonly property color fg: bar ? bar.foreground : Commons.Color.foreground
  readonly property color dim: Qt.darker(fg, 1.5)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  // Same token the clock label uses, so both track shell.toml's font base-size.
  readonly property int fontSize: Style.font.body
  readonly property int gap: 6

  implicitWidth: vertical ? barSize : stripRow.implicitWidth + 4
  implicitHeight: vertical ? stripColumn.implicitHeight + 4 : barSize

  component StripLabel: Item {
    id: label

    property int workspaceId: -1

    readonly property var projectspace: Model.projectspaceFor(root.spaces, workspaceId)
    readonly property bool focused: workspaceId === root.primaryId
    readonly property bool occupied: root.windowCount(workspaceId) > 0

    implicitWidth: root.vertical ? content.implicitHeight : content.implicitWidth
    implicitHeight: root.vertical ? content.implicitWidth : content.implicitHeight

    Row {
      id: content
      anchors.centerIn: parent
      spacing: Style.space(5)
      rotation: root.vertical ? -90 : 0

      ProjectspaceDot {
        visible: label.projectspace !== null
        anchors.verticalCenter: parent.verticalCenter
        color: label.projectspace ? label.projectspace.color : "transparent"
        icon: label.projectspace ? label.projectspace.icon : ""
        hollow: label.projectspace ? !label.projectspace.ok : false
        size: Style.space(6)
        opacity: label.focused ? 1 : 0.8
        fontFamily: root.fontFamily
        glyphSize: root.fontSize
      }

      Text {
        anchors.verticalCenter: parent.verticalCenter
        textFormat: Text.PlainText
        text: Model.labelFor(label.workspaceId, root.names, root.spaces)
        color: root.fg
        opacity: label.focused ? 1 : (label.occupied ? 0.85 : 0.5)
        font.family: root.fontFamily
        font.pixelSize: root.fontSize
        font.bold: label.focused
        // Native hinting matches the clock label, but it ignores the rotation
        // the vertical bar needs.
        renderType: root.vertical ? Text.QtRendering : Text.NativeRendering
      }
    }

    MouseArea {
      anchors.fill: parent
      // Half a gap on each side, so neighbouring labels' hit areas meet and
      // the pointer never crosses a dead strip on its way across.
      anchors.margins: -root.gap / 2
      acceptedButtons: Qt.LeftButton | Qt.RightButton
      cursorShape: Qt.PointingHandCursor
      hoverEnabled: true
      onEntered: {
        root.setLabelHovered(true)
        if (root.bar) root.bar.showTooltip(label, root.tooltipFor(label.workspaceId))
      }
      onExited: {
        root.setLabelHovered(false)
        if (root.bar) root.bar.hideTooltip(label)
      }
      onClicked: function(mouse) {
        if (root.bar) root.bar.hideTooltip(label)
        if (mouse.button === Qt.RightButton) root.openAt(label.workspaceId)
        else root.focusWorkspace(label.workspaceId)
      }
    }
  }

  Row {
    id: stripRow
    visible: !root.vertical
    anchors.top: parent.top
    anchors.bottom: parent.bottom
    spacing: 0

    StripLabel {
      visible: root.primaryId > 0
      height: stripRow.height
      workspaceId: root.primaryId
    }

    // Collapses to zero width instead of hiding, so the labels inside keep
    // their layout and are simply clipped away while the module is idle.
    Item {
      width: root.revealOthers ? othersRow.implicitWidth : 0
      height: stripRow.height
      clip: true

      Behavior on width { NumberAnimation { duration: Style.duration(120); easing.type: Easing.OutCubic } }

      Row {
        id: othersRow
        height: parent.height
        spacing: root.gap
        // The leading gap lives inside the clipped area, so the collapsed
        // module has no trailing whitespace and every gap is the same width.
        leftPadding: root.gap

        Repeater {
          model: root.otherIds

          StripLabel {
            required property int modelData
            height: othersRow.height
            workspaceId: modelData
          }
        }
      }
    }

    // Takes bar space only while it shows, like the labels above.
    Item {
      width: root.revealSettings ? gearH.implicitWidth + root.gap : 0
      height: stripRow.height
      clip: true

      BarIconButton {
        id: gearH
        x: root.gap
        width: implicitWidth
        height: implicitHeight
        bar: root.bar
        text: ""
        tooltipText: "Projectspaces (Super+Alt+P)"
        fixedWidth: Style.bar.iconSlot
        fixedHeight: stripRow.height
        onPressed: function() { root.toggle() }
      }
    }
  }

  Column {
    id: stripColumn
    visible: root.vertical
    anchors.horizontalCenter: parent.horizontalCenter
    spacing: 0

    StripLabel {
      visible: root.primaryId > 0
      anchors.horizontalCenter: parent.horizontalCenter
      workspaceId: root.primaryId
    }

    Item {
      width: stripColumn.width
      height: root.revealOthers ? othersColumn.implicitHeight : 0
      clip: true

      Column {
        id: othersColumn
        width: parent.width
        spacing: root.gap + 2
        topPadding: root.gap + 2

        Repeater {
          model: root.otherIds

          StripLabel {
            required property int modelData
            anchors.horizontalCenter: parent.horizontalCenter
            workspaceId: modelData
          }
        }
      }
    }

    Item {
      width: stripColumn.width
      height: root.revealSettings ? gearV.implicitHeight + root.gap : 0
      clip: true

      BarIconButton {
        id: gearV
        anchors.horizontalCenter: parent.horizontalCenter
        y: root.gap
        width: implicitWidth
        height: implicitHeight
        bar: root.bar
        text: ""
        tooltipText: "Projectspaces (Super+Alt+P)"
        fixedWidth: root.barSize
        fixedHeight: Style.bar.iconSlot
        onPressed: function() { root.toggle() }
      }
    }
  }

  // ---- panel state
  // The row under the keyboard/mouse cursor, and the row being renamed.
  property int cursorId: 1
  property int editingId: -1
  readonly property bool editingAny: editingId > 0

  readonly property var cursorProjectspace: Model.projectspaceFor(root.spaces, cursorId)
  readonly property var activeProjectspace: Model.projectspaceFor(root.spaces, monitorActiveId)

  function openAt(id) {
    cursorId = id
    cursorPinned = true
    if (!opened) open()
  }

  function startRename(id) {
    cursorId = id
    editingId = id
  }

  function endRename() {
    editingId = -1
    Qt.callLater(function() { if (panel.loadedContent) panel.loadedContent.forceActiveFocus() })
  }

  onOpenedChanged: {
    if (opened) {
      panel.ensureContent()
      editingId = -1
      if (!cursorPinned) cursorId = monitorActiveId > 0 && monitorActiveId <= 10 ? monitorActiveId : 1
      cursorPinned = false
      refresh()
    } else {
      editingId = -1
    }
  }
  // Set by a right-click on a strip label, so opening lands on that row.
  property bool cursorPinned: false

  ShellIpc {
    target: root.ipcTarget
    enabled: root.onFocusedMonitor
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { root.refresh(); return "ok" }
    // What the bar knows, for scripts and for checking it from a terminal.
    function state(): string {
      return JSON.stringify({ monitor: root.screenName, active: root.monitorActiveId, strip: root.ids, attachments: root.spaces.attachments, projectspaces: root.spaces.projectspaces.map(function(p) { return p.name }) })
    }
  }

  // ---- panel
  KeyboardPanel {
    id: panel
    anchorItem: root
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: panel.loadedContent
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(panel.loadedContentHeight, Style.space(960))

    content: PanelContent {
      panel: root
    }
  }
}

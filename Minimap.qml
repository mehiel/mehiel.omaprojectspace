import QtQuick
import QtQuick.Shapes
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import qs.Commons
import qs.Commons as Commons
import "Minimap.js" as Mini

// The active workspace's windows as a row of boxes beside its label: each box
// keeps its window's proportions, in the scrolling layout's column order,
// stacked windows split their column and a tabbed group gets a tab bar. The
// focused box is accent-filled, one scrolled off screen is dimmed. Boxes move
// on springs as windows open, close and resize, and hovering one (or focusing
// a window) pops a tab out of the bar naming it. An urgent window turns amber
// until it is focused.
//
// After jgarza's Minimap plugin (github.com/jgarza9788/minimap, MIT).
Item {
  id: root

  property var bar: null
  property var monitor: null              // the HyprlandMonitor this bar sits on
  property int workspaceId: -1
  property bool vertical: false
  property int barSize: 26
  property color fg: Commons.Color.foreground
  property string fontFamily: Style.font.family
  property int maxLength: 480
  property bool showFloating: false
  property bool reduceMotion: false
  // Set while the strip's panel is open, so the name tab stays out of its way.
  property bool suppressLabel: false
  // What the CLI calls each open window ({ address: { name, kind } }), the
  // way the panel lists them: "Browser", "Slack", "Terminal"... A window it
  // has not seen yet asks for a fresh read with namesWanted().
  property var appNames: ({})
  // Also pop the tab up for a moment when focus moves to a window here.
  property bool peekOnFocus: false
  signal namesWanted()

  // ---- look
  readonly property color accent: Commons.Color.accent
  readonly property color muted: Commons.Color.muted
  readonly property color bg: Commons.Color.background
  readonly property color warn: "#f2b134"
  // Three steps of one colour: the focused window in the accent, its
  // neighbours on screen in the accent eased toward the background (lighter on
  // a light theme, deeper on a dark one), and windows scrolled off screen
  // faintest, in muted.
  readonly property color neighbor: Qt.tint(accent, Qt.rgba(bg.r, bg.g, bg.b, 0.2))
  readonly property real thickness: Math.max(8, Math.round(barSize * 0.62))
  readonly property int gap: 3

  // Calm springs and a soft swell; reduce motion damps them critically.
  readonly property real springK: reduceMotion ? 4.0 : 3.0
  readonly property real springD: reduceMotion ? 1.0 : 0.70
  readonly property real popTo: reduceMotion ? 1.0 : 1.18
  readonly property real hoverScale: reduceMotion ? 1.03 : 1.08

  // ---- data
  property int tick: 0
  readonly property var monitorRect: {
    var _t = tick
    var m = monitor
    if (!m) return null
    var ipc = m.lastIpcObject || {}
    var s = Number(m.scale || ipc.scale) || 1
    var w = Number(m.width || ipc.width) / s, h = Number(m.height || ipc.height) / s
    var x = Number(m.x !== undefined ? m.x : ipc.x) || 0, y = Number(m.y !== undefined ? m.y : ipc.y) || 0
    return w > 0 && h > 0 ? { x: x, y: y, width: w, height: h } : null
  }
  // The focused window: Hyprland's activewindowv2 event says so at once, and
  // each `hyprctl clients` read (focus history 0) confirms it.
  // Hyprland.activeToplevel is not used: after a shell restart it can name
  // no window, or a stale one, until focus moves.
  property string activeAddr: ""

  readonly property var rawColumns: {
    var _t = tick
    if (workspaceId < 0 || !monitorRect) return []
    var tops = Hyprland.toplevels ? Hyprland.toplevels.values : []
    return Mini.buildColumns(Mini.eligibleClients(tops, workspaceId, showFloating, liveAddrs), monitorRect, vertical, activeAddr)
  }
  // Swapped only when what is drawn changes, so boxes keep their hover state
  // through the polling.
  property var columns: []
  property string columnsSig: ""
  onRawColumnsChanged: {
    var sig = JSON.stringify(rawColumns)
    if (sig === columnsSig) return
    columnsSig = sig
    columns = rawColumns
  }

  // Quickshell can keep a toplevel for a closed window; `hyprctl clients` is
  // the truth. Null until the first read.
  property var liveAddrs: null
  Process {
    id: liveClients
    command: ["hyprctl", "clients", "-j"]
    stdout: StdioCollector {
      onStreamFinished: {
        var list = null
        try { list = JSON.parse(text) } catch (e) { return }
        if (!Array.isArray(list)) return
        var live = {}
        var focused = ""
        for (var i = 0; i < list.length; i++) {
          live[Mini.normalizeAddress(list[i].address)] = true
          if (list[i].focusHistoryID === 0) focused = Mini.normalizeAddress(list[i].address)
        }
        root.liveAddrs = live
        root.activeAddr = focused
      }
    }
  }

  function bump() {
    if (!liveClients.running) liveClients.running = true
    Hyprland.refreshToplevels()
    Hyprland.refreshMonitors()
    tick = (tick + 1) & 0x3fffffff
  }

  Connections {
    target: Hyprland
    enabled: root.visible
    function onRawEvent(event) {
      var n = String(event.name || "")
      if (n === "activewindowv2") {
        root.activeAddr = Mini.normalizeAddress(event.data)
        root.peek(root.activeAddr)
      }
      if (n === "urgent") root.raiseAlert(Mini.urgentAddress(event.data))
      if (n.indexOf("window") !== -1 || n.indexOf("workspace") !== -1 || n.indexOf("monitor") !== -1
          || n === "changefloatingmode" || n === "fullscreen" || n === "pin") {
        root.bump()
        burst.count = 0
        burst.restart()
      }
    }
  }
  // Follows the layout's scroll animation to where it settles.
  Timer {
    id: burst
    interval: 180
    repeat: true
    property int count: 0
    onTriggered: { root.bump(); if (++count >= 8) stop() }
  }
  // Scrolling the layout with a plain bind raises no event.
  Timer { interval: 2500; running: root.visible; repeat: true; onTriggered: root.bump() }

  // The window `step` boxes from the focused one, in the order drawn (a
  // group counts once, as its shown tab). Stops at either end.
  function stepFocus(step) {
    var items = tape.items
    if (items.length === 0) return
    var at = -1
    for (var i = 0; i < items.length; i++) if (items[i].focused) { at = i; break }
    var next = at < 0 ? (step > 0 ? 0 : items.length - 1) : Math.max(0, Math.min(items.length - 1, at + step))
    if (next === at) return
    focusWindow(items[next].address)
  }

  // Focus without moving the pointer: Hyprland warps it onto the window it
  // focuses, which would pull it off the minimap mid-scroll. no_warps is on
  // just for this dispatch, then back to what it was.
  property bool noWarps: false
  Process {
    command: ["hyprctl", "getoption", "cursor:no_warps", "-j"]
    running: true
    stdout: StdioCollector {
      onStreamFinished: { try { root.noWarps = JSON.parse(text).bool === true } catch (e) {} }
    }
  }

  function focusWindow(address) {
    address = Mini.normalizeAddress(address)
    if (!address) return
    Quickshell.execDetached(["hyprctl", "eval",
      "hl.config({ cursor = { no_warps = true } }); "
      + "hl.dispatch(hl.dsp.focus({ window = \"address:" + address + "\" })); "
      + "hl.config({ cursor = { no_warps = " + root.noWarps + " } })"])
  }

  // ---- attention: urgent windows, until focused
  property var alerts: ({})
  function raiseAlert(address) {
    if (!address || address === activeAddr) return
    var next = Object.assign({}, alerts)
    next[address] = true
    alerts = next
  }
  onActiveAddrChanged: {
    if (alerts[activeAddr]) {
      var next = Object.assign({}, alerts)
      delete next[activeAddr]
      alerts = next
    }
  }
  // Alerts by row key, so a group lights up for any of its tabs.
  readonly property var alertKeys: {
    var out = {}
    for (var a in alerts) {
      var k = Mini.keyFor(columns, a)
      if (k) out[k] = true
    }
    return out
  }

  // ---- layout
  readonly property real scale: monitorRect ? thickness / (vertical ? monitorRect.width : monitorRect.height) : 0
  readonly property var tape: Mini.layoutTape(columns, { scale: scale, gap: gap, stackGap: gap, vertical: vertical })
  property real tapeTotal: 0
  readonly property real viewLen: Math.min(tapeTotal, maxLength)
  readonly property real maxScroll: Math.max(0, tapeTotal - viewLen)
  property real scrollTarget: 0
  property real scrollOff: scrollTarget
  Behavior on scrollOff { SpringAnimation { spring: root.springK; damping: root.springD; epsilon: 0.2 } }

  // Past maxLength the row scrolls to keep the focused box in view.
  function updateScroll() {
    var target = Math.max(0, Math.min(scrollTarget, maxScroll))
    var items = tape.items
    for (var i = 0; i < items.length; i++) {
      if (!items[i].focused) continue
      var s = vertical ? items[i].by : items[i].bx
      var e = s + (vertical ? items[i].bh : items[i].bw)
      if (s - thickness < target) target = s - thickness
      else if (e + thickness > target + viewLen) target = e + thickness - viewLen
      break
    }
    scrollTarget = Math.max(0, Math.min(target, maxScroll))
  }
  onMaxScrollChanged: updateScroll()

  // Boxes live in a ListModel reconciled by key, so each keeps its delegate
  // and glides; a closed one lingers while it shrinks away.
  ListModel { id: rows }
  property string tapeSig: ""
  property bool settled: false

  function rowIndex(key) {
    for (var i = 0; i < rows.count; i++) if (rows.get(i).key === key) return i
    return -1
  }

  function syncRows() {
    var items = tape.items
    var sig = JSON.stringify(items)
    if (sig === tapeSig) return
    tapeSig = sig
    tapeTotal = tape.total
    updateScroll()
    var seen = {}
    for (var i = 0; i < items.length; i++) {
      var it = items[i]
      seen[it.key] = true
      var idx = rowIndex(it.key)
      if (idx < 0) {
        var row = Object.assign({ closing: false, closedAt: 0, fresh: settled }, it)
        rows.append(row)
      } else {
        var cur = rows.get(idx)
        for (var f in it) if (cur[f] !== it[f]) rows.setProperty(idx, f, it[f])
        if (cur.closing) rows.setProperty(idx, "closing", false)
      }
    }
    var any = false
    for (var r = 0; r < rows.count; r++) {
      if (!seen[rows.get(r).key] && !rows.get(r).closing) {
        rows.setProperty(r, "closing", true)
        rows.setProperty(r, "closedAt", Date.now())
      }
      if (rows.get(r).closing) any = true
    }
    if (any) reaper.restart()
  }
  onTapeChanged: syncRows()
  Component.onCompleted: { bump(); syncRows() }
  Timer { interval: 1200; running: true; onTriggered: root.settled = true }

  Timer {
    id: reaper
    interval: 480
    onTriggered: {
      var keep = false
      for (var i = rows.count - 1; i >= 0; i--) {
        var row = rows.get(i)
        if (!row.closing) continue
        if (Date.now() - row.closedAt >= 420) rows.remove(i)
        else keep = true
      }
      if (keep) restart()
    }
  }

  // The widget's length follows the tape on a spring, so the bar's other
  // modules glide instead of jumping.
  property real animLen: rows.count > 0 ? viewLen : 0
  Behavior on animLen { SpringAnimation { spring: root.springK; damping: root.springD; epsilon: 0.2 } }
  implicitWidth: vertical ? barSize : animLen
  implicitHeight: vertical ? animLen : thickness

  // ---- the tape
  Item {
    id: viewport
    anchors.centerIn: parent
    width: root.vertical ? root.thickness : root.animLen
    height: root.vertical ? root.animLen : root.thickness
    clip: true

    // The wheel steps focus through the windows in the order drawn; a
    // touchpad's many small deltas add up to one step per notch.
    WheelHandler {
      acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
      property real acc: 0
      onWheel: function(event) {
        var d = event.angleDelta.y !== 0 ? event.angleDelta.y : -event.angleDelta.x
        if (event.inverted) d = -d
        acc += d
        while (Math.abs(acc) >= 120) {
          root.stepFocus(acc > 0 ? -1 : 1)
          acc -= acc > 0 ? 120 : -120
        }
        event.accepted = true
      }
    }

    Item {
      id: tapeItem
      x: root.vertical ? 0 : -root.scrollOff
      y: root.vertical ? -root.scrollOff : 0
      width: root.vertical ? root.thickness : root.tapeTotal
      height: root.vertical ? root.tapeTotal : root.thickness

      Repeater {
        model: rows

        Rectangle {
          id: box
          required property string key
          required property string address
          required property real bx
          required property real by
          required property real bw
          required property real bh
          required property bool focused
          required property bool onScreen
          required property bool floating
          required property bool fullscreen
          required property bool pinned
          required property string tabsJson
          required property bool closing
          required property bool fresh

          readonly property var tabs: tabsJson !== "" ? JSON.parse(tabsJson) : []
          readonly property bool alerting: root.alertKeys[key] === true && !focused
          readonly property bool hot: root.hoverAddr !== "" && !closing && (root.hoverAddr === address
            || tabs.some(function(t) { return t.address === root.hoverAddr }))
          // Dark marks on a light box, light marks on a dark one.
          readonly property color ink: (0.299 * color.r + 0.587 * color.g + 0.114 * color.b) > 0.45 ? root.bg : root.fg

          x: bx
          y: by
          width: bw
          height: bh
          Behavior on x { SpringAnimation { spring: root.springK; damping: root.springD; epsilon: 0.2 } }
          Behavior on y { SpringAnimation { spring: root.springK; damping: root.springD; epsilon: 0.2 } }
          Behavior on width { SpringAnimation { spring: root.springK; damping: root.springD; epsilon: 0.2 } }
          Behavior on height { SpringAnimation { spring: root.springK; damping: root.springD; epsilon: 0.2 } }

          // Grows in on open, shrinks away on close; swells on focus; lifts on hover.
          property bool arrived: !fresh
          property real appear: closing || !arrived ? 0 : 1
          Behavior on appear { SpringAnimation { spring: root.springK; damping: root.springD; epsilon: 0.002 } }
          property real pop: 1
          property real lift: hot ? root.hoverScale : 1
          Behavior on lift { SpringAnimation { spring: 4; damping: 0.45; epsilon: 0.002 } }
          scale: Math.max(0.001, appear * pop * lift)

          radius: 2
          property real pulse: 0
          SequentialAnimation on pulse {
            running: box.alerting && !root.reduceMotion
            loops: Animation.Infinite
            NumberAnimation { to: 1; duration: 700; easing.type: Easing.InOutSine }
            NumberAnimation { to: 0; duration: 700; easing.type: Easing.InOutSine }
            onStopped: box.pulse = 0
          }
          readonly property color baseFill: focused ? root.accent : (onScreen ? root.neighbor : root.muted)
          color: alerting ? Qt.lighter(root.warn, 1 + 0.3 * pulse) : baseFill
          opacity: Math.min(1, appear * 1.8) * (focused || alerting || onScreen ? 1 : (hot ? 0.95 : 0.4))
          Behavior on color { enabled: !box.alerting; ColorAnimation { duration: 260; easing.type: Easing.InOutSine } }
          Behavior on opacity { NumberAnimation { duration: 220; easing.type: Easing.InOutSine } }

          onFocusedChanged: if (focused && root.settled && arrived) focusPop.restart()
          SequentialAnimation {
            id: focusPop
            NumberAnimation { target: box; property: "pop"; to: root.popTo; duration: 120; easing.type: Easing.OutSine }
            NumberAnimation { target: box; property: "pop"; to: 1; duration: 520; easing.type: Easing.OutBack; easing.overshoot: 1.4 }
          }

          // A soft halo while alerting.
          Rectangle {
            anchors.fill: parent
            anchors.margins: -2 - 2 * box.pulse
            radius: box.radius + 2
            color: "transparent"
            border.width: 1
            border.color: root.warn
            opacity: box.alerting ? 0.35 + 0.4 * box.pulse : 0
            visible: opacity > 0.01
          }

          // Floating: an outline; pinned: a dot; fullscreen: corner brackets.
          Rectangle {
            visible: box.floating && !box.closing
            anchors.fill: parent
            anchors.margins: 1
            radius: 1
            color: "transparent"
            border.width: 1
            border.color: box.ink
            opacity: 0.7
          }
          Rectangle {
            visible: box.pinned && !box.closing
            width: 3; height: 3; radius: 1.5
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.margins: 2
            color: box.ink
          }
          Repeater {
            model: box.fullscreen && !box.closing ? 4 : 0
            Item {
              id: corner
              required property int index
              readonly property bool atRight: index % 2 === 1
              readonly property bool atBottom: index >= 2
              width: 4; height: 4
              x: atRight ? box.width - width - 1 : 1
              y: atBottom ? box.height - height - 1 : 1
              Rectangle { width: corner.width; height: 1; y: corner.atBottom ? corner.height - 1 : 0; color: box.ink }
              Rectangle { width: 1; height: corner.height; x: corner.atRight ? corner.width - 1 : 0; color: box.ink }
            }
          }

          // A tabbed group: one nub per tab along the top, the shown one solid.
          Row {
            id: tabRow
            visible: box.tabs.length > 1
            x: 2
            y: 2
            spacing: 1
            readonly property real nubW: box.tabs.length > 0 ? (box.width - 4 - (box.tabs.length - 1)) / box.tabs.length : 0

            Repeater {
              model: box.tabs.length > 1 ? box.tabs : []

              Rectangle {
                id: nub
                required property var modelData
                width: Math.max(1, tabRow.nubW)
                height: Math.max(3, Math.round(box.height * 0.3))
                radius: height / 2.5
                color: box.ink
                opacity: modelData.active ? 0.9 : 0.3
                Behavior on opacity { NumberAnimation { duration: 260; easing.type: Easing.InOutSine } }

                Component.onCompleted: root.registerItem(modelData.address, nub, 1)
                Component.onDestruction: root.unregisterItem(modelData.address, nub)

                MouseArea {
                  anchors.fill: parent
                  anchors.margins: -1
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  enabled: !box.closing
                  onClicked: root.focusWindow(nub.modelData.address)
                  onEntered: root.hoverEntered(nub.modelData.address)
                  onExited: root.hoverLeft(nub.modelData.address)
                }
              }
            }
          }

          property string regAddr: ""
          function reg() {
            if (regAddr === address) return
            if (regAddr !== "") root.unregisterItem(regAddr, box)
            regAddr = address
            root.registerItem(address, box, 0)
          }
          onAddressChanged: reg()
          Component.onCompleted: { reg(); Qt.callLater(function() { box.arrived = true }) }
          Component.onDestruction: {
            try { if (regAddr !== "") root.unregisterItem(regAddr, box); root.hoverLeft(regAddr) } catch (e) {}
          }

          MouseArea {
            anchors.fill: parent
            z: -1
            hoverEnabled: true
            enabled: !box.closing
            cursorShape: Qt.PointingHandCursor
            onClicked: root.focusWindow(box.address)
            onEntered: root.hoverEntered(box.address)
            onExited: root.hoverLeft(box.address)
          }
        }
      }
    }

    // More windows past an edge: a breathing accent line on that edge.
    Repeater {
      model: [false, true]
      Item {
        id: glow
        required property bool modelData
        readonly property bool lit: modelData ? root.scrollOff < root.maxScroll - 1 : root.scrollOff > 1
        z: 100
        opacity: lit ? 1 : 0
        visible: opacity > 0.01
        Behavior on opacity { NumberAnimation { duration: 220; easing.type: Easing.InOutSine } }
        readonly property real size: Math.max(8, root.thickness * 0.6)
        x: root.vertical ? 0 : (modelData ? parent.width - width : 0)
        y: root.vertical ? (modelData ? parent.height - height : 0) : 0
        width: root.vertical ? parent.width : size
        height: root.vertical ? size : parent.height
        property real breathe: 0.6
        SequentialAnimation on breathe {
          running: glow.lit && !root.reduceMotion
          loops: Animation.Infinite
          NumberAnimation { to: 1; duration: 900; easing.type: Easing.InOutSine }
          NumberAnimation { to: 0.5; duration: 900; easing.type: Easing.InOutSine }
        }
        Rectangle {
          anchors.fill: parent
          opacity: glow.breathe * 0.7
          gradient: Gradient {
            orientation: root.vertical ? Gradient.Vertical : Gradient.Horizontal
            GradientStop { position: 0; color: glow.modelData ? "transparent" : root.accent }
            GradientStop { position: 1; color: glow.modelData ? root.accent : "transparent" }
          }
        }
      }
    }
  }

  // Whether the bar is glassy: Omarchy keeps the toggle as the Hyprland file
  // that blurs behind the bar (omarchy-bar's sync_glass); the bar API does
  // not say. hypr/omaprojectspace.lua blurs behind this tab by the same file.
  property bool glassy: false
  FileView {
    path: (Quickshell.env("XDG_STATE_HOME") || (Quickshell.env("HOME") + "/.local/state")) + "/omarchy/toggles/hypr/bar-glassy.lua"
    watchChanges: true
    printErrors: false
    onLoaded: root.glassy = true
    onLoadFailed: root.glassy = false
    onFileChanged: reload()
  }

  // ---- the name tab
  // Hovering a box, or a window taking focus, pops a tab out of the bar's
  // edge with the app's icon and the window's title. It glides and stretches
  // between boxes.
  property string hoverAddr: ""
  property string peekAddr: ""
  property var items: ({})
  property int itemsRev: 0

  // A tab nub anchors better than its box, so it wins.
  function registerItem(addr, item, prio) {
    var cur = items[addr]
    if (cur && cur.prio > prio && cur.item) return
    items[addr] = { item: item, prio: prio }
    itemsRev++
  }
  function unregisterItem(addr, item) {
    if (items[addr] && items[addr].item === item) { delete items[addr]; itemsRev++ }
  }
  function hoverEntered(addr) {
    hoverClear.stop()
    hoverAddr = addr
    if (!appNames[addr]) root.namesWanted()
  }
  function hoverLeft(addr) { if (hoverAddr === addr) hoverClear.restart() }
  Timer { id: hoverClear; interval: 140; onTriggered: root.hoverAddr = "" }
  Timer { id: peekTimer; interval: 1800; onTriggered: root.peekAddr = "" }

  // Only for a focus change Hyprland announced, and only when asked for: the
  // tab otherwise shows on hover alone.
  function peek(addr) {
    if (!peekOnFocus || !settled || !addr) return
    peekAddr = addr
    peekTimer.restart()
  }

  readonly property string shownAddr: hoverAddr !== "" ? hoverAddr : peekAddr
  readonly property var shownWin: shownAddr !== "" ? (Mini.windowsByAddress(columns)[shownAddr] || null) : null
  readonly property var shownItem: {
    var _rev = itemsRev
    return shownAddr !== "" && items[shownAddr] ? items[shownAddr].item : null
  }
  // The app's name: the CLI's, else its desktop entry's, else its class.
  function appNameFor(win) {
    if (!win) return ""
    var known = appNames[win.address]
    if (known && known.name) return String(known.name)
    var cls = String(win.appClass || "")
    try {
      var entry = cls ? DesktopEntries.heuristicLookup(cls) : null
      if (entry && entry.name) return String(entry.name)
    } catch (e) {}
    return cls
  }
  readonly property string labelText: shownWin ? (appNameFor(shownWin) || String(shownWin.title || "")) : ""
  // The tab keeps its last label while it fades out.
  property var held: ({ name: "", title: "", cls: "", floating: false, fullscreen: false })
  // Read straight from the window, not from labelText, which may not have
  // caught up yet when this runs; again when the CLI's names arrive.
  function captureHeld() {
    var w = shownWin
    if (!w) return
    var name = appNameFor(w) || String(w.title || "")
    if (name === "") return
    held = {
      name: name,
      title: String(w.title || ""),
      cls: String(w.appClass || ""),
      floating: w.floating === true,
      fullscreen: w.fullscreen === true
    }
  }
  onShownWinChanged: captureHeld()
  onAppNamesChanged: captureHeld()
  readonly property string tabLabel: held.name
  // The title, unless it only repeats the name.
  readonly property string tabTitle: held.title !== "" && held.title !== held.name ? held.title : ""
  readonly property string tabClass: held.cls
  readonly property string tabState: held.fullscreen ? "fullscreen" : (held.floating ? "floating" : "")

  function resolveIcon(cls) {
    var value = String(cls || "")
    if (!value) return ""
    if (bar && bar.shell && bar.shell.appLibrary) return bar.shell.appLibrary.iconSource(value)
    return Quickshell.iconPath(value, true) || Quickshell.iconPath(value.toLowerCase(), true)
  }

  PopupWindow {
    id: tip
    readonly property bool wanted: root.visible && root.shownWin !== null && root.shownItem !== null
      && root.labelText !== "" && !root.suppressLabel
    readonly property real pad: Style.space(6)
    readonly property real springK: 3.2
    readonly property real springD: 0.34
    property bool animatePos: false
    readonly property real along: Style.space(760)
    readonly property real maxPillW: Style.space(560)
    readonly property bool left: root.bar && root.bar.position === "left"
    readonly property bool bottom: root.bar && root.bar.position === "bottom"
    // The bar's own fill, glass included, so the tab reads as part of it.
    readonly property color tabColor: {
      if (!root.bar || root.bar.transparent) return Commons.Color.popups.background
      var bg = root.bar.background
      return root.glassy ? Qt.rgba(bg.r, bg.g, bg.b, Math.min(bg.a, 0.35)) : bg
    }

    anchor {
      window: root.QsWindow.window
      adjustment: PopupAdjustment.None
      edges: Edges.Top | Edges.Left
      gravity: Edges.Bottom | Edges.Right
      rect.width: 1
      rect.height: 1
    }
    // Mapped for as long as the minimap shows, and only emptied while hidden:
    // creating the popup on each hover held the drop back by most of a second.
    visible: root.QsWindow.window !== null && root.visible
    color: "transparent"
    implicitWidth: root.vertical ? maxPillW + pad * 2 : along
    implicitHeight: root.vertical ? along : pill.height + pad
    // Takes no input while the tab is away.
    mask: Region { item: pill.presence > 0.003 ? pill : noInput }
    Item { id: noInput; width: 0; height: 0 }

    onWantedChanged: {
      if (!wanted) return
      if (pill.presence < 0.05) {
        animatePos = false
        place()
        Qt.callLater(function() { tip.animatePos = true })
      } else place()
    }
    Connections {
      target: root
      function onShownItemChanged() { if (tip.wanted) tip.place() }
      function onColumnsChanged() { if (tip.wanted) Qt.callLater(tip.place) }
    }

    function clamp(v, lo, hi) { return Math.max(lo, Math.min(v, Math.max(lo, hi))) }

    function place() {
      var win = root.QsWindow.window
      var item = root.shownItem
      if (!win || !item) return
      var o = win.contentItem.mapFromItem(root, 0, 0)
      var c = win.contentItem.mapFromItem(item, item.width / 2, item.height / 2)
      var m = Style.space(4)
      // The bar's surface can be the whole screen (it hosts its popouts),
      // so the tab goes at the bar's own edge, not the window's.
      var screenName = win.screen ? String(win.screen.name || "") : ""
      var thick = root.bar && typeof root.bar.barSizeFor === "function" ? root.bar.barSizeFor(screenName) : root.barSize
      if (!root.vertical) {
        var wx = clamp(o.x - Style.space(12), m, win.width - along - m)
        anchor.rect.x = Math.round(wx)
        anchor.rect.y = Math.round(bottom ? win.height - thick - implicitHeight : thick)
        pill.targetX = clamp(c.x - wx - pill.targetW / 2, 0, along - pill.targetW)
        pill.targetY = bottom ? pad : 0
      } else {
        var vx = left ? o.x + root.width + m : o.x - implicitWidth - m
        var vy = clamp(o.y - Style.space(12), m, win.height - along - m)
        anchor.rect.x = Math.round(vx)
        anchor.rect.y = Math.round(vy)
        pill.targetY = clamp(c.y - vy - pill.height / 2, 0, along - pill.height)
        pill.targetX = left ? pad : implicitWidth - pill.targetW - pad
      }
    }

    Item {
      id: pill
      property real targetX: 0
      property real targetY: 0
      // flare: the concave corners where the tab meets the bar; corner: its free ones.
      readonly property real flare: root.vertical ? 0 : Style.space(10)
      readonly property real corner: Math.min(Style.space(13), height / 2)
      readonly property real textW: Math.max(nameMetrics.width + (stateTag.visible ? stateTag.implicitWidth + Style.space(8) : 0),
                                              root.tabTitle !== "" ? titleMetrics.width : 0)
      readonly property real targetW: Math.min(tip.maxPillW, textW + iconBox.width + flare * 2 + Style.space(40))

      TextMetrics {
        id: nameMetrics
        text: root.tabLabel
        font.family: root.fontFamily
        font.pixelSize: Math.round(Style.font.body * 1.2)
        font.bold: true
      }
      TextMetrics {
        id: titleMetrics
        text: root.tabTitle
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
      }

      // A rounded tab (css-tip.com/rounded-tab), flat edge against the bar.
      readonly property string tabPath: {
        var W = width, H = height + (root.vertical ? 0 : 1), r = flare, R = corner
        if (r <= 0) {
          var h = H / 2
          return "M " + h + " 0 L " + (W - h) + " 0 A " + h + " " + h + " 0 0 1 " + (W - h) + " " + H
            + " L " + h + " " + H + " A " + h + " " + h + " 0 0 1 " + h + " 0 Z"
        }
        return "M 0 " + H
          + " A " + r + " " + r + " 0 0 0 " + r + " " + (H - r)
          + " L " + r + " " + R
          + " A " + R + " " + R + " 0 0 1 " + (r + R) + " 0"
          + " L " + (W - r - R) + " 0"
          + " A " + R + " " + R + " 0 0 1 " + (W - r) + " " + R
          + " L " + (W - r) + " " + (H - r)
          + " A " + r + " " + r + " 0 0 0 " + W + " " + H + " Z"
      }

      // The glide between boxes springs targetX/targetY alone. Springing y as
      // well made it chase the drop's own spring, so the drop stalled and then
      // caught up.
      property real slideX: targetX
      property real slideY: targetY
      Behavior on slideX { enabled: tip.animatePos; SpringAnimation { spring: tip.springK; damping: tip.springD; epsilon: 0.3 } }
      Behavior on slideY { enabled: tip.animatePos; SpringAnimation { spring: tip.springK; damping: tip.springD; epsilon: 0.3 } }
      x: Math.round(slideX)
      y: Math.round(slideY + lift)
      width: targetW
      height: textCol.implicitHeight + Style.space(16)
      // One spring slides and fades it: it rises out of the bar's edge.
      property real presence: tip.wanted ? 1 : 0
      readonly property real lift: root.vertical ? 0 : (1 - presence) * (tip.bottom ? height : -height)
      opacity: Math.max(0, Math.min(1, presence * 2.2))
      Behavior on presence { SpringAnimation { spring: tip.springK; damping: tip.springD; epsilon: 0.002 } }
      Behavior on width { enabled: tip.animatePos; SpringAnimation { spring: tip.springK; damping: tip.springD; epsilon: 0.3 } }

      // Fills the gap under the tab while the spring overshoots.
      Rectangle {
        visible: !root.vertical
        x: pill.flare
        width: parent.width - pill.flare * 2
        height: Style.space(12)
        y: tip.bottom ? parent.height + 1 : -height - 1
        color: tip.tabColor
      }

      // Its flat edge sits 1 px past the bar's edge, outside the popup, so the
      // renderer's half-pixel antialiasing there is cut off. Drawn on the
      // edge, the tab's first row was half see-through: too faint for the
      // glass blur, it showed the bright wallpaper as a line under the bar.
      Shape {
        id: shape
        x: 0
        y: root.vertical || tip.bottom ? 0 : -1
        width: parent.width
        height: parent.height + (root.vertical ? 0 : 1)
        preferredRendererType: Shape.CurveRenderer
        transform: Scale { yScale: (root.vertical || tip.bottom) ? 1 : -1; origin.y: shape.height / 2 }
        ShapePath {
          fillColor: tip.tabColor
          strokeColor: "transparent"
          PathSvg { path: pill.tabPath }
        }
      }

      Item {
        id: iconBox
        anchors.left: parent.left
        anchors.leftMargin: pill.flare + Style.space(12)
        anchors.verticalCenter: parent.verticalCenter
        width: Math.round(nameText.implicitHeight * (root.tabTitle !== "" ? 1.7 : 1.2))
        height: width

        Image {
          id: iconImg
          anchors.fill: parent
          source: root.resolveIcon(root.tabClass)
          sourceSize.width: Math.round(width * 2)
          sourceSize.height: Math.round(height * 2)
          fillMode: Image.PreserveAspectFit
          asynchronous: true
          smooth: true
          mipmap: true
          visible: status === Image.Ready
        }
        Text {
          anchors.centerIn: parent
          visible: iconImg.status !== Image.Ready
          textFormat: Text.PlainText
          text: root.tabClass !== "" ? root.tabClass.charAt(0).toUpperCase() : "•"
          color: root.shownAddr === root.activeAddr ? root.accent : root.muted
          font.family: root.fontFamily
          font.pixelSize: Math.round(Style.font.body * 1.3)
          font.bold: true
        }
      }

      // The app's name, bold, with a floating/fullscreen tag; the window's
      // title under it, dimmed.
      Column {
        id: textCol
        anchors.left: iconBox.right
        anchors.leftMargin: Style.space(10)
        anchors.right: parent.right
        anchors.rightMargin: pill.flare + Style.space(14)
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(1)

        Row {
          width: parent.width
          spacing: Style.space(8)

          Text {
            id: nameText
            width: Math.min(implicitWidth, parent.width - (stateTag.visible ? stateTag.width + parent.spacing : 0))
            textFormat: Text.PlainText
            text: root.tabLabel
            elide: Text.ElideRight
            color: root.fg
            font.family: root.fontFamily
            font.pixelSize: Math.round(Style.font.body * 1.2)
            font.bold: true
          }

          Rectangle {
            id: stateTag
            visible: root.tabState !== ""
            anchors.verticalCenter: nameText.verticalCenter
            implicitWidth: stateText.implicitWidth + Style.space(10)
            width: implicitWidth
            height: stateText.implicitHeight + Style.space(2)
            radius: height / 2
            color: "transparent"
            border.width: 1
            border.color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.35)

            Text {
              id: stateText
              anchors.centerIn: parent
              textFormat: Text.PlainText
              text: root.tabState
              color: root.fg
              opacity: 0.7
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }
        }

        Text {
          visible: root.tabTitle !== ""
          width: parent.width
          textFormat: Text.PlainText
          text: root.tabTitle
          elide: Text.ElideRight
          color: root.fg
          opacity: 0.6
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
        }
      }
    }
  }
}

// Pure helpers for the minimap beside the active workspace (Minimap.qml).
// ES5 only, so `node tests/minimap.test.js` can load it.
//
// The geometry follows jgarza's Minimap plugin (github.com/jgarza9788/minimap,
// MIT): windows of the active workspace become boxes at their true aspect
// ratio, laid out in scrolling-layout column order.

function normalizeAddress(value) {
  var raw = String(value || "").trim().toLowerCase()
  if (raw.indexOf("0x") === 0) raw = raw.slice(2)
  return /^[0-9a-f]+$/.test(raw) ? "0x" + raw : ""
}

function groupedOf(ipc) {
  var g = ipc && ipc.grouped
  var out = []
  if (!g || !g.length) return out
  for (var i = 0; i < g.length; i++) {
    var a = normalizeAddress(g[i])
    if (a) out.push(a)
  }
  return out
}

// The tiled, mapped windows of one workspace, from Quickshell toplevels.
// `live` (optional) is { address: true } from `hyprctl clients`: Quickshell can
// keep a toplevel for a window that is gone, which would draw a phantom box.
function eligibleClients(toplevels, workspaceId, includeFloating, live) {
  var out = []
  var list = toplevels || []
  for (var i = 0; i < list.length; i++) {
    var top = list[i]
    if (!top) continue
    var ipc = top.lastIpcObject && typeof top.lastIpcObject === "object" ? top.lastIpcObject : {}
    var address = normalizeAddress(top.address || ipc.address)
    if (!address) continue
    if (live && !live[address]) continue
    if (ipc.mapped === false || ipc.hidden === true) continue
    if (ipc.floating === true && includeFloating !== true) continue
    if (!ipc.workspace || Number(ipc.workspace.id) !== Number(workspaceId)) continue
    var at = ipc.at || [], size = ipc.size || []
    var x = Number(at[0]), y = Number(at[1]), w = Number(size[0]), h = Number(size[1])
    if (!isFinite(x) || !isFinite(y) || !(w > 0) || !(h > 0)) continue
    var history = Number(ipc.focusHistoryID)
    out.push({
      address: address,
      appClass: String(ipc.class || ipc.initialClass || ""),
      title: String(top.title || ipc.title || ipc.class || ""),
      floating: ipc.floating === true,
      fullscreen: Number(ipc.fullscreen) > 0,
      pinned: ipc.pinned === true,
      grouped: groupedOf(ipc),
      focusHistory: isFinite(history) ? history : 1e9,
      x: x, y: y, w: w, h: h
    })
  }
  return out
}

function overlapFraction(start, end, lo, hi) {
  var span = end - start
  if (!(span > 0)) return 0
  var a = Math.max(start, lo), b = Math.min(end, hi)
  return b > a ? (b - a) / span : 0
}

// A Hyprland group (tabbed windows) shares one position and size: fold it into
// one client carrying `tabs`. The shown tab is the focused one, else the most
// recently focused.
function collapseGroups(clients, activeAddr) {
  var byAddr = {}, seen = {}, out = []
  for (var i = 0; i < clients.length; i++) byAddr[clients[i].address] = clients[i]
  for (var j = 0; j < clients.length; j++) {
    var c = clients[j]
    if (seen[c.address]) continue
    var members = []
    for (var k = 0; k < c.grouped.length; k++) if (byAddr[c.grouped[k]]) members.push(byAddr[c.grouped[k]])
    if (members.length < 2) {
      seen[c.address] = true
      out.push(withTabs(c, null))
      continue
    }
    var head = null
    for (var m = 0; m < members.length; m++) {
      seen[members[m].address] = true
      if (members[m].address === activeAddr) head = members[m]
    }
    if (!head) {
      head = members[0]
      for (var n = 1; n < members.length; n++) if (members[n].focusHistory < head.focusHistory) head = members[n]
    }
    out.push(withTabs(head, members.map(function (t) {
      return { address: t.address, title: t.title, appClass: t.appClass, active: t.address === head.address }
    })))
  }
  return out
}

function withTabs(c, tabs) {
  return {
    address: c.address, appClass: c.appClass, title: c.title, floating: c.floating,
    fullscreen: c.fullscreen, pinned: c.pinned, x: c.x, y: c.y, w: c.w, h: c.h, tabs: tabs
  }
}

// Columns along the bar's axis: windows that share a start and a width are
// one scrolling-layout column, stacked.
function groupColumns(clients, vertical) {
  var list = clients.slice().sort(function (a, b) {
    var p = vertical ? a.y - b.y : a.x - b.x
    if (p !== 0) return p
    var s = vertical ? a.x - b.x : a.y - b.y
    return s !== 0 ? s : (a.address < b.address ? -1 : 1)
  })
  var cols = []
  for (var i = 0; i < list.length; i++) {
    var c = list[i]
    var start = vertical ? c.y : c.x
    var len = vertical ? c.h : c.w
    var last = cols.length ? cols[cols.length - 1] : null
    if (last && Math.abs(last.start - start) <= 2 && Math.abs(last.len - len) <= 4) last.windows.push(c)
    else cols.push({ start: start, len: len, windows: [c] })
  }
  return cols
}

// `monitor` is { x, y, width, height } in logical px; the viewport is the
// monitor's extent along the bar's axis, so a column outside it is scrolled off.
function buildColumns(clients, monitor, vertical, activeAddr) {
  var active = normalizeAddress(activeAddr)
  var viewStart = vertical ? monitor.y : monitor.x
  var viewEnd = viewStart + (vertical ? monitor.height : monitor.width)
  var crossOrigin = vertical ? monitor.x : monitor.y
  return groupColumns(collapseGroups(clients, active), vertical).map(function (col) {
    return {
      len: col.len,
      onScreen: overlapFraction(col.start, col.start + col.len, viewStart, viewEnd) > 0.02,
      windows: col.windows.map(function (w) {
        var focused = active !== "" && (w.address === active
          || (w.tabs ? w.tabs.some(function (t) { return t.address === active }) : false))
        return {
          // A group keeps one key while its shown tab changes, so its box stays put.
          key: w.tabs ? w.tabs.map(function (t) { return t.address }).sort()[0] : w.address,
          address: w.address, title: w.title, appClass: w.appClass, tabs: w.tabs,
          floating: w.floating, fullscreen: w.fullscreen, pinned: w.pinned,
          off: (vertical ? w.x : w.y) - crossOrigin,
          span: vertical ? w.w : w.h,
          focused: focused
        }
      })
    }
  })
}

// Absolutely positioned boxes in bar pixels. Stacked windows split their
// column with a gap between them.
function layoutTape(columns, o) {
  var scale = Number(o.scale) || 0, gap = Number(o.gap) || 0, stackGap = Number(o.stackGap) || 0
  var vertical = o.vertical === true
  var items = [], cursor = 0
  for (var i = 0; i < columns.length; i++) {
    var col = columns[i]
    var len = Math.max(2, col.len * scale)
    var n = col.windows.length
    for (var j = 0; j < n; j++) {
      var w = col.windows[j]
      var inStart = n > 1 && j > 0 ? stackGap / 2 : 0
      var inEnd = n > 1 && j < n - 1 ? stackGap / 2 : 0
      var cross = Math.max(1, w.span * scale - inStart - inEnd)
      var cs = Math.max(0, w.off * scale + inStart)
      var tabs = w.tabs && w.tabs.length > 1 ? w.tabs : null
      items.push({
        key: w.key, address: w.address,
        bx: vertical ? cs : cursor, by: vertical ? cursor : cs,
        bw: vertical ? cross : len, bh: vertical ? len : cross,
        focused: w.focused, onScreen: col.onScreen,
        floating: w.floating, fullscreen: w.fullscreen, pinned: w.pinned,
        tabsJson: tabs ? JSON.stringify(tabs) : ""
      })
    }
    cursor += len + gap
  }
  return { items: items, total: Math.max(0, cursor - (items.length ? gap : 0)) }
}

// Hyprland's `urgent` event carries the window address without 0x.
function urgentAddress(data) { return normalizeAddress(String(data || "").split(",")[0]) }

// Every window of the tape (group members too), by address.
function windowsByAddress(columns) {
  var out = {}
  for (var i = 0; i < columns.length; i++)
    for (var j = 0; j < columns[i].windows.length; j++) {
      var w = columns[i].windows[j]
      out[w.address] = w
      if (w.tabs) for (var k = 0; k < w.tabs.length; k++) out[w.tabs[k].address] = w.tabs[k]
    }
  return out
}

// The row key holding a window: its own, or its group's.
function keyFor(columns, address) {
  for (var i = 0; i < columns.length; i++)
    for (var j = 0; j < columns[i].windows.length; j++) {
      var w = columns[i].windows[j]
      if (w.address === address) return w.key
      if (w.tabs) for (var k = 0; k < w.tabs.length; k++) if (w.tabs[k].address === address) return w.key
    }
  return ""
}

if (typeof module !== "undefined") module.exports = {
  normalizeAddress: normalizeAddress, eligibleClients: eligibleClients, buildColumns: buildColumns,
  layoutTape: layoutTape, urgentAddress: urgentAddress, windowsByAddress: windowsByAddress, keyFor: keyFor
}

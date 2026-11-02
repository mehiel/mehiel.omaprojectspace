// Pure logic for Projectspaces: which workspaces the strip shows, what each one
// is called, which projectspace it carries and how that looks. Everything here
// runs under both QML's JS engine and node, so tests/model.test.js can cover it.

var WORKSPACE_IDS = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]

// Omarchy gives every monitor workspaces 1-10 of its own, numbered in a block
// of ten per monitor: the laptop panel 1-10, the next monitor 11-20, and so on
// (default/hypr/monitor-workspaces.lua). Ids stay global everywhere here;
// only what is shown and typed is the slot within a block.
var SLOTS = 10

function blockOf(id) {
  return Math.floor((id - 1) / SLOTS)
}

function slotOf(id) {
  return (id - 1) % SLOTS + 1
}

// A monitor's own ten ids.
function blockIds(block) {
  var base = (block > 0 ? block : 0) * SLOTS
  var ids = []
  for (var slot = 1; slot <= SLOTS; slot++) ids.push(base + slot)
  return ids
}

// Connector -> block, from Omarchy's state file: one "block<TAB>connector<TAB>
// identity" line per monitor ever seen, the connector empty while unplugged.
function parseBlocks(text) {
  var out = {}
  var lines = String(text || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var fields = lines[i].split("\t")
    if (fields.length >= 3 && fields[1] !== "" && /^[0-9]+$/.test(fields[0])) out[fields[1]] = parseInt(fields[0], 10)
  }
  return out
}

// The panel's rows for a monitor: its own ten, then any workspace visiting it
// from a monitor that is unplugged, ascending.
function panelIds(block, guests) {
  var ids = blockIds(block)
  var extra = (guests || []).filter(function(id) { return id > 0 && blockOf(id) !== block && ids.indexOf(id) === -1 })
  extra.sort(function(a, b) { return a - b })
  return ids.concat(extra)
}

// Every monitor Omarchy has seen, from the same file: [{ block, connector,
// identity }] by block, the connector "" while it is unplugged.
function parseScreens(text) {
  var out = []
  var lines = String(text || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var fields = lines[i].split("\t")
    if (fields.length >= 3 && /^[0-9]+$/.test(fields[0]) && fields[2] !== "")
      out.push({ block: parseInt(fields[0], 10), connector: fields[1], identity: fields.slice(2).join("\t") })
  }
  out.sort(function(a, b) { return a.block - b.block })
  return out
}

// The panel's screen tabs: [{ block, connector, plugged, icon, label }]. A
// plugged-in monitor always has one; an unplugged one only while something in
// its block is attached or named (`used` is those ids), so a screen seen once
// in a meeting room doesn't linger. `badges` is monitorBadges' output.
function screenTabs(screens, badges, used) {
  var tabs = []
  var list = Array.isArray(screens) ? screens : []
  var ids = Array.isArray(used) ? used : []
  for (var i = 0; i < list.length; i++) {
    var s = list[i]
    var badge = s.connector ? (badges || {})[s.connector] : null
    if (s.connector && !badge) continue
    if (!s.connector && !ids.some(function(id) { return blockOf(id) === s.block })) continue
    var label = badge ? badge.label : monitorLabels([{ name: "unplugged", make: s.identity }]).unplugged
    tabs.push({
      block: s.block, connector: s.connector, plugged: !!s.connector,
      icon: badge ? badge.icon : MONITOR_GLYPH, label: label
    })
  }
  return tabs
}

// The tab after (step 1) or before (-1) the one showing `block`, wrapping.
function nextTab(tabs, block, step) {
  if (!tabs || tabs.length === 0) return block
  var at = -1
  for (var i = 0; i < tabs.length; i++) if (tabs[i].block === block) at = i
  if (at < 0) return tabs[0].block
  return tabs[((at + step) % tabs.length + tabs.length) % tabs.length].block
}

function tabFor(tabs, block) {
  for (var i = 0; i < (tabs || []).length; i++) if (tabs[i].block === block) return tabs[i]
  return null
}

// Workspaces on other monitors attached to the same projectspace as `id`,
// ascending: the rest of a project spread over several screens.
function pairedIds(state, id) {
  var p = projectspaceFor(state, id)
  if (!p) return []
  var out = []
  for (var ws in state.attachments) {
    var other = Number(ws)
    if (state.attachments[ws].home === p.home && blockOf(other) !== blockOf(id)) out.push(other)
  }
  out.sort(function(a, b) { return a - b })
  return out
}

// "9:19 8:18" -> { "9": "19", "8": "18" }; anything malformed is skipped.
function parseRenumber(text) {
  var out = {}
  var pairs = String(text || "").split(/\s+/)
  for (var i = 0; i < pairs.length; i++) {
    var m = /^([1-9][0-9]*):([1-9][0-9]*)$/.exec(pairs[i])
    if (m && m[1] !== m[2]) out[m[1]] = m[2]
  }
  return out
}

// The same re-keying as the CLI's renumber: entries move all at once, and one
// a newcomer displaces takes the id the newcomer left.
function renumbered(object, map) {
  var back = {}
  for (var from in map) back[map[from]] = from
  var out = {}
  var k
  for (k in object) if (map[k]) out[map[k]] = object[k]
  for (k in object) {
    if (map[k]) continue
    if (back[k]) { if (out[back[k]] === undefined) out[back[k]] = object[k] }
    else out[k] = object[k]
  }
  return out
}

// Fallback labels, used until a workspace gets a custom name or a
// projectspace: its number, as the stock workspace switcher shows it.
var DEFAULT_LABELS = {
  "1": "1", "2": "2", "3": "3", "4": "4", "5": "5",
  "6": "6", "7": "7", "8": "8", "9": "9", "10": "10"
}

// Projectspaces without PROJECTSPACE_COLOR get one of these, picked by name so
// it never changes between sessions. Mid lightness and saturation, so a dot
// reads on light and dark bars alike; themes here are often monochrome, so
// the theme palette cannot be relied on to tell teams apart.
var PALETTE = [
  "#E5636B", // coral
  "#E8913A", // orange
  "#C9A227", // gold
  "#4FAE6B", // green
  "#2FA5A0", // teal
  "#4C8DDB", // blue
  "#8A6BE0", // violet
  "#D45FA6"  // magenta
]

// The digit a workspace answers to on the keyboard, within its monitor's
// block: SUPER+0 is slot 10, so workspace 20 on the second monitor is "0".
function keyLabel(id) {
  if (!(id > 0)) return String(id)
  var slot = slotOf(id)
  return slot === SLOTS ? "0" : String(slot)
}

// FNV-1a: short folder names differ in a letter or two, and a plain
// multiply-add hash leaves those differences where a small modulo never looks.
function hashName(name) {
  var h = 0x811c9dc5
  var s = String(name || "")
  for (var i = 0; i < s.length; i++) {
    h ^= s.charCodeAt(i)
    h = Math.imul(h, 0x01000193) >>> 0
  }
  // murmur3's finalizer: FNV's low bits are weak, and a palette of eight
  // only reads the lowest three.
  h ^= h >>> 16
  h = Math.imul(h, 0x85ebca6b) >>> 0
  h ^= h >>> 13
  h = Math.imul(h, 0xc2b2ae35) >>> 0
  h ^= h >>> 16
  return h >>> 0
}

function isHexColor(value) {
  return /^#([0-9a-fA-F]{6}|[0-9a-fA-F]{8})$/.test(String(value || ""))
}

function colorFor(projectspace) {
  if (!projectspace) return ""
  if (isHexColor(projectspace.color)) return projectspace.color
  return PALETTE[hashName(projectspace.folder || projectspace.name) % PALETTE.length]
}

// Each projectspace without its own color starts at its hashed palette slot
// and takes the next free one on a collision. Assigned in folder order, so a
// color only moves when a new folder collides with it, and up to eight
// projectspaces never share one.
function assignColors(list) {
  var taken = {}
  var pending = []
  for (var i = 0; i < list.length; i++) {
    if (list[i].color) taken[list[i].color.toUpperCase()] = true
    else pending.push(list[i])
  }
  pending.sort(function(a, b) { return a.folder < b.folder ? -1 : (a.folder > b.folder ? 1 : 0) })
  for (var j = 0; j < pending.length; j++) {
    var start = hashName(pending[j].folder || pending[j].name) % PALETTE.length
    var pick = PALETTE[start]
    for (var k = 0; k < PALETTE.length; k++) {
      var candidate = PALETTE[(start + k) % PALETTE.length]
      if (!taken[candidate.toUpperCase()]) { pick = candidate; break }
    }
    taken[pick.toUpperCase()] = true
    pending[j].color = pick
  }
}

// `omaprojectspace list --json` → lookups the widget reads every frame.
// Garbage in (a failed run, a partial write) gives an empty, usable state.
function parseList(text) {
  var data = null
  try { data = JSON.parse(String(text || "")) } catch (e) { data = null }
  var state = { projectspaces: [], byHome: {}, attachments: {} }
  if (!data || typeof data !== "object") return state
  var list = Array.isArray(data.projectspaces) ? data.projectspaces : []
  for (var i = 0; i < list.length; i++) {
    var p = list[i]
    if (!p || typeof p.home !== "string") continue
    var entry = {
      name: String(p.name || p.folder || ""),
      folder: String(p.folder || ""),
      home: p.home,
      display: String(p.display || p.home),
      config: String(p.config || ""),
      ok: p.ok !== false,
      error: String(p.error || ""),
      color: "",
      icon: String(p.icon || ""),
      browser: String(p.browser || ""),
      env: p.env && typeof p.env === "object" ? p.env : {},
      workspaces: Array.isArray(p.workspaces) ? p.workspaces : []
    }
    entry.color = isHexColor(p.color) ? p.color : ""
    state.projectspaces.push(entry)
    state.byHome[entry.home] = entry
  }
  assignColors(state.projectspaces)
  var att = data.attachments && typeof data.attachments === "object" ? data.attachments : {}
  for (var ws in att) {
    var a = att[ws]
    if (!a || typeof a.home !== "string") continue
    state.attachments[ws] = { home: a.home, missing: a.missing === true }
  }
  return state
}

// The projectspace attached to a workspace, or null. A missing folder still
// answers, flagged, so the panel can say what went away.
function projectspaceFor(state, id) {
  if (!state) return null
  var a = state.attachments[String(id)]
  if (!a) return null
  var p = state.byHome[a.home]
  if (p) return p
  var parts = a.home.split("/")
  var folder = parts[parts.length - 1] || a.home
  return {
    name: folder, folder: folder, home: a.home, display: a.home, config: "",
    ok: false, error: "This folder is gone or no longer has a mise config.",
    color: colorFor({ folder: folder }), icon: "", browser: "", env: {}, workspaces: [id],
    missing: true
  }
}

// A custom name wins; then the projectspace's name; then the default.
function labelFor(id, names, state) {
  var key = String(id)
  var custom = names ? names[key] : ""
  if (custom) return String(custom)
  var p = projectspaceFor(state, id)
  if (p) return p.name
  return defaultLabel(id)
}

// A workspace's number as the stock workspace switcher shows it: its slot in
// its monitor's block.
function defaultLabel(id) {
  return id > 0 ? DEFAULT_LABELS[String(slotOf(id))] : String(id)
}

function labelSource(id, names, state) {
  if (names && names[String(id)]) return "custom"
  if (projectspaceFor(state, id)) return "projectspace"
  return "default"
}

// The placeholder the name field shows: what the label falls back to.
function fallbackLabel(id, state) {
  var p = projectspaceFor(state, id)
  return p ? p.name : defaultLabel(id)
}

// The state with one workspace attached to `home`, or detached when it is "".
// Applied at once so the panel answers a keypress before the CLI has written.
function withAttachment(state, id, home) {
  var next = { projectspaces: state.projectspaces, byHome: state.byHome, attachments: {} }
  for (var ws in state.attachments) next.attachments[ws] = state.attachments[ws]
  if (home) next.attachments[String(id)] = { home: home, missing: !state.byHome[home] }
  else delete next.attachments[String(id)]
  return next
}

// None first, then the projectspaces as listed. ← / → walk this list.
function attachOptions(state) {
  var out = [{ home: "", name: "None", color: "" }]
  if (!state) return out
  for (var i = 0; i < state.projectspaces.length; i++) {
    var p = state.projectspaces[i]
    out.push({ home: p.home, name: p.name, color: p.color })
  }
  return out
}

function cycleAttachment(state, id, step) {
  var options = attachOptions(state)
  var a = state ? state.attachments[String(id)] : null
  var current = a ? a.home : ""
  var at = 0
  for (var i = 0; i < options.length; i++) if (options[i].home === current) at = i
  var next = ((at + step) % options.length + options.length) % options.length
  return options[next].home
}

function tildify(path, home) {
  var p = String(path || "")
  if (home && (p === home || p.indexOf(home + "/") === 0)) return "~" + p.slice(home.length)
  return p
}

// Keys a projectspace most often exists to set come first, then the rest.
var NOTABLE_KEYS = ["BROWSER", "CLAUDE_CONFIG_DIR", "HERDR_SESSION"]

function envRows(env, home, limit) {
  var rows = []
  var seen = {}
  var keys = Object.keys(env || {})
  for (var i = 0; i < NOTABLE_KEYS.length; i++) {
    var k = NOTABLE_KEYS[i]
    if (keys.indexOf(k) !== -1) { rows.push({ key: k, value: tildify(env[k], home) }); seen[k] = true }
  }
  keys.sort()
  for (var j = 0; j < keys.length; j++) {
    if (seen[keys[j]]) continue
    rows.push({ key: keys[j], value: tildify(env[keys[j]], home) })
  }
  var max = limit > 0 ? limit : rows.length
  return { rows: rows.slice(0, max), hidden: Math.max(0, rows.length - max) }
}

// "1 window", "3 windows", "empty".
function windowsLabel(count) {
  if (!count) return "empty"
  return count === 1 ? "1 window" : count + " windows"
}

// The strip's workspaces for one monitor: its active workspace plus every
// other occupied one that lives there, ascending, its own block before any
// visiting from another. `workspaces` is a plain [{ id, monitor, windows }]
// snapshot; `block` is the monitor's, when known.
function stripIds(workspaces, monitorName, activeId, block) {
  var ids = []
  for (var i = 0; i < workspaces.length; i++) {
    var w = workspaces[i]
    if (!w || w.id <= 0) continue
    if (monitorName && w.monitor && w.monitor !== monitorName) continue
    if (w.windows > 0 || w.id === activeId) {
      if (ids.indexOf(w.id) === -1) ids.push(w.id)
    }
  }
  if (activeId > 0 && ids.indexOf(activeId) === -1) ids.push(activeId)
  var own = block >= 0 ? block : -1
  ids.sort(function(a, b) {
    var guestA = own >= 0 && blockOf(a) !== own ? 1 : 0
    var guestB = own >= 0 && blockOf(b) !== own ? 1 : 0
    return guestA - guestB || a - b
  })
  return ids
}

// Up/down over the panel's rows, wrapping.
function moveCursor(current, step, rows) {
  var list = rows && rows.length ? rows : WORKSPACE_IDS
  var at = list.indexOf(current)
  if (at < 0) at = 0
  var next = ((at + step) % list.length + list.length) % list.length
  return list[next]
}

// A typed digit → the workspace it names in a monitor's block, or -1.
function workspaceForKey(text, block) {
  if (!/^[0-9]$/.test(String(text || ""))) return -1
  var n = Number(text)
  return (block > 0 ? block : 0) * SLOTS + (n === 0 ? SLOTS : n)
}

// mise names its config in errors; this turns "not trusted" into the fix.
function trustCommand(projectspace) {
  if (!projectspace || !/not trusted/i.test(projectspace.error || "")) return ""
  return projectspace.config ? "mise trust " + projectspace.config : "mise trust " + projectspace.home
}

// ---- saved windows (omaprojectspace windows --json)

// { workspaces: [{ ws, saved, projectspace, windows, missing }], byWs, missing, live }.
// Anything unreadable is an empty one, so the panel simply shows nothing saved.
function parseWindows(text) {
  var empty = { workspaces: [], byWs: {}, missing: 0, live: {} }
  var data
  try { data = JSON.parse(text || "") } catch (e) { return empty }
  if (!data || !Array.isArray(data.workspaces)) return empty
  var out = {
    workspaces: [], byWs: {}, missing: 0,
    live: data.live && typeof data.live === "object" && !Array.isArray(data.live) ? data.live : {}
  }
  for (var i = 0; i < data.workspaces.length; i++) {
    var w = data.workspaces[i]
    if (!w || !(w.ws > 0) || !Array.isArray(w.windows)) continue
    var entry = { ws: w.ws, saved: w.saved || null, projectspace: w.projectspace || null, windows: w.windows, missing: Number(w.missing) || 0 }
    out.workspaces.push(entry)
    out.byWs[String(w.ws)] = entry
    out.missing += entry.missing
  }
  return out
}

function restoreFor(session, id) {
  return session && session.byWs ? session.byWs[String(id)] || null : null
}

// "3 to reopen", "all open".
function restoreSummary(entry) {
  if (!entry) return ""
  if (entry.missing === 0) return "all open"
  return entry.missing + " to reopen"
}

// When the snapshot was taken, relative to now (both epoch seconds).
function savedLabel(saved, now) {
  if (!saved) return ""
  var minutes = Math.max(0, Math.round((now - saved) / 60))
  if (minutes < 1) return "just now"
  if (minutes < 60) return minutes + " min ago"
  var hours = Math.round(minutes / 60)
  if (hours < 24) return hours + " h ago"
  var days = Math.round(hours / 24)
  return days === 1 ? "yesterday" : days + " days ago"
}

// ---- what is open now (windows --json's live)

// { layout, monitor, windows: [{ address, title, at, size, floating, kind, name, focus }] }
// for a workspace with windows, else null.
function liveFor(session, id) {
  var entry = session && session.live ? session.live[String(id)] : null
  return entry && Array.isArray(entry.windows) && entry.windows.length > 0 ? entry : null
}

// The workspace drawn to fit `width` (and at most `maxHeight`): its monitor's
// usable area as the view, and every window, in the same scale. A scrolling
// layout's columns off either side of the screen extend the drawing.
// { width, height, view: {x,y,w,h} | null, boxes: [{x,y,w,h, address, name, kind, title, focused, floating}] }
function layoutBoxes(entry, width, maxHeight) {
  var out = { width: 0, height: 0, view: null, boxes: [] }
  if (!entry || !Array.isArray(entry.windows) || entry.windows.length === 0 || !(width > 0)) return out
  var m = entry.monitor
  var view = null
  if (m && m.width > 0 && m.height > 0) {
    var r = Array.isArray(m.reserved) ? m.reserved : [0, 0, 0, 0]
    view = { x: m.x + r[0], y: m.y + r[1], w: m.width - r[0] - r[2], h: m.height - r[1] - r[3] }
  }
  var minX = Infinity, minY = Infinity, maxX = -Infinity, maxY = -Infinity
  function grow(x, y, w, h) {
    minX = Math.min(minX, x); minY = Math.min(minY, y)
    maxX = Math.max(maxX, x + w); maxY = Math.max(maxY, y + h)
  }
  if (view) grow(view.x, view.y, view.w, view.h)
  var focus = Infinity
  for (var i = 0; i < entry.windows.length; i++) {
    var w = entry.windows[i]
    if (!w.at || !w.size) continue
    grow(w.at[0], w.at[1], w.size[0], w.size[1])
    if (w.focus >= 0) focus = Math.min(focus, w.focus)
  }
  if (!(maxX > minX) || !(maxY > minY)) return out
  var scale = width / (maxX - minX)
  if (maxHeight > 0) scale = Math.min(scale, maxHeight / (maxY - minY))
  function place(x, y, w, h) {
    return { x: Math.round((x - minX) * scale), y: Math.round((y - minY) * scale), w: Math.max(2, Math.round(w * scale)), h: Math.max(2, Math.round(h * scale)) }
  }
  out.width = Math.round((maxX - minX) * scale)
  out.height = Math.round((maxY - minY) * scale)
  if (view) out.view = place(view.x, view.y, view.w, view.h)
  for (var j = 0; j < entry.windows.length; j++) {
    var win = entry.windows[j]
    if (!win.at || !win.size) continue
    var b = place(win.at[0], win.at[1], win.size[0], win.size[1])
    b.address = win.address
    b.name = win.name || ""
    b.title = win.title || ""
    b.kind = win.kind || "unknown"
    b.floating = !!win.floating
    b.focused = win.focus === focus
    out.boxes.push(b)
  }
  // Floating windows draw over the tiled ones.
  out.boxes.sort(function(a, b2) { return (a.floating ? 1 : 0) - (b2.floating ? 1 : 0) })
  return out
}

// "scrolling" → "Scrolling".
function layoutLabel(layout) {
  var s = String(layout || "")
  return s ? s.charAt(0).toUpperCase() + s.slice(1) : ""
}

// Short names for monitors, by connector: { "eDP-1": "Laptop", "DP-3": "Dell" }.
// A built-in panel is the laptop's; an external one goes by its maker, or by
// its model when two share a maker; the connector when it says nothing else.
// `monitors` is [{ name, make, model }].
function monitorLabels(monitors) {
  var out = {}
  var list = Array.isArray(monitors) ? monitors : []
  var makers = {}
  function maker(m) {
    var word = String(m.make || "").trim().split(/\s+/)[0] || ""
    // "DELL" → "Dell", but "LG" and "AOC" stay as they are.
    if (word.length <= 3) return word.toUpperCase()
    return word.charAt(0).toUpperCase() + word.slice(1).toLowerCase()
  }
  for (var i = 0; i < list.length; i++) {
    var k = maker(list[i])
    if (k) makers[k] = (makers[k] || 0) + 1
  }
  for (var j = 0; j < list.length; j++) {
    var m = list[j]
    if (!m || !m.name) continue
    var name = String(m.name)
    var mk = maker(m)
    if (/^(eDP|LVDS|DSI)-/.test(name)) out[name] = "Laptop"
    else if (mk && makers[mk] === 1) out[name] = mk
    else if (m.model) out[name] = String(m.model).trim()
    else out[name] = name
  }
  return out
}

var LAPTOP_GLYPH = "\uf109"
var MONITOR_GLYPH = "\uf108"

// How a monitor shows in the panel: { "eDP-1": { icon, label, text } }. A
// laptop's own screen and an external one each get their glyph; `text` adds
// the short name only where two monitors would share a glyph.
function monitorBadges(monitors) {
  var labels = monitorLabels(monitors)
  var out = {}
  var count = {}
  for (var name in labels) {
    var icon = labels[name] === "Laptop" ? LAPTOP_GLYPH : MONITOR_GLYPH
    out[name] = { icon: icon, label: labels[name] }
    count[icon] = (count[icon] || 0) + 1
  }
  for (var n in out) out[n].text = count[out[n].icon] > 1 ? out[n].icon + " " + out[n].label : out[n].icon
  return out
}

if (typeof module !== "undefined") {
  module.exports = {
    WORKSPACE_IDS: WORKSPACE_IDS,
    SLOTS: SLOTS,
    blockOf: blockOf,
    slotOf: slotOf,
    blockIds: blockIds,
    parseBlocks: parseBlocks,
    panelIds: panelIds,
    parseScreens: parseScreens,
    screenTabs: screenTabs,
    nextTab: nextTab,
    tabFor: tabFor,
    pairedIds: pairedIds,
    parseRenumber: parseRenumber,
    renumbered: renumbered,
    defaultLabel: defaultLabel,
    DEFAULT_LABELS: DEFAULT_LABELS,
    PALETTE: PALETTE,
    keyLabel: keyLabel,
    hashName: hashName,
    isHexColor: isHexColor,
    colorFor: colorFor,
    assignColors: assignColors,
    parseList: parseList,
    projectspaceFor: projectspaceFor,
    labelFor: labelFor,
    labelSource: labelSource,
    fallbackLabel: fallbackLabel,
    withAttachment: withAttachment,
    attachOptions: attachOptions,
    cycleAttachment: cycleAttachment,
    tildify: tildify,
    envRows: envRows,
    windowsLabel: windowsLabel,
    stripIds: stripIds,
    moveCursor: moveCursor,
    workspaceForKey: workspaceForKey,
    trustCommand: trustCommand,
    parseWindows: parseWindows,
    restoreFor: restoreFor,
    restoreSummary: restoreSummary,
    savedLabel: savedLabel,
    liveFor: liveFor,
    layoutBoxes: layoutBoxes,
    layoutLabel: layoutLabel,
    monitorLabels: monitorLabels,
    monitorBadges: monitorBadges
  }
}

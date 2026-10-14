// Pure logic for Projectspaces: which workspaces the strip shows, what each one
// is called, which projectspace it carries and how that looks. Everything here
// runs under both QML's JS engine and node, so tests/model.test.js can cover it.

var WORKSPACE_IDS = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]

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

// The digit a workspace answers to on the keyboard: SUPER+0 is workspace 10.
function keyLabel(id) {
  return id === 10 ? "0" : String(id)
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
  return DEFAULT_LABELS[key] || key
}

function labelSource(id, names, state) {
  if (names && names[String(id)]) return "custom"
  if (projectspaceFor(state, id)) return "projectspace"
  return "default"
}

// The placeholder the name field shows: what the label falls back to.
function fallbackLabel(id, state) {
  var p = projectspaceFor(state, id)
  return p ? p.name : (DEFAULT_LABELS[String(id)] || String(id))
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
// other occupied one (1–10) that lives there, ascending. `workspaces` is a
// plain [{ id, monitor, windows }] snapshot.
function stripIds(workspaces, monitorName, activeId) {
  var ids = []
  for (var i = 0; i < workspaces.length; i++) {
    var w = workspaces[i]
    if (!w || w.id <= 0 || w.id > 10) continue
    if (monitorName && w.monitor && w.monitor !== monitorName) continue
    if (w.windows > 0 || w.id === activeId) {
      if (ids.indexOf(w.id) === -1) ids.push(w.id)
    }
  }
  if (activeId > 0 && activeId <= 10 && ids.indexOf(activeId) === -1) ids.push(activeId)
  ids.sort(function(a, b) { return a - b })
  return ids
}

// Up/down over the ten rows, wrapping.
function moveCursor(current, step) {
  var at = WORKSPACE_IDS.indexOf(current)
  if (at < 0) at = 0
  var next = ((at + step) % WORKSPACE_IDS.length + WORKSPACE_IDS.length) % WORKSPACE_IDS.length
  return WORKSPACE_IDS[next]
}

// A typed digit → the workspace it names, or -1.
function workspaceForKey(text) {
  if (!/^[0-9]$/.test(String(text || ""))) return -1
  var n = Number(text)
  return n === 0 ? 10 : n
}

// mise names its config in errors; this turns "not trusted" into the fix.
function trustCommand(projectspace) {
  if (!projectspace || !/not trusted/i.test(projectspace.error || "")) return ""
  return projectspace.config ? "mise trust " + projectspace.config : "mise trust " + projectspace.home
}

// ---- the last session's windows (omaprojectspace windows --json)

// { saved, workspaces: [{ ws, projectspace, windows, missing }], byWs, missing }.
// Anything unreadable is an empty session, so the panel simply hides it.
function parseWindows(text) {
  var empty = { saved: null, workspaces: [], byWs: {}, missing: 0, current: null, uptime: null }
  var data
  try { data = JSON.parse(text || "") } catch (e) { return empty }
  if (!data || !Array.isArray(data.workspaces)) return empty
  var c = data.current
  var out = {
    saved: data.saved || null, workspaces: [], byWs: {}, missing: 0,
    current: c && c.saved > 0 ? { saved: c.saved, windows: Number(c.windows) || 0, workspaces: Number(c.workspaces) || 0 } : null,
    uptime: data.uptime >= 0 ? data.uptime : null
  }
  for (var i = 0; i < data.workspaces.length; i++) {
    var w = data.workspaces[i]
    if (!w || !(w.ws > 0) || !Array.isArray(w.windows)) continue
    var entry = { ws: w.ws, projectspace: w.projectspace || null, windows: w.windows, missing: Number(w.missing) || 0 }
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

// Auto-save runs every minute; a snapshot older than this means it stopped.
var AUTOSAVE_STALE = 180

// The footer's auto-save line: { text, stale }. Without a snapshot yet, a
// session older than the stale mark means the timer never started.
function autosaveStatus(session, now) {
  var c = session ? session.current : null
  if (!c) {
    var late = session && session.uptime !== null && session.uptime > AUTOSAVE_STALE
    return { text: late ? "Auto-save isn't running" : "Auto-save starts within a minute", stale: !!late }
  }
  var age = now - c.saved
  if (age > AUTOSAVE_STALE) return { text: "Auto-save stopped  ·  last " + savedLabel(c.saved, now), stale: true }
  return { text: "Auto-saved " + windowsLabel(c.windows) + "  ·  " + (age < 60 ? "just now" : savedLabel(c.saved, now)), stale: false }
}

if (typeof module !== "undefined") {
  module.exports = {
    WORKSPACE_IDS: WORKSPACE_IDS,
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
    autosaveStatus: autosaveStatus
  }
}

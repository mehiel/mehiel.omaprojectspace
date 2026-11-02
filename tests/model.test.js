// node tests/model.test.js
// Runs the pure half of Projectspaces: labels, attachments, colors, the strip.

var assert = require("assert")
var Model = require("../Model.js")

var failures = 0
var passes = 0

function test(name, body) {
  try {
    body()
    passes++
  } catch (error) {
    failures++
    console.error("FAIL " + name)
    console.error("     " + error.message)
  }
}

var HOME = "/home/me"

function listJson() {
  return JSON.stringify({
    projectspaces: [
      { name: "acme", folder: "acme", home: HOME + "/Projects/acme", display: "~/Projects/acme",
        config: HOME + "/Projects/acme/mise.local.toml", ok: true, error: "", color: "#ff8800", icon: "",
        browser: "chrome-acme", workspaces: [3],
        env: { TEAM: "acme", BROWSER: HOME + "/.local/bin/chrome-acme", CLAUDE_CONFIG_DIR: HOME + "/.claude.acme" } },
      { name: "Globex Corp", folder: "globex", home: HOME + "/Projects/globex", display: "~/Projects/globex",
        config: HOME + "/Projects/globex/mise.toml", ok: false,
        error: "Config files in " + HOME + "/Projects/globex/mise.toml are not trusted.", color: "", icon: "",
        browser: "", workspaces: [], env: {} }
    ],
    attachments: {
      "3": { home: HOME + "/Projects/acme", name: "acme", missing: false },
      "9": { home: HOME + "/Projects/gone", name: null, missing: true }
    }
  })
}

var state = Model.parseList(listJson())

// ------------------------------------------------------------- parsing

test("parseList reads projectspaces by home", function() {
  assert.strictEqual(state.projectspaces.length, 2)
  assert.strictEqual(state.byHome[HOME + "/Projects/acme"].name, "acme")
})

test("parseList keeps attachments", function() {
  assert.deepStrictEqual(state.attachments["3"], { home: HOME + "/Projects/acme", missing: false })
  assert.strictEqual(state.attachments["9"].missing, true)
})

test("parseList survives garbage", function() {
  var empty = Model.parseList("{not json")
  assert.deepStrictEqual(empty, { projectspaces: [], byHome: {}, attachments: {} })
  assert.deepStrictEqual(Model.parseList(""), empty)
  assert.deepStrictEqual(Model.parseList("null"), empty)
})

// --------------------------------------------------------------- colors

test("an explicit color wins", function() {
  assert.strictEqual(state.byHome[HOME + "/Projects/acme"].color, "#ff8800")
})

test("a missing color comes from the palette, stable by folder", function() {
  var c = state.byHome[HOME + "/Projects/globex"].color
  assert.ok(Model.PALETTE.indexOf(c) !== -1)
  assert.strictEqual(Model.colorFor({ folder: "globex", name: "Other name" }), c)
})

test("a malformed color falls back to the palette", function() {
  assert.ok(Model.PALETTE.indexOf(Model.colorFor({ color: "orange", folder: "x" })) !== -1)
})

test("up to eight projectspaces never share a color", function() {
  var names = ["acme", "globex", "initech", "umbrella", "hooli", "stark", "wayne", "tyrell"]
  var list = names.map(function(n) { return { folder: n, name: n, color: "" } })
  Model.assignColors(list)
  var seen = {}
  list.forEach(function(p) { seen[p.color] = true })
  assert.strictEqual(Object.keys(seen).length, 8)
})

test("colors stay put when an unrelated folder appears", function() {
  var before = [{ folder: "acme", color: "" }, { folder: "globex", color: "" }]
  Model.assignColors(before)
  var after = [{ folder: "acme", color: "" }, { folder: "globex", color: "" }, { folder: "zzz", color: "" }]
  Model.assignColors(after)
  assert.strictEqual(after[0].color, before[0].color)
  assert.strictEqual(after[1].color, before[1].color)
})

test("an explicit color is not handed to anyone else", function() {
  var hashed = Model.colorFor({ folder: "acme" })
  var list = [{ folder: "zed", color: hashed }, { folder: "acme", color: "" }]
  Model.assignColors(list)
  assert.notStrictEqual(list[1].color, hashed)
})

// --------------------------------------------------------------- labels

test("a custom name wins over the projectspace", function() {
  assert.strictEqual(Model.labelFor(3, { "3": "Chat" }, state), "Chat")
  assert.strictEqual(Model.labelSource(3, { "3": "Chat" }, state), "custom")
})

test("an attached workspace without a name shows the projectspace", function() {
  assert.strictEqual(Model.labelFor(3, {}, state), "acme")
  assert.strictEqual(Model.labelSource(3, {}, state), "projectspace")
})

test("a plain workspace shows its default", function() {
  assert.strictEqual(Model.labelFor(2, {}, state), "2")
  assert.strictEqual(Model.labelFor(10, null, null), "10")
  assert.strictEqual(Model.labelSource(2, {}, state), "default")
})

test("the name field's placeholder is what the label falls back to", function() {
  assert.strictEqual(Model.fallbackLabel(3, state), "acme")
  assert.strictEqual(Model.fallbackLabel(4, state), "4")
})

test("a vanished attachment still answers, flagged", function() {
  var p = Model.projectspaceFor(state, 9)
  assert.strictEqual(p.name, "gone")
  assert.strictEqual(p.missing, true)
  assert.strictEqual(p.ok, false)
  assert.strictEqual(Model.labelFor(9, {}, state), "gone")
})

test("no attachment, no projectspace", function() {
  assert.strictEqual(Model.projectspaceFor(state, 5), null)
  assert.strictEqual(Model.projectspaceFor(null, 3), null)
})

// ---------------------------------------------------------- attachments

test("attach options start with None", function() {
  var options = Model.attachOptions(state)
  assert.deepStrictEqual(options.map(function(o) { return o.name }), ["None", "acme", "Globex Corp"])
})

test("cycling walks None → each projectspace and wraps", function() {
  assert.strictEqual(Model.cycleAttachment(state, 5, 1), HOME + "/Projects/acme")
  assert.strictEqual(Model.cycleAttachment(state, 3, 1), HOME + "/Projects/globex")
  assert.strictEqual(Model.cycleAttachment(state, 3, -1), "")
  assert.strictEqual(Model.cycleAttachment(state, 5, -1), HOME + "/Projects/globex")
})

test("withAttachment attaches and detaches without touching the original", function() {
  var attached = Model.withAttachment(state, 5, HOME + "/Projects/globex")
  assert.strictEqual(Model.labelFor(5, {}, attached), "Globex Corp")
  assert.strictEqual(Model.projectspaceFor(state, 5), null)
  var detached = Model.withAttachment(attached, 3, "")
  assert.strictEqual(Model.projectspaceFor(detached, 3), null)
  assert.strictEqual(Model.labelFor(3, {}, state), "acme")
})

// ---------------------------------------------------------------- env

test("env rows put the notable keys first, tildified", function() {
  var out = Model.envRows(state.byHome[HOME + "/Projects/acme"].env, HOME, 0)
  assert.deepStrictEqual(out.rows.map(function(r) { return r.key }), ["BROWSER", "CLAUDE_CONFIG_DIR", "TEAM"])
  assert.strictEqual(out.rows[0].value, "~/.local/bin/chrome-acme")
  assert.strictEqual(out.hidden, 0)
})

test("env rows count what the limit hides", function() {
  var out = Model.envRows({ A: "1", B: "2", C: "3" }, HOME, 2)
  assert.strictEqual(out.rows.length, 2)
  assert.strictEqual(out.hidden, 1)
})

test("tildify only touches the home prefix", function() {
  assert.strictEqual(Model.tildify(HOME + "/x", HOME), "~/x")
  assert.strictEqual(Model.tildify(HOME, HOME), "~")
  assert.strictEqual(Model.tildify(HOME + "x/y", HOME), HOME + "x/y")
})

test("trust command comes from the not-trusted error", function() {
  assert.strictEqual(Model.trustCommand(state.byHome[HOME + "/Projects/globex"]),
    "mise trust " + HOME + "/Projects/globex/mise.toml")
  assert.strictEqual(Model.trustCommand(state.byHome[HOME + "/Projects/acme"]), "")
})

// --------------------------------------------------------------- strip

function ws(id, monitor, windows) { return { id: id, monitor: monitor, windows: windows } }

test("strip shows this monitor's occupied workspaces and the active one", function() {
  var all = [ws(1, "eDP-1", 0), ws(2, "DP-3", 2), ws(7, "DP-3", 1), ws(8, "DP-3", 0), ws(9, "eDP-1", 3)]
  assert.deepStrictEqual(Model.stripIds(all, "DP-3", 8), [2, 7, 8])
  assert.deepStrictEqual(Model.stripIds(all, "eDP-1", 1), [1, 9])
})

test("strip skips special workspaces", function() {
  assert.deepStrictEqual(Model.stripIds([ws(-98, "DP-3", 1), ws(3, "DP-3", 1)], "DP-3", -98), [3])
})

test("strip shows a second monitor's block, its own before visitors", function() {
  var all = [ws(9, "DP-3", 2), ws(12, "DP-3", 3), ws(19, "DP-3", 1), ws(20, "DP-3", 0), ws(8, "eDP-1", 4)]
  assert.deepStrictEqual(Model.stripIds(all, "DP-3", 20, 1), [12, 19, 20, 9])
  assert.deepStrictEqual(Model.stripIds(all, "DP-3", 20), [9, 12, 19, 20])
  assert.deepStrictEqual(Model.stripIds(all, "eDP-1", 8, 0), [8])
})

// ------------------------------------------------------------- blocks

test("ids map onto a block of ten per monitor", function() {
  assert.strictEqual(Model.blockOf(1), 0)
  assert.strictEqual(Model.blockOf(10), 0)
  assert.strictEqual(Model.blockOf(11), 1)
  assert.strictEqual(Model.blockOf(20), 1)
  assert.strictEqual(Model.slotOf(19), 9)
  assert.strictEqual(Model.slotOf(20), 10)
  assert.deepStrictEqual(Model.blockIds(1), [11, 12, 13, 14, 15, 16, 17, 18, 19, 20])
  assert.deepStrictEqual(Model.blockIds(0), Model.WORKSPACE_IDS)
})

test("labels and keys read as the slot in the block", function() {
  assert.strictEqual(Model.keyLabel(19), "9")
  assert.strictEqual(Model.keyLabel(20), "0")
  assert.strictEqual(Model.labelFor(19, {}, null), "9")
  assert.strictEqual(Model.labelFor(19, { "19": "Chat" }, null), "Chat")
  assert.strictEqual(Model.labelFor(9, { "19": "Chat" }, null), "9")
  assert.strictEqual(Model.fallbackLabel(12, null), "2")
})

test("Omarchy's block file maps plugged-in connectors", function() {
  var text = "0\teDP-1\tChimei Innolux Corporation N140JCN-GT1\n1\tDP-3\tDell Inc. DELL U2722DE 1CYWCH3\n2\t\tLG gone\n"
  assert.deepStrictEqual(Model.parseBlocks(text), { "eDP-1": 0, "DP-3": 1 })
  assert.deepStrictEqual(Model.parseBlocks(""), {})
  assert.deepStrictEqual(Model.parseBlocks("junk\nx\ty\tz"), {})
})

test("panel rows are the block, then visitors", function() {
  assert.deepStrictEqual(Model.panelIds(1, [9, 12, 3]), [11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 3, 9])
  assert.deepStrictEqual(Model.panelIds(0, []), Model.WORKSPACE_IDS)
})

test("renumber pairs parse, skipping junk and no-ops", function() {
  assert.deepStrictEqual(Model.parseRenumber("9:19 8:18"), { "9": "19", "8": "18" })
  assert.deepStrictEqual(Model.parseRenumber("9:9 x:1 0:3 4:5"), { "4": "5" })
  assert.deepStrictEqual(Model.parseRenumber(""), {})
})

test("renumbering moves entries, and a displaced one takes the freed id", function() {
  assert.deepStrictEqual(Model.renumbered({ "9": "a", "3": "b" }, { "9": "19" }), { "19": "a", "3": "b" })
  assert.deepStrictEqual(Model.renumbered({ "9": "a", "19": "c" }, { "9": "19" }), { "19": "a", "9": "c" })
  assert.deepStrictEqual(Model.renumbered({ "9": "a", "19": "c" }, { "9": "19", "19": "9" }), { "19": "a", "9": "c" })
  assert.deepStrictEqual(Model.renumbered({ "3": "b" }, { "9": "19" }), { "3": "b" })
})

test("strip keeps the active workspace before Hyprland lists it", function() {
  assert.deepStrictEqual(Model.stripIds([], "DP-3", 4), [4])
})

// ------------------------------------------------------------ keyboard

test("the cursor wraps over the ten rows", function() {
  assert.strictEqual(Model.moveCursor(10, 1), 1)
  assert.strictEqual(Model.moveCursor(1, -1), 10)
  assert.strictEqual(Model.moveCursor(4, 1), 5)
})

test("the cursor wraps over a second monitor's rows", function() {
  var rows = Model.panelIds(1, [9])
  assert.strictEqual(Model.moveCursor(20, 1, rows), 9)
  assert.strictEqual(Model.moveCursor(9, 1, rows), 11)
  assert.strictEqual(Model.moveCursor(11, -1, rows), 9)
})

test("digits name workspaces, 0 is ten", function() {
  assert.strictEqual(Model.workspaceForKey("7"), 7)
  assert.strictEqual(Model.workspaceForKey("0"), 10)
  assert.strictEqual(Model.workspaceForKey("a"), -1)
  assert.strictEqual(Model.keyLabel(10), "0")
})

test("digits name the monitor's own block", function() {
  assert.strictEqual(Model.workspaceForKey("7", 1), 17)
  assert.strictEqual(Model.workspaceForKey("0", 1), 20)
  assert.strictEqual(Model.workspaceForKey("3", 0), 3)
})

test("window counts read naturally", function() {
  assert.strictEqual(Model.windowsLabel(0), "empty")
  assert.strictEqual(Model.windowsLabel(1), "1 window")
  assert.strictEqual(Model.windowsLabel(4), "4 windows")
})

// ------------------------------------------------------------ windows

var WINDOWS = JSON.stringify({
  workspaces: [
    { ws: 8, saved: 1000, projectspace: "~/Projects/acme", missing: 2, windows: [
      { kind: "terminal", name: "herdr · ~/Projects/acme", open: false },
      { kind: "browser", name: "Browser", open: true },
      { kind: "app", name: "Slack", open: false }] },
    { ws: 2, saved: 900, projectspace: null, missing: 0, windows: [{ kind: "browser", name: "Browser", open: true }] }
  ]
})

test("the last session parses per workspace, with what is missing", function() {
  var session = Model.parseWindows(WINDOWS)
  assert.strictEqual(session.missing, 2)
  assert.strictEqual(Model.restoreFor(session, 8).windows.length, 3)
  assert.strictEqual(Model.restoreSummary(Model.restoreFor(session, 8)), "2 to reopen")
  assert.strictEqual(Model.restoreSummary(Model.restoreFor(session, 2)), "all open")
  assert.strictEqual(Model.restoreFor(session, 5), null)
  assert.strictEqual(Model.restoreFor(session, 8).saved, 1000)
})

test("no or broken window data is an empty session", function() {
  assert.strictEqual(Model.parseWindows("").missing, 0)
  assert.deepStrictEqual(Model.parseWindows("{oops").workspaces, [])
  assert.deepStrictEqual(Model.parseWindows('{"workspaces":[]}').workspaces, [])
  assert.strictEqual(Model.restoreSummary(null), "")
})

test("snapshot age reads naturally", function() {
  assert.strictEqual(Model.savedLabel(null, 100), "")
  assert.strictEqual(Model.savedLabel(1000, 1010), "just now")
  assert.strictEqual(Model.savedLabel(1000, 1000 + 25 * 60), "25 min ago")
  assert.strictEqual(Model.savedLabel(1000, 1000 + 5 * 3600), "5 h ago")
  assert.strictEqual(Model.savedLabel(1000, 1000 + 30 * 3600), "yesterday")
  assert.strictEqual(Model.savedLabel(1000, 1000 + 72 * 3600), "3 days ago")
})

test("what is open now comes per workspace, empty ones as null", function() {
  var session = Model.parseWindows(JSON.stringify({ workspaces: [], live: {
    "9": { layout: "scrolling", monitor: null, windows: [{ address: "0x1", at: [0, 0], size: [10, 10] }] },
    "3": { layout: "dwindle", monitor: null, windows: [] } } }))
  assert.strictEqual(Model.liveFor(session, 9).layout, "scrolling")
  assert.strictEqual(Model.liveFor(session, 3), null)
  assert.strictEqual(Model.liveFor(Model.parseWindows(""), 9), null)
  assert.strictEqual(Model.layoutLabel("scrolling"), "Scrolling")
  assert.strictEqual(Model.layoutLabel(""), "")
})

test("the layout draws the screen and every window, scrolled-off columns too", function() {
  var entry = {
    layout: "scrolling",
    monitor: { name: "DP-3", x: -2000, y: 0, width: 2000, height: 1000, reserved: [0, 0, 0, 0] },
    windows: [
      { address: "0xa", at: [-4000, 0], size: [2000, 1000], focus: 3, name: "Browser" },
      { address: "0xb", at: [-2000, 0], size: [2000, 1000], focus: 1, name: "foot" },
      { address: "0xc", at: [-1500, 200], size: [400, 300], floating: true, focus: 2, name: "Calc" }
    ]
  }
  var d = Model.layoutBoxes(entry, 400, 1000)
  assert.deepStrictEqual([d.width, d.height], [400, 100])
  assert.deepStrictEqual(d.view, { x: 200, y: 0, w: 200, h: 100 })
  assert.deepStrictEqual([d.boxes[0].x, d.boxes[0].w], [0, 200])
  assert.strictEqual(d.boxes[1].focused, true)
  assert.strictEqual(d.boxes[2].floating, true)
  assert.deepStrictEqual(Model.layoutBoxes(entry, 400, 50).height, 50)
  assert.deepStrictEqual(Model.layoutBoxes(null, 400, 50).boxes, [])
})

test("monitors get short names", function() {
  assert.deepStrictEqual(Model.monitorLabels([
    { name: "eDP-1", make: "Chimei Innolux Corporation", model: "N140JCN-GT1" },
    { name: "DP-3", make: "Dell Inc.", model: "DELL U2722DE" }
  ]), { "eDP-1": "Laptop", "DP-3": "Dell" })
  assert.deepStrictEqual(Model.monitorLabels([
    { name: "DP-1", make: "Dell Inc.", model: "U2722DE" },
    { name: "DP-2", make: "DELL", model: "P2419H" },
    { name: "HDMI-A-1", make: "", model: "" }
  ]), { "DP-1": "U2722DE", "DP-2": "P2419H", "HDMI-A-1": "HDMI-A-1" })
})

test("monitors show as glyphs, named only when two share one", function() {
  var one = Model.monitorBadges([
    { name: "eDP-1", make: "Chimei Innolux Corporation", model: "N140JCN-GT1" },
    { name: "DP-3", make: "Dell Inc.", model: "DELL U2722DE" }
  ])
  assert.deepStrictEqual(one["eDP-1"], { icon: "\uf109", label: "Laptop", text: "\uf109" })
  assert.deepStrictEqual(one["DP-3"], { icon: "\uf108", label: "Dell", text: "\uf108" })
  var two = Model.monitorBadges([
    { name: "eDP-1", make: "BOE", model: "x" },
    { name: "DP-1", make: "Dell Inc.", model: "U2722DE" },
    { name: "HDMI-A-1", make: "LG Electronics", model: "27UL850" }
  ])
  assert.strictEqual(two["eDP-1"].text, "\uf109")
  assert.strictEqual(two["DP-1"].text, "\uf108 Dell")
  assert.strictEqual(two["HDMI-A-1"].text, "\uf108 LG")
})

var SCREENS = "0\teDP-1\tChimei Innolux Corporation N140JCN-GT1\n1\tDP-3\tDell Inc. DELL U2722DE 1CYWCH3\n2\t\tLG Electronics 27UL850 123\n"
var BADGES = Model.monitorBadges([
  { name: "eDP-1", make: "Chimei Innolux Corporation", model: "N140JCN-GT1" },
  { name: "DP-3", make: "Dell Inc.", model: "DELL U2722DE" }
])

test("parseScreens keeps every monitor seen, plugged or not, by block", function() {
  var screens = Model.parseScreens(SCREENS)
  assert.deepStrictEqual(screens.map(function(s) { return [s.block, s.connector] }), [[0, "eDP-1"], [1, "DP-3"], [2, ""]])
  assert.strictEqual(screens[2].identity, "LG Electronics 27UL850 123")
  assert.deepStrictEqual(Model.parseScreens("junk\n\n"), [])
})

test("screen tabs: plugged monitors, and unplugged ones only while they hold something", function() {
  var screens = Model.parseScreens(SCREENS)
  var tabs = Model.screenTabs(screens, BADGES, [3, 19])
  assert.deepStrictEqual(tabs.map(function(t) { return t.label }), ["Laptop", "Dell"])
  assert.deepStrictEqual(tabs.map(function(t) { return t.plugged }), [true, true])
  var kept = Model.screenTabs(screens, BADGES, [22])
  assert.deepStrictEqual(kept[2], { block: 2, connector: "", plugged: false, icon: "\uf108", label: "LG" })
})

test("nextTab wraps both ways, and an unknown block lands on the first", function() {
  var tabs = Model.screenTabs(Model.parseScreens(SCREENS), BADGES, [22])
  assert.strictEqual(Model.nextTab(tabs, 0, 1), 1)
  assert.strictEqual(Model.nextTab(tabs, 2, 1), 0)
  assert.strictEqual(Model.nextTab(tabs, 0, -1), 2)
  assert.strictEqual(Model.nextTab(tabs, 7, 1), 0)
  assert.strictEqual(Model.tabFor(tabs, 1).label, "Dell")
  assert.strictEqual(Model.tabFor(tabs, 5), null)
})

test("pairedIds lists the project's workspaces on the other screens", function() {
  var state = Model.parseList(JSON.stringify({
    projectspaces: [{ name: "horizon", home: "/h/horizon", folder: "horizon", ok: true }],
    attachments: { "1": { home: "/h/horizon" }, "4": { home: "/h/horizon" }, "19": { home: "/h/horizon" }, "12": { home: "/h/other" } }
  }))
  assert.deepStrictEqual(Model.pairedIds(state, 1), [19])
  assert.deepStrictEqual(Model.pairedIds(state, 19), [1, 4])
  assert.deepStrictEqual(Model.pairedIds(state, 12), [])
  assert.deepStrictEqual(Model.pairedIds(state, 5), [])
})

console.log(passes + " passed, " + failures + " failed")
process.exit(failures === 0 ? 0 : 1)

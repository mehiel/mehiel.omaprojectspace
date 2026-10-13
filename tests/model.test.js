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

test("strip skips special and out-of-range workspaces", function() {
  assert.deepStrictEqual(Model.stripIds([ws(-98, "DP-3", 1), ws(11, "DP-3", 1), ws(3, "DP-3", 1)], "DP-3", -98), [3])
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

test("digits name workspaces, 0 is ten", function() {
  assert.strictEqual(Model.workspaceForKey("7"), 7)
  assert.strictEqual(Model.workspaceForKey("0"), 10)
  assert.strictEqual(Model.workspaceForKey("a"), -1)
  assert.strictEqual(Model.keyLabel(10), "0")
})

test("window counts read naturally", function() {
  assert.strictEqual(Model.windowsLabel(0), "empty")
  assert.strictEqual(Model.windowsLabel(1), "1 window")
  assert.strictEqual(Model.windowsLabel(4), "4 windows")
})

console.log(passes + " passed, " + failures + " failed")
process.exit(failures === 0 ? 0 : 1)

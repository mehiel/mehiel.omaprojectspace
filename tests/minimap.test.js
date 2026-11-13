// node tests/minimap.test.js
// The minimap's geometry: columns, stacks, groups, scrolled-off columns.

var assert = require("assert")
var Mini = require("../Minimap.js")

function top(address, ws, x, y, w, h, extra) {
  var ipc = { address: address, workspace: { id: ws }, at: [x, y], size: [w, h], class: "app", mapped: true }
  for (var k in extra || {}) ipc[k] = extra[k]
  return { address: address, title: "t" + address, lastIpcObject: ipc }
}

var monitor = { x: 0, y: 0, width: 1000, height: 500 }
var tops = [
  top("0xb", 1, 500, 0, 500, 250), top("0xc", 1, 500, 250, 500, 250),   // a stacked column
  top("0xa", 1, 0, 0, 500, 500),
  top("0xd", 1, 1000, 0, 500, 500),                                       // scrolled off
  top("0xe", 2, 0, 0, 500, 500),                                          // another workspace
  top("0xf", 1, 100, 100, 200, 200, { floating: true })
]

var clients = Mini.eligibleClients(tops, 1, false, null)
assert.deepStrictEqual(clients.map(function(c) { return c.address }).sort(), ["0xa", "0xb", "0xc", "0xd"])
assert.strictEqual(Mini.eligibleClients(tops, 1, true, null).length, 5)
assert.strictEqual(Mini.eligibleClients(tops, 1, false, { "0xa": true }).length, 1)

var cols = Mini.buildColumns(clients, monitor, false, "0xc")
assert.strictEqual(cols.length, 3)
assert.deepStrictEqual(cols[1].windows.map(function(w) { return w.address }), ["0xb", "0xc"])
assert.strictEqual(cols[1].windows[1].focused, true)
assert.strictEqual(cols[2].onScreen, false)

var tape = Mini.layoutTape(cols, { scale: 0.04, gap: 3, stackGap: 3 })
assert.strictEqual(tape.items.length, 4)
assert.strictEqual(tape.total, 20 * 3 + 3 * 2)
assert.strictEqual(tape.items[0].bh, 20)
assert.ok(tape.items[1].bh < 10 && tape.items[2].by > 10)

// A group: one box, the focused tab shown.
var grouped = [
  top("0x1", 1, 0, 0, 500, 500, { grouped: ["0x1", "0x2"], focusHistoryID: 3 }),
  top("0x2", 1, 0, 0, 500, 500, { grouped: ["0x1", "0x2"], focusHistoryID: 1 })
]
var gcols = Mini.buildColumns(Mini.eligibleClients(grouped, 1, false, null), monitor, false, "")
assert.strictEqual(gcols.length, 1)
assert.strictEqual(gcols[0].windows.length, 1)
assert.strictEqual(gcols[0].windows[0].address, "0x2")
assert.strictEqual(Mini.keyFor(gcols, "0x1"), gcols[0].windows[0].key)
assert.strictEqual(Mini.urgentAddress("abc123"), "0xabc123")

console.log("minimap: all passed")

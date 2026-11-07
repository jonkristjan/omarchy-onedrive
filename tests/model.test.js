// Tests for Model.js. Run: node tests/model.test.js
const assert = require("assert")
const M = require("../Model.js")

assert.strictEqual(M.bytes(1610612736), "1.5 GB")
assert.strictEqual(M.bytes(512), "512 B")
assert.strictEqual(M.count(2657, "file", "files"), "2,657 files")
assert.strictEqual(M.count(1, "file", "files"), "1 file")
assert.strictEqual(M.duration(282), "4m 42s")
assert.strictEqual(M.duration(137000), "1d 14h")
assert.strictEqual(M.ago(1000 - 30, 1000), "just now")
assert.strictEqual(M.ago(10000 - 7200, 10000), "2h ago")
assert.strictEqual(M.ago(0, 1000), "")
assert.strictEqual(M.basename("Work/Finances/a.xlsx"), "a.xlsx")
assert.strictEqual(M.dirname("Work/Finances/a.xlsx"), "Work/Finances")
assert.strictEqual(M.state("transferring").glyph, "\u{F063F}")
assert.strictEqual(M.state("nonsense").label, "Unknown")
assert.strictEqual(M.parseStatus("not json").ok, false)
assert.strictEqual(
  M.activityCaption({ kind: "download", path: "Work/a.xlsx", ts: 970, ok: true }, 1000),
  "Downloaded · Work · just now")
assert.strictEqual(
  M.activityCaption({ kind: "upload", path: "a.docx", ts: 970, ok: false }, 1000),
  "Failed · just now")
console.log("model.test.js: all passed")

// Pure formatting for the OneDrive panel. No QML, so it can be tested with node.

function parseStatus(raw) {
  try {
    var parsed = JSON.parse(String(raw || "").trim())
    return parsed && typeof parsed === "object" ? parsed : { ok: false }
  } catch (e) {
    return { ok: false }
  }
}

// What the bar icon and the hero say for each overall status.
var STATES = {
  ok:           { glyph: "\u{F015F}", label: "Up to date",      tone: "normal" },
  checking:     { glyph: "\u{F015F}", label: "Checking for changes", tone: "normal" },
  transferring: { glyph: "\u{F063F}", label: "Syncing files",   tone: "normal" },
  starting:     { glyph: "\u{F015F}", label: "Starting",        tone: "dim" },
  offline:      { glyph: "\u{F0164}", label: "Offline",         tone: "dim" },
  warning:      { glyph: "\u{F09E0}", label: "Some items failed to sync", tone: "urgent" },
  failed:       { glyph: "\u{F09E0}", label: "Service failed",  tone: "urgent" },
  stopped:      { glyph: "\u{F015F}", label: "Off",             tone: "dim" }
}

function state(status) {
  return STATES[status] || { glyph: "\u{F015F}", label: "Unknown", tone: "dim" }
}

function ago(ts, nowSec) {
  var then = Number(ts)
  if (!isFinite(then) || then <= 0) return ""
  var delta = Math.max(0, Math.floor(nowSec - then))
  if (delta < 60) return "just now"
  if (delta < 3600) return Math.floor(delta / 60) + "m ago"
  if (delta < 86400) return Math.floor(delta / 3600) + "h ago"
  return Math.floor(delta / 86400) + "d ago"
}

function duration(seconds) {
  var s = Math.max(0, Math.floor(Number(seconds) || 0))
  if (s < 60) return s + "s"
  if (s < 3600) return Math.floor(s / 60) + "m " + (s % 60) + "s"
  if (s < 86400) return Math.floor(s / 3600) + "h " + Math.floor((s % 3600) / 60) + "m"
  return Math.floor(s / 86400) + "d " + Math.floor((s % 86400) / 3600) + "h"
}

function bytes(n) {
  var v = Number(n) || 0
  var units = ["B", "KB", "MB", "GB", "TB"]
  var i = 0
  // Binary steps, so the memory limit reads as systemd states it (MemoryHigh=1536M is 1.5 GB).
  while (v >= 1024 && i < units.length - 1) { v /= 1024; i++ }
  return (i === 0 || v >= 100 ? Math.round(v) : v.toFixed(1)) + " " + units[i]
}

function count(n, one, many) {
  var v = Number(n) || 0
  var digits = String(Math.round(v)).replace(/\B(?=(\d{3})+(?!\d))/g, ",")
  return digits + " " + (v === 1 ? one : many)
}

function basename(path) {
  var parts = String(path || "").split("/")
  return parts[parts.length - 1] || String(path || "")
}

function dirname(path) {
  var parts = String(path || "").split("/")
  parts.pop()
  return parts.join("/")
}

var ACTIVITY_GLYPHS = { upload: "\u{F0552}", download: "\u{F01DA}", delete: "\u{F01B4}" }
var ACTIVITY_VERBS = { upload: "Uploaded", download: "Downloaded", delete: "Deleted online" }

function activityGlyph(kind) { return ACTIVITY_GLYPHS[kind] || "\u{F0219}" }

function activityCaption(item, nowSec) {
  if (!item) return ""
  var verb = item.ok === false ? "Failed" : (ACTIVITY_VERBS[item.kind] || "")
  var dir = dirname(item.path)
  return [verb, dir, ago(item.ts, nowSec)].filter(function (p) { return p !== "" }).join(" · ")
}

// "Synced 3m ago · took 4m 42s"
function lastSyncLine(client, nowSec) {
  if (!client || !client.lastSuccessAt) return "Not yet"
  var parts = [ago(client.lastSuccessAt, nowSec)]
  if (client.lastCycle && client.lastCycle.durationSec) parts.push("took " + duration(client.lastCycle.durationSec))
  return parts.join(" · ")
}

function memoryLine(service) {
  if (!service || !service.memoryBytes) return ""
  return bytes(service.memoryBytes) + (service.memoryHigh ? " of " + bytes(service.memoryHigh) : "")
}

if (typeof module !== "undefined") {
  module.exports = {
    parseStatus: parseStatus, state: state, ago: ago, duration: duration, bytes: bytes,
    count: count, basename: basename, dirname: dirname, activityGlyph: activityGlyph,
    activityCaption: activityCaption, lastSyncLine: lastSyncLine, memoryLine: memoryLine
  }
}

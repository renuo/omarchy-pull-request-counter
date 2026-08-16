.pragma library

// Pure helpers for the pull-request widget: group metadata, the shaping of the
// helper script's JSON into what the panel renders, and label formatting.
// Keeping them here (rather than in Panel.qml) means the QML files stay
// declarative and this logic is testable with plain `qs`-free JavaScript.

// Group order and copy follow renuo/github-pull-request-counter's popup, so a
// user moving from the browser extension to the bar reads the same list in the
// same order. Glyphs are Nerd Font (Font Awesome) code points.
var GROUPS = [
  { key: "reviewRequested",     label: "I must review",       glyph: "\uf06e" },
  { key: "teamReviewRequested", label: "My team must review", glyph: "\uf0c0" },
  { key: "noReviewRequested",   label: "No review requested", glyph: "\uf017" },
  { key: "allReviewsDone",      label: "All reviews done",    glyph: "\uf00c" },
  { key: "missingAssignee",     label: "Missing assignee",    glyph: "\uf234" },
  { key: "allAssigned",         label: "Assigned to me",      glyph: "\uf007" }
]

var GITHUB_GLYPH = "\uf09b"

// Everything but "Assigned to me", matching the extension's default counter
// checkboxes: an assigned pull request is already counted by the group that
// says what it needs, so counting it again would just inflate the badge.
var DEFAULT_COUNT_GROUPS = "reviewRequested,teamReviewRequested,noReviewRequested,allReviewsDone,missingAssignee"

function groupKeys() {
  var keys = []
  for (var i = 0; i < GROUPS.length; i++) keys.push(GROUPS[i].key)
  return keys
}

// Cursor order for the options form, top to bottom. Qt's Tab traversal does
// not reach into these layer-shell panels, so the form is driven by the same
// j/k cursor as the pull request list — and this is the single place that
// decides what "next row" means. Every option row names itself here rather
// than hard-coding a number.
var OPTION_ORDER = [
  "count:reviewRequested",
  "count:teamReviewRequested",
  "count:noReviewRequested",
  "count:allReviewsDone",
  "count:missingAssignee",
  "count:allAssigned",
  "teams",
  "scope",
  "maximumAgeDays",
  "ignoredPrs",
  "ignoredTitles",
  "urgentThreshold",
  "refreshIntervalSec",
  "resultLimit",
  "hideWhenEmpty"
]

function optionIndexOf(name) {
  return OPTION_ORDER.indexOf(name)
}

function optionCount() {
  return OPTION_ORDER.length
}

function groupMeta(key) {
  for (var i = 0; i < GROUPS.length; i++) {
    if (GROUPS[i].key === key) return GROUPS[i]
  }
  return { key: key, label: key, glyph: "\uf09b" }
}

// The helper script emits groups in GROUPS order already, but it is the only
// thing standing between untrusted-ish JSON and the view, so rebuild the list
// from GROUPS rather than trusting whatever order (or keys) arrived.
function parse(raw) {
  var payload
  try {
    payload = JSON.parse(raw || "{}")
  } catch (e) {
    return { ok: false, login: "", error: "Could not read the pull request helper output", hint: "", groups: [] }
  }

  var byKey = {}
  var incoming = payload.groups || []
  for (var i = 0; i < incoming.length; i++) {
    if (incoming[i] && incoming[i].key) byKey[incoming[i].key] = incoming[i].prs || []
  }

  var groups = []
  for (var g = 0; g < GROUPS.length; g++) {
    groups.push({
      key: GROUPS[g].key,
      label: GROUPS[g].label,
      glyph: GROUPS[g].glyph,
      prs: byKey[GROUPS[g].key] || []
    })
  }

  return {
    ok: payload.ok === true,
    login: String(payload.login || ""),
    error: String(payload.error || ""),
    hint: String(payload.hint || ""),
    groups: groups
  }
}

function emptyResult() {
  return { ok: true, login: "", error: "", hint: "", groups: parse("{}").groups }
}

// `countGroups` is a comma separated list of group keys, mirroring the
// extension's per-category counter checkboxes. An empty setting counts nothing
// rather than everything: silently counting a group the user removed would be
// the one behavior they cannot undo from the setting.
//
// Distinct by URL, unlike the extension, which sums the selected categories.
// The groups overlap by design, so summing turns on "Assigned to me" and
// silently double-counts every pull request already listed under a more
// specific group. The badge is a count of pull requests; it should be one.
function countedTotal(groups, countGroups) {
  var wanted = splitList(countGroups)
  var seen = {}
  var total = 0
  for (var i = 0; i < groups.length; i++) {
    if (wanted.indexOf(groups[i].key) === -1) continue
    for (var j = 0; j < groups[i].prs.length; j++) {
      var pr = groups[i].prs[j]
      if (pr.ignored) continue
      var url = String(pr.url || "")
      if (seen[url]) continue
      seen[url] = true
      total += 1
    }
  }
  return total
}

// ------------------------------------------------------------------ ignoring

function ignoreKey(pr) {
  if (!pr) return ""
  return String(pr.repo || "") + "#" + String(pr.number || "")
}

// Compiled once per call rather than per pull request. Returns null for an
// empty or unparseable pattern; `regexError` is what tells the user why.
function titleMatcher(ignoredTitles) {
  var pattern = String(ignoredTitles || "").replace(/^\s+|\s+$/g, "")
  if (pattern === "") return null
  try {
    return new RegExp(pattern)
  } catch (e) {
    return null
  }
}

function regexError(ignoredTitles) {
  var pattern = String(ignoredTitles || "").replace(/^\s+|\s+$/g, "")
  if (pattern === "") return ""
  try {
    new RegExp(pattern)
    return ""
  } catch (e) {
    return "Invalid regular expression: " + String(e.message || e)
  }
}

// Flags rather than filters: the extension keeps ignored pull requests visible
// in the popup and only drops them from the counter, so they stay one click
// away instead of vanishing into a setting the user has to remember editing.
function applyIgnores(groups, ignoredPrs, ignoredTitles) {
  var keys = splitList(ignoredPrs)
  var matcher = titleMatcher(ignoredTitles)
  if (keys.length === 0 && matcher === null) return groups

  var out = []
  for (var i = 0; i < groups.length; i++) {
    var prs = []
    for (var j = 0; j < groups[i].prs.length; j++) {
      var pr = groups[i].prs[j]
      var ignored = keys.indexOf(ignoreKey(pr)) !== -1
        || (matcher !== null && matcher.test(String(pr.title || "")))
      prs.push(ignored === (pr.ignored === true) ? pr : shallowCopyWithIgnored(pr, ignored))
    }
    out.push({ key: groups[i].key, label: groups[i].label, glyph: groups[i].glyph, prs: prs })
  }
  return out
}

function shallowCopyWithIgnored(pr, ignored) {
  var copy = {}
  for (var key in pr) copy[key] = pr[key]
  copy.ignored = ignored
  return copy
}

function ignoredCount(groups) {
  var seen = {}
  var total = 0
  for (var i = 0; i < groups.length; i++) {
    for (var j = 0; j < groups[i].prs.length; j++) {
      if (!groups[i].prs[j].ignored) continue
      var url = String(groups[i].prs[j].url || "")
      if (seen[url]) continue
      seen[url] = true
      total += 1
    }
  }
  return total
}

// Add or remove one entry in a comma separated setting, preserving the order
// the user typed the rest in.
function toggleInList(value, entry) {
  var list = splitList(value)
  var index = list.indexOf(entry)
  if (index === -1) list.push(entry)
  else list.splice(index, 1)
  return list.join(",")
}

function listContains(value, entry) {
  return splitList(value).indexOf(entry) !== -1
}

function splitList(value) {
  var parts = String(value || "").split(",")
  var out = []
  for (var i = 0; i < parts.length; i++) {
    var trimmed = parts[i].replace(/^\s+|\s+$/g, "")
    if (trimmed.length > 0) out.push(trimmed)
  }
  return out
}

function nonEmptyGroups(groups) {
  var out = []
  for (var i = 0; i < groups.length; i++) {
    if (groups[i].prs.length > 0) out.push(groups[i])
  }
  return out
}

// Flat, in-render-order list of every pull request on screen. The panel's
// keyboard cursor indexes into this, so it walks rows across group boundaries
// without any group having to know where it sits.
function flatten(groups) {
  var out = []
  for (var i = 0; i < groups.length; i++) {
    for (var j = 0; j < groups[i].prs.length; j++) out.push(groups[i].prs[j])
  }
  return out
}

function groupOffset(groups, groupIndex) {
  var offset = 0
  for (var i = 0; i < groupIndex && i < groups.length; i++) offset += groups[i].prs.length
  return offset
}

// Distinct pull requests across every group. The groups deliberately overlap —
// a pull request assigned to you with its reviews in shows up under both
// "All reviews done" and "Assigned to me" — so summing group sizes would
// report a number larger than the list the user is looking at.
function totalCount(groups) {
  var seen = {}
  var total = 0
  for (var i = 0; i < groups.length; i++) {
    for (var j = 0; j < groups[i].prs.length; j++) {
      var url = String(groups[i].prs[j].url || "")
      if (seen[url]) continue
      seen[url] = true
      total += 1
    }
  }
  return total
}

function titleFor(pr) {
  if (!pr) return ""
  return "#" + pr.number + "  " + String(pr.title || "")
}

function metaFor(pr) {
  if (!pr) return ""
  var parts = [String(pr.repo || "")]
  if (pr.author) parts.push("@" + pr.author)
  parts.push(ageText(pr.ageInDays))
  if (pr.draft) parts.push("draft")
  if (pr.ignored) parts.push("ignored")
  return parts.join("  ·  ")
}

function ageText(days) {
  var n = Number(days)
  if (!isFinite(n) || n < 1) return "today"
  if (n < 7) return Math.round(n) + "d"
  if (n < 30) return Math.round(n / 7) + "w"
  if (n < 365) return Math.round(n / 30) + "mo"
  return (Math.round(n / 36.5) / 10) + "y"
}

function heroMeta(result, total, ignored, refreshing) {
  if (refreshing && total === 0) return "Loading…"
  if (!result.ok) return "Not connected"
  var parts = []
  if (result.login) parts.push("@" + result.login)
  // The long form only fits while it is the last thing on the line; once an
  // ignored count joins it, the hero elides mid-word instead.
  if (ignored > 0) {
    parts.push(total + " open")
    parts.push(ignored + " ignored")
  } else {
    parts.push(total === 1 ? "1 open pull request" : total + " open pull requests")
  }
  return parts.join("  ·  ")
}

// Qt.resolvedUrl() hands back a file:// URL, but Process wants a plain path.
function pathFromUrl(url) {
  var s = String(url || "")
  if (s.indexOf("file://") === 0) s = s.substring(7)
  try {
    return decodeURIComponent(s)
  } catch (e) {
    return s
  }
}

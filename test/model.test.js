const { describe, it } = require("node:test")
const assert = require("node:assert/strict")
const { loadModel } = require("./load-model")

const Model = loadModel()

// Values built inside the vm context carry that context's prototypes, which
// deepStrictEqual would reject; compare their JSON shape instead.
const plain = (value) => JSON.parse(JSON.stringify(value))

function pr(overrides) {
  return Object.assign({ url: "https://github.com/o/r/pull/1", repo: "o/r", number: 1, title: "Fix" }, overrides)
}

function groupsWith(prsByKey) {
  return Model.GROUPS.map((g) => ({ key: g.key, label: g.label, glyph: g.glyph, prs: prsByKey[g.key] || [] }))
}

describe("groups and options", () => {
  it("lists the group keys in display order", () => {
    assert.deepEqual(plain(Model.groupKeys()), [
      "reviewRequested",
      "teamReviewRequested",
      "noReviewRequested",
      "allReviewsDone",
      "missingAssignee",
      "allAssigned",
    ])
  })

  it("counts every group except allAssigned by default", () => {
    assert.equal(Model.DEFAULT_COUNT_GROUPS, Model.groupKeys().filter((k) => k !== "allAssigned").join(","))
  })

  it("finds metadata for a known group", () => {
    assert.equal(Model.groupMeta("allAssigned").label, "Assigned to me")
  })

  it("falls back to the key and the GitHub glyph for an unknown group", () => {
    assert.deepEqual(plain(Model.groupMeta("bogus")), { key: "bogus", label: "bogus", glyph: Model.GITHUB_GLYPH })
  })

  it("orders the options form", () => {
    assert.equal(Model.optionIndexOf("count:reviewRequested"), 0)
    assert.equal(Model.optionIndexOf("hideWhenEmpty"), Model.optionCount() - 1)
    assert.equal(Model.optionIndexOf("missing"), -1)
  })
})

describe("parse", () => {
  it("rebuilds groups in GROUPS order and drops unknown keys", () => {
    const result = Model.parse(JSON.stringify({
      ok: true,
      login: "me",
      groups: [
        { key: "allAssigned", prs: [pr()] },
        { key: "bogus", prs: [pr()] },
        null,
        { key: "reviewRequested" },
      ],
    }))
    assert.equal(result.ok, true)
    assert.equal(result.login, "me")
    assert.deepEqual(plain(result.groups.map((g) => g.key)), plain(Model.groupKeys()))
    assert.equal(result.groups[0].prs.length, 0)
    assert.equal(result.groups[5].prs.length, 1)
    assert.equal(result.groups[5].label, "Assigned to me")
  })

  it("carries error and hint through", () => {
    const result = Model.parse(JSON.stringify({ ok: false, error: "boom", hint: "do this" }))
    assert.equal(result.ok, false)
    assert.equal(result.error, "boom")
    assert.equal(result.hint, "do this")
    assert.equal(result.groups.length, Model.GROUPS.length)
  })

  it("treats anything but literal true as not ok", () => {
    assert.equal(Model.parse(JSON.stringify({ ok: "true" })).ok, false)
  })

  it("treats empty input as an empty, not-ok payload", () => {
    const result = Model.parse("")
    assert.equal(result.ok, false)
    assert.equal(result.error, "")
  })

  it("reports unparseable output", () => {
    const result = Model.parse("not json")
    assert.equal(result.ok, false)
    assert.equal(result.error, "Could not read the pull request helper output")
    assert.equal(result.groups.length, 0)
  })

  it("starts from an ok result with every group empty", () => {
    const result = Model.emptyResult()
    assert.equal(result.ok, true)
    assert.deepEqual(plain(result.groups.map((g) => g.prs.length)), [0, 0, 0, 0, 0, 0])
  })
})

describe("counting", () => {
  const shared = pr({ url: "u1" })
  const groups = groupsWith({
    reviewRequested: [shared, pr({ url: "u2" })],
    allReviewsDone: [pr({ url: "u3" })],
    allAssigned: [shared, pr({ url: "u3" }), pr({ url: "u4" })],
  })

  it("counts distinct pull requests across all groups", () => {
    assert.equal(Model.totalCount(groups), 4)
  })

  it("counts only the selected groups, once per pull request", () => {
    assert.equal(Model.countedTotal(groups, "reviewRequested, allAssigned"), 4)
    assert.equal(Model.countedTotal(groups, "reviewRequested"), 2)
    assert.equal(Model.countedTotal(groups, Model.DEFAULT_COUNT_GROUPS), 3)
  })

  it("counts nothing when no group is selected", () => {
    assert.equal(Model.countedTotal(groups, ""), 0)
  })

  it("leaves ignored pull requests out of the count", () => {
    const flagged = Model.applyIgnores(groups, "o/r#1", "")
    assert.equal(Model.countedTotal(flagged, "allAssigned"), 0)
    assert.equal(Model.ignoredCount(flagged), 4)
  })

  it("counts no ignored pull requests when none are flagged", () => {
    assert.equal(Model.ignoredCount(groups), 0)
  })

  it("treats a missing url as one shared key", () => {
    const anonymous = groupsWith({ allAssigned: [{ number: 1 }, { number: 2 }] })
    assert.equal(Model.totalCount(anonymous), 1)
    assert.equal(Model.countedTotal(anonymous, "allAssigned"), 1)
  })
})

describe("ignoring", () => {
  it("builds the owner/repo#number key", () => {
    assert.equal(Model.ignoreKey(pr({ repo: "renuo/app", number: 42 })), "renuo/app#42")
    assert.equal(Model.ignoreKey({}), "#")
    assert.equal(Model.ignoreKey(null), "")
  })

  it("returns the same groups when there is nothing to ignore", () => {
    const groups = groupsWith({ allAssigned: [pr()] })
    assert.equal(Model.applyIgnores(groups, " , ", "  "), groups)
  })

  it("flags pull requests by key without touching the originals", () => {
    const original = pr({ repo: "o/r", number: 7 })
    const other = pr({ repo: "o/r", number: 8, url: "u8" })
    const out = Model.applyIgnores(groupsWith({ allAssigned: [original, other] }), "o/r#7", "")
    const prs = out[5].prs
    assert.equal(prs[0].ignored, true)
    assert.equal(prs[0].title, "Fix")
    assert.equal(original.ignored, undefined)
    assert.equal(prs[1], other)
    assert.equal(out[5].label, "Assigned to me")
  })

  it("flags pull requests whose title matches the pattern", () => {
    const out = Model.applyIgnores(groupsWith({ allAssigned: [pr({ title: "WIP: thing" }), pr({ title: "Real" }), pr({ title: undefined })] }), "", "^WIP")
    assert.deepEqual(plain(out[5].prs.map((p) => p.ignored === true)), [true, false, false])
  })

  it("matches titles case sensitively", () => {
    const out = Model.applyIgnores(groupsWith({ allAssigned: [pr({ title: "wip: thing" })] }), "", "^WIP")
    assert.equal(out[5].prs[0].ignored, undefined)
  })

  it("clears a stale ignored flag", () => {
    const stale = pr({ ignored: true })
    const out = Model.applyIgnores(groupsWith({ allAssigned: [stale] }), "other/repo#1", "")
    assert.equal(out[5].prs[0].ignored, false)
    assert.equal(stale.ignored, true)
  })

  it("ignores an invalid title pattern instead of throwing", () => {
    assert.equal(Model.titleMatcher("("), null)
    assert.equal(Model.titleMatcher(""), null)
    assert.equal(Model.titleMatcher(" x ").source, "x")
  })

  it("explains an invalid title pattern", () => {
    assert.match(Model.regexError("("), /^Invalid regular expression: /)
    assert.equal(Model.regexError("^ok$"), "")
    assert.equal(Model.regexError(undefined), "")
  })
})

describe("comma separated settings", () => {
  it("splits and trims, dropping empty entries", () => {
    assert.deepEqual(plain(Model.splitList(" a, ,b ,")), ["a", "b"])
    assert.deepEqual(plain(Model.splitList(null)), [])
  })

  it("adds a missing entry at the end", () => {
    assert.equal(Model.toggleInList("a, b", "c"), "a,b,c")
  })

  it("removes a present entry and keeps the rest in order", () => {
    assert.equal(Model.toggleInList("a,b,c", "b"), "a,c")
  })

  it("checks membership", () => {
    assert.equal(Model.listContains("a, b", "b"), true)
    assert.equal(Model.listContains("a, b", "c"), false)
  })
})

describe("list layout", () => {
  const groups = groupsWith({ reviewRequested: [pr({ url: "a" })], allAssigned: [pr({ url: "b" }), pr({ url: "c" })] })

  it("keeps only groups with pull requests", () => {
    assert.deepEqual(plain(Model.nonEmptyGroups(groups).map((g) => g.key)), ["reviewRequested", "allAssigned"])
  })

  it("flattens rows in render order", () => {
    assert.deepEqual(plain(Model.flatten(groups).map((p) => p.url)), ["a", "b", "c"])
  })

  it("offsets each group by the rows above it", () => {
    const visible = Model.nonEmptyGroups(groups)
    assert.equal(Model.groupOffset(visible, 0), 0)
    assert.equal(Model.groupOffset(visible, 1), 1)
    assert.equal(Model.groupOffset(visible, 9), 3)
  })
})

describe("labels", () => {
  it("formats the title line", () => {
    assert.equal(Model.titleFor(pr({ number: 12, title: "Add thing" })), "#12  Add thing")
    assert.equal(Model.titleFor(pr({ number: 12, title: undefined })), "#12  ")
    assert.equal(Model.titleFor(null), "")
  })

  it("formats the meta line", () => {
    assert.equal(Model.metaFor(pr({ repo: "o/r", author: "ann", ageInDays: 3 })), "o/r  ·  @ann  ·  3d")
    assert.equal(Model.metaFor({ ageInDays: 0, draft: true, ignored: true }), "  ·  today  ·  draft  ·  ignored")
    assert.equal(Model.metaFor(null), "")
  })

  it("formats ages", () => {
    assert.equal(Model.ageText(undefined), "today")
    assert.equal(Model.ageText(0.5), "today")
    assert.equal(Model.ageText(6), "6d")
    assert.equal(Model.ageText(14), "2w")
    assert.equal(Model.ageText(90), "3mo")
    assert.equal(Model.ageText(365), "1y")
    assert.equal(Model.ageText(548), "1.5y")
  })

  it("formats the panel header", () => {
    const ok = { ok: true, login: "me" }
    assert.equal(Model.heroMeta(ok, 0, 0, true), "Loading…")
    assert.equal(Model.heroMeta({ ok: false }, 2, 0, false), "Not connected")
    assert.equal(Model.heroMeta(ok, 1, 0, false), "@me  ·  1 open pull request")
    assert.equal(Model.heroMeta({ ok: true, login: "" }, 3, 0, true), "3 open pull requests")
    assert.equal(Model.heroMeta(ok, 3, 1, false), "@me  ·  3 open  ·  1 ignored")
  })
})

describe("pathFromUrl", () => {
  it("strips file:// and decodes", () => {
    assert.equal(Model.pathFromUrl("file:///home/me/my%20plugin/x.sh"), "/home/me/my plugin/x.sh")
  })

  it("passes plain paths through", () => {
    assert.equal(Model.pathFromUrl("/a/b.sh"), "/a/b.sh")
    assert.equal(Model.pathFromUrl(undefined), "")
  })

  it("keeps an undecodable path as is", () => {
    assert.equal(Model.pathFromUrl("file:///a/%E0%A4%A"), "/a/%E0%A4%A")
  })
})

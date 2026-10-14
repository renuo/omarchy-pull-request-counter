const { it } = require("node:test")
const assert = require("node:assert/strict")
const fs = require("node:fs")
const path = require("node:path")

// Service.qml needs the Omarchy shell to load, so this reads the source instead.
const source = fs.readFileSync(path.join(__dirname, "..", "Service.qml"), "utf8")

it("opens pull requests only through Model.pullRequestUrl", () => {
  const opened = [...source.matchAll(/Qt\.openUrlExternally\(([^)]*\)?)\)/g)].map((m) => m[1])
  assert.deepEqual(opened.sort(), ['"https://github.com/pulls"', "url"].sort())
  assert.match(source, /var url = Model\.pullRequestUrl\(pr\)/)
})

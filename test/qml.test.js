const { describe, it } = require("node:test")
const assert = require("node:assert/strict")
const fs = require("node:fs")
const path = require("node:path")

const ROOT = path.join(__dirname, "..")

// The QML needs the Omarchy shell to load, so this reads the source instead.
function textElements(source) {
  const blocks = []
  const opener = /\bText\s*\{/g
  let match
  while ((match = opener.exec(source)) !== null) {
    let depth = 0
    let end = match.index + match[0].length - 1
    do {
      if (source[end] === "{") depth += 1
      else if (source[end] === "}") depth -= 1
      end += 1
    } while (depth > 0)
    const line = source.slice(0, match.index).split("\n").length
    blocks.push({ line, body: source.slice(match.index, end) })
  }
  return blocks
}

describe("Text elements", () => {
  const files = fs.readdirSync(ROOT).filter((name) => name.endsWith(".qml"))

  it("finds the Text elements to check", () => {
    assert.ok(files.includes("Panel.qml"))
    assert.ok(textElements(fs.readFileSync(path.join(ROOT, "Panel.qml"), "utf8")).length > 0)
  })

  // A Text defaults to AutoText, which renders a pull request title such as
  // `Fix <img src="https://attacker/x.png">` as markup and fetches the image.
  for (const file of files) {
    it(`renders plain text only in ${file}`, () => {
      const source = fs.readFileSync(path.join(ROOT, file), "utf8")
      const offenders = textElements(source)
        .filter((block) => !/^\s*textFormat:\s*Text\.PlainText\s*$/m.test(block.body))
        .map((block) => `${file}:${block.line}`)
      assert.deepEqual(offenders, [])
    })
  }
})

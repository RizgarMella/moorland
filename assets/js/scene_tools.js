// Scene navigator helpers: list scenes and reorder whole scene blocks.
// Pure functions over the script text - unit-testable, offline-friendly.

import { parse } from "./fountain"

// [{index, line, text}] for every scene heading, in document order.
export function sceneList(text) {
  return parse(text)
    .elements.filter((el) => el.type === "scene")
    .map((el, index) => ({ index, line: el.line, text: el.text }))
}

// The full navigator listing: scenes (numbered), # sections (with level),
// and [[note]] lines, in document order.
export function navList(text) {
  let sceneIndex = 0
  const rows = []
  for (const el of parse(text).elements) {
    if (el.type === "scene") {
      rows.push({ kind: "scene", index: sceneIndex++, line: el.line, text: el.text })
    } else if (el.type === "section") {
      rows.push({ kind: "section", level: el.level, line: el.line, text: el.text })
    } else if (el.type === "action" && /\[\[[^\]]+\]\]/.test(el.text)) {
      const note = el.text.match(/\[\[([^\]]+)\]\]/)[1].trim()
      rows.push({ kind: "note", line: el.line, text: note })
    }
  }
  return rows
}

// Moves the whole block of scene `from` (heading through the line before the
// next heading) to position `to` among the scenes. Content before the first
// scene (title page, cold-open action) stays put.
export function moveScene(text, from, to) {
  const lines = (text || "").split("\n")
  const starts = sceneList(text).map((s) => s.line)
  if (
    from === to ||
    from < 0 || from >= starts.length ||
    to < 0 || to >= starts.length
  ) {
    return text
  }

  const trimEnd = (arr) => {
    const copy = [...arr]
    while (copy.length && copy[copy.length - 1].trim() === "") copy.pop()
    return copy
  }

  const preamble = trimEnd(lines.slice(0, starts[0]))
  const blocks = starts.map((start, i) => {
    const end = i + 1 < starts.length ? starts[i + 1] : lines.length
    return trimEnd(lines.slice(start, end))
  })

  const [moved] = blocks.splice(from, 1)
  blocks.splice(to, 0, moved)

  const parts = []
  if (preamble.length) parts.push(preamble.join("\n"))
  for (const block of blocks) parts.push(block.join("\n"))
  return parts.join("\n\n") + "\n"
}

// Scene navigator helpers: list scenes and reorder whole scene blocks.
// Pure functions over the script text - unit-testable, offline-friendly.

import { parse, splitSceneNumber } from "./fountain"

// [{index, line, text, number}] for every scene heading, in document order.
// `number` is the heading's fixed #number#, or null.
export function sceneList(text) {
  return parse(text)
    .elements.filter((el) => el.type === "scene")
    .map((el, index) => ({ index, line: el.line, text: el.text, number: el.number }))
}

// The next production number after `label`: 12 -> 12A, 12A -> 12B, 12Z -> 12ZA.
function bump(label) {
  const last = label.slice(-1)
  if (/[A-Y]/i.test(last)) return label.slice(0, -1) + String.fromCharCode(last.toUpperCase().charCodeAt(0) + 1)
  return label + "A"
}

// Fixes every scene's number in the text as a Fountain #number#. The first
// time, scenes are numbered 1, 2, 3...; after that, scenes added since keep
// everyone else's number and slot in as production numbers do: a scene
// after 12 becomes 12A, one before scene 1 becomes A1.
export function lockSceneNumbers(text) {
  const lines = (text || "").split("\n")
  const scenes = sceneList(text)
  if (scenes.length === 0) return text

  const labels = scenes.map((s) => s.number)
  if (labels.every((l) => !l)) {
    scenes.forEach((_, i) => (labels[i] = String(i + 1)))
  } else {
    const used = new Set(labels.filter(Boolean).map((l) => l.toUpperCase()))
    const firstNumbered = labels.findIndex(Boolean)
    for (let i = 0; i < labels.length; i++) {
      if (labels[i]) continue
      let candidate
      if (i < firstNumbered) {
        // Before the first numbered scene: A1, B1... in front of it.
        const anchor = labels[firstNumbered]
        let prefix = "A"
        candidate = prefix + anchor
        while (used.has(candidate.toUpperCase())) {
          prefix = String.fromCharCode(prefix.charCodeAt(0) + 1)
          candidate = prefix + anchor
        }
      } else {
        candidate = bump(labels[i - 1])
        while (used.has(candidate.toUpperCase())) candidate = bump(candidate)
      }
      labels[i] = candidate
      used.add(candidate.toUpperCase())
    }
  }

  scenes.forEach((scene, i) => {
    if (scene.number) return
    lines[scene.line] = lines[scene.line].replace(/\s+$/, "") + ` #${labels[i]}#`
  })
  return lines.join("\n")
}

// Removes every fixed scene number, so scenes number themselves again.
export function clearSceneNumbers(text) {
  const lines = (text || "").split("\n")
  for (const scene of sceneList(text)) {
    lines[scene.line] = splitSceneNumber(lines[scene.line])[0]
  }
  return lines.join("\n")
}

// The full navigator listing: scenes (numbered), # sections (with level),
// and [[note]] lines, in document order.
export function navList(text) {
  let sceneIndex = 0
  const rows = []
  for (const el of parse(text).elements) {
    if (el.type === "scene") {
      rows.push({ kind: "scene", index: sceneIndex++, line: el.line, text: el.text, number: el.number })
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

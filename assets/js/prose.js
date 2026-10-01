// Prose documents (stories, books) are Markdown. A small, dependency-free
// renderer for the preview and print, and the navigator's chapter list.
// Every block carries data-line (its first source line) so comments, Go to,
// tags and revision marks work on prose exactly as on a screenplay.

import { escapeHtml, inline } from "./fountain"

const HEADING_RE = /^(#{1,3})\s+(.*)$/
const BREAK_RE = /^\s*(([*\-_])\s*){3,}$/

// Blanks out /* boneyard */ while keeping line numbers.
function stripBoneyard(text) {
  return text.replace(/\/\*[\s\S]*?\*\//g, (m) => m.replace(/[^\n]/g, ""))
}

// Blocks in order: {type: "heading"|"break"|"quote"|"para", level, text, line}.
export function parseProse(text) {
  const lines = stripBoneyard(text || "").split("\n")
  const blocks = []
  let para = null

  const close = () => {
    if (para) blocks.push(para)
    para = null
  }

  lines.forEach((raw, i) => {
    const line = raw.trimEnd()
    if (line.trim() === "") return close()

    const heading = line.match(HEADING_RE)
    if (heading) {
      close()
      blocks.push({ type: "heading", level: heading[1].length, text: heading[2].trim(), line: i })
      return
    }
    if (BREAK_RE.test(line)) {
      close()
      blocks.push({ type: "break", line: i })
      return
    }

    const quote = line.startsWith(">")
    const body = quote ? line.replace(/^>\s?/, "") : line.trim()
    const type = quote ? "quote" : "para"
    // Consecutive lines join into one paragraph, as in Markdown.
    if (para && para.type === type) {
      para.text += " " + body
    } else {
      close()
      para = { type, text: body, line: i }
    }
  })
  close()
  return blocks
}

export function renderProse(text) {
  const parts = []
  for (const block of parseProse(text)) {
    const ln = `data-line="${block.line}"`
    switch (block.type) {
      case "heading":
        parts.push(`<h${block.level + 1} class="pr-h${block.level}" ${ln}>${inline(block.text)}</h${block.level + 1}>`)
        break
      case "break":
        parts.push(`<div class="pr-break" ${ln} aria-label="Scene break">*&nbsp;&nbsp;*&nbsp;&nbsp;*</div>`)
        break
      case "quote":
        parts.push(`<blockquote class="pr-quote" ${ln}>${inline(block.text)}</blockquote>`)
        break
      default:
        parts.push(`<p class="pr-p" ${ln}>${inline(block.text)}</p>`)
    }
  }
  if (parts.length === 0) {
    return `<p class="pr-empty">${escapeHtml("Your story appears here as you write.")}</p>`
  }
  return parts.join("")
}

// Navigator rows: # headings as chapters, ## as scenes (and ### beneath).
export function proseNavList(text) {
  return parseProse(text)
    .filter((b) => b.type === "heading")
    .map((b) => ({ kind: "section", level: b.level, line: b.line, text: b.text }))
}

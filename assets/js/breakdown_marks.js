// Breakdown tags in the preview: wraps each tag's words in a coloured
// <mark>. A tag records the words and the source line they were on; the
// words are looked for in the preview block nearest that line, so the
// highlight follows its text while lines are added and removed above it.

const escapeRe = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")

// Words of the anchor joined by any run of whitespace, case-insensitive.
// Punctuation must match; the anchor came from the rendered preview text.
export function anchorPattern(text) {
  const words = (text || "").trim().split(/\s+/).filter(Boolean)
  if (words.length === 0) return null
  return new RegExp(words.map(escapeRe).join("\\s+"), "i")
}

// [start, end] of the anchor in a string, or null.
export function findAnchor(haystack, text) {
  const re = anchorPattern(text)
  if (!re) return null
  const m = re.exec(haystack)
  return m ? [m.index, m.index + m[0].length] : null
}

// The block (element with data-line) nearest `line` whose text holds the
// anchor, preferring the earlier block on a tie.
function nearestBlock(blocks, tag) {
  let best = null
  let bestDist = Infinity
  for (const block of blocks) {
    const dist = Math.abs(block.line - tag.line)
    if (dist < bestDist && findAnchor(block.el.textContent, tag.text)) {
      best = block
      bestDist = dist
    }
  }
  return best
}

// Wraps [start, end) of the element's text in marks, splitting across the
// text nodes it spans (emphasis and other inline markup).
function wrapRange(el, start, end, tag) {
  const walker = document.createTreeWalker(el, NodeFilter.SHOW_TEXT)
  const pieces = []
  let offset = 0
  let node
  while ((node = walker.nextNode())) {
    const len = node.nodeValue.length
    const from = Math.max(start, offset)
    const to = Math.min(end, offset + len)
    if (from < to) pieces.push({ node, from: from - offset, to: to - offset })
    offset += len
    if (offset >= end) break
  }

  for (const { node, from, to } of pieces) {
    // Never nest: text already inside a tag mark stays with that tag.
    if (node.parentElement && node.parentElement.closest("mark.bd-mark")) continue
    let target = node
    if (from > 0) target = target.splitText(from)
    if (to - from < target.nodeValue.length) target.splitText(to - from)
    const mark = document.createElement("mark")
    mark.className = `bd-mark bd-cat-${tag.category}`
    mark.title = tag.name
    target.parentNode.insertBefore(mark, target)
    mark.appendChild(target)
  }
}

// Marks every tag in the rendered preview. Safe to call after each render.
export function markTags(preview, tags) {
  if (!preview || !tags || tags.length === 0) return
  const blocks = Array.from(preview.querySelectorAll("[data-line]"))
    .filter((el) => !el.classList.contains("fp-title-page"))
    .map((el) => ({ el, line: parseInt(el.dataset.line, 10) }))

  for (const tag of tags) {
    const block = nearestBlock(blocks, tag)
    if (!block) continue
    const range = findAnchor(block.el.textContent, tag.text)
    if (range) wrapRange(block.el, range[0], range[1], tag)
  }
}

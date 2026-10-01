// Revision marks: which lines of the script have changed since a revision
// set began. A line-level Myers diff between the set's starting text and the
// text now; pure, so it runs on every keystroke in the preview.

// Scene numbers are written into headings when a script is locked; a heading
// that only gained its number is not a revision.
const SCENE_NUMBER_RE = /\s*#[A-Za-z0-9.\-]+#\s*$/
const normalize = (line) => line.replace(SCENE_NUMBER_RE, "").trimEnd()

// Beyond this many differing lines the rewrite is wholesale; marking every
// line that doesn't appear in the base is then close enough and far cheaper.
const MAX_EDIT = 400

// Indices (0-based) of lines in `text` that are new or changed relative to
// `base`. Where lines were only deleted, the next line is marked instead, so
// a cut still shows in the margin. Blank lines are never marked.
export function changedLines(base, text) {
  const fullA = (base || "").split("\n").map(normalize)
  const fullB = (text || "").split("\n").map(normalize)
  const changed = new Set()

  // Most revisions touch a few lines in the middle: diff only between the
  // common first and last lines, and shift results back by the prefix.
  let start = 0
  while (start < fullA.length && start < fullB.length && fullA[start] === fullB[start]) start++
  let endA = fullA.length
  let endB = fullB.length
  while (endA > start && endB > start && fullA[endA - 1] === fullB[endB - 1]) {
    endA--
    endB--
  }
  const a = fullA.slice(start, endA)
  const b = fullB.slice(start, endB)

  const trace = myersTrace(a, b)
  if (trace === null) {
    const seen = new Set(a)
    b.forEach((line, i) => {
      if (line.trim() !== "" && !seen.has(line)) changed.add(i + start)
    })
    return changed
  }

  // Walk back from the end along the shortest edit script.
  const cuts = []
  let x = a.length
  let y = b.length
  for (let d = trace.length - 1; d >= 0; d--) {
    const v = trace[d]
    const k = x - y
    const prevK = k === -d || (k !== d && v.get(k - 1) < v.get(k + 1)) ? k + 1 : k - 1
    const prevX = v.get(prevK)
    const prevY = prevX - prevK

    while (x > prevX && y > prevY) {
      x--
      y--
    }
    if (d > 0) {
      if (x === prevX) {
        if (b[prevY].trim() !== "") changed.add(prevY + start)
      } else if (a[prevX].trim() !== "") {
        cuts.push(y + start)
      }
    }
    x = prevX
    y = prevY
  }

  if (a.length > 0 && b.length === 0) cuts.push(start)
  for (const at of cuts) markNear(changed, fullB, at)
  return changed
}

// Marks the first non-blank line at or after `from` (or before, at the end).
function markNear(changed, lines, from) {
  for (let i = from; i < lines.length; i++) {
    if (lines[i].trim() !== "") return changed.add(i)
  }
  for (let i = Math.min(from, lines.length) - 1; i >= 0; i--) {
    if (lines[i].trim() !== "") return changed.add(i)
  }
}

// Myers' shortest edit script: the frontier (furthest x on each diagonal k)
// as it stood before each edit distance d, until the end is reached; null
// when that takes more than MAX_EDIT edits.
function myersTrace(a, b) {
  const n = a.length
  const m = b.length
  const max = Math.min(n + m, MAX_EDIT)
  const v = new Map([[1, 0]])
  const trace = []

  for (let d = 0; d <= max; d++) {
    trace.push(new Map(v))
    for (let k = -d; k <= d; k += 2) {
      let x = k === -d || (k !== d && v.get(k - 1) < v.get(k + 1)) ? v.get(k + 1) : v.get(k - 1) + 1
      let y = x - k
      while (x < n && y < m && a[x] === b[y]) {
        x++
        y++
      }
      v.set(k, x)
      if (x >= n && y >= m) return trace
    }
  }
  return null
}

// Marks rendered blocks (elements with data-line) whose line changed: a
// class for styling and the margin asterisk.
export function markRevisions(container, changed) {
  if (!container || !changed || changed.size === 0) return
  for (const block of container.querySelectorAll("[data-line]")) {
    if (block.classList.contains("fp-title-page")) continue
    if (changed.has(parseInt(block.dataset.line, 10))) block.classList.add("fp-revised")
  }
}

// Heads every page that holds a revised line with the set's label, as
// revised pages are headed in production ("BLUE REV. 12/10/26"). Pages are
// the stretches between the preview's page edges; the first page, having no
// edge above it, gets its label as the container's first child.
export function labelRevisedPages(container, label) {
  if (!container || !label) return
  let edge = null
  let revised = false
  const mark = () => {
    if (!revised) return
    const tag = document.createElement("span")
    tag.className = "fp-rev-label"
    tag.textContent = label
    if (edge) {
      edge.prepend(tag)
    } else {
      const top = document.createElement("div")
      top.className = "fp-rev-top"
      top.appendChild(tag)
      container.prepend(top)
    }
  }
  for (const child of [...container.children]) {
    if (child.classList.contains("fp-page-edge")) {
      mark()
      edge = child
      revised = false
    } else if (child.classList.contains("fp-revised")) {
      revised = true
    }
  }
  mark()
}

// Where each line of `base` is in `text` now: a Map of old line -> new line,
// for lines that survived unchanged. Used to keep locked pages where they
// were. Past the edit limit, lines that are unique in both texts stand in.
export function mapLines(base, text) {
  const fullA = (base || "").split("\n").map(normalize)
  const fullB = (text || "").split("\n").map(normalize)
  const map = new Map()

  let start = 0
  while (start < fullA.length && start < fullB.length && fullA[start] === fullB[start]) {
    map.set(start, start)
    start++
  }
  let endA = fullA.length
  let endB = fullB.length
  while (endA > start && endB > start && fullA[endA - 1] === fullB[endB - 1]) {
    endA--
    endB--
    map.set(endA, endB)
  }
  const a = fullA.slice(start, endA)
  const b = fullB.slice(start, endB)

  const trace = myersTrace(a, b)
  if (trace === null) {
    const count = (lines) => lines.reduce((m, l) => m.set(l, (m.get(l) || 0) + 1), new Map())
    const ca = count(a)
    const cb = count(b)
    const where = new Map(b.map((l, i) => [l, i]))
    a.forEach((l, i) => {
      if (l.trim() !== "" && ca.get(l) === 1 && cb.get(l) === 1) map.set(i + start, where.get(l) + start)
    })
    return map
  }

  let x = a.length
  let y = b.length
  for (let d = trace.length - 1; d >= 0; d--) {
    const v = trace[d]
    const k = x - y
    const prevK = k === -d || (k !== d && v.get(k - 1) < v.get(k + 1)) ? k + 1 : k - 1
    const prevX = v.get(prevK)
    const prevY = prevX - prevK
    while (x > prevX && y > prevY) {
      x--
      y--
      map.set(x + start, y + start)
    }
    x = prevX
    y = prevY
  }
  return map
}

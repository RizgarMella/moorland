// A small Fountain (fountain.io) parser and HTML renderer.
// Runs entirely client-side so the preview keeps working offline.
// Every rendered block carries data-line (its source line index) so the UI can
// anchor comments to preview selections and offer inline "script helper" chips.

const SCENE_RE = /^(INT|EXT|EST|INT\.\/EXT|INT\/EXT|I\/E)[.\s]/i
const TRANSITION_RE = /^[A-Z0-9 .']+TO:$/
const TIME_SUFFIXES = [
  "DAY", "NIGHT", "MORNING", "EVENING", "AFTERNOON", "DUSK", "DAWN",
  "CONTINUOUS", "LATER", "MOMENTS LATER", "SAME", "SUNSET", "SUNRISE",
]

function escapeHtml(text) {
  return text
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
}

// *italic*, **bold**, ***bold italic***, _underline_, [[note]]
function inline(text) {
  let out = escapeHtml(text)
  out = out.replace(/\[\[([^\]]+)\]\]/g, '<span class="fnote">$1</span>')
  out = out.replace(/\*\*\*([^*]+)\*\*\*/g, "<strong><em>$1</em></strong>")
  out = out.replace(/\*\*([^*]+)\*\*/g, "<strong>$1</strong>")
  out = out.replace(/\*([^*\n]+)\*/g, "<em>$1</em>")
  out = out.replace(/_([^_\n]+)_/g, "<u>$1</u>")
  return out
}

function isBlank(line) {
  return line === undefined || line.trim() === ""
}

function isSceneHeading(line) {
  const t = line.trim()
  return SCENE_RE.test(t) || (t.startsWith(".") && !t.startsWith(".."))
}

function isTransition(line) {
  const t = line.trim()
  if (t.startsWith(">") && !t.endsWith("<")) return true
  return TRANSITION_RE.test(t) && t === t.toUpperCase()
}

function isCharacterCue(line, prevBlank, nextLine) {
  const t = line.trim()
  if (t.startsWith("@")) return prevBlank && !isBlank(nextLine)
  if (!prevBlank || isBlank(nextLine)) return false
  if (t.length === 0 || t.length > 60) return false
  // Strip a trailing (extension) like (V.O.) / (CONT'D)
  const base = t.replace(/\s*\([^)]*\)\s*$/, "")
  if (base.length === 0) return false
  if (!/[A-Z]/.test(base)) return false
  if (base !== base.toUpperCase()) return false
  if (isSceneHeading(t) || isTransition(t)) return false
  return /^[A-Z0-9 .'\-#]+$/.test(base)
}

function cueName(line) {
  return line.trim().replace(/^@/, "").replace(/\s*\([^)]*\)\s*$/, "").trim()
}

// Strips a Fountain title page from the top; returns [titlePairs, consumedLineCount]
function splitTitlePage(lines) {
  if (lines.length === 0 || !/^[A-Za-z ]+:\s*/.test(lines[0])) return [[], 0]
  const pairs = []
  let i = 0
  let current = null
  while (i < lines.length && !isBlank(lines[i])) {
    const m = lines[i].match(/^([A-Za-z ]+):\s*(.*)$/)
    if (m) {
      current = { key: m[1].trim(), values: m[2] ? [m[2].trim()] : [] }
      pairs.push(current)
    } else if (current && /^\s+/.test(lines[i])) {
      current.values.push(lines[i].trim())
    } else {
      return [[], 0] // not a title page after all
    }
    i++
  }
  return [pairs, i]
}

// Blanks out /* boneyard */ while preserving line numbering.
function stripBoneyard(text) {
  return text.replace(/\/\*[\s\S]*?\*\//g, (m) => m.replace(/[^\n]/g, ""))
}

// Parses the script into a flat list of typed elements, each with its source line.
export function parse(text) {
  const lines = stripBoneyard(text || "").split("\n")
  const [titlePage, offset] = splitTitlePage(lines)
  const elements = []
  let i = offset
  let inDialogue = false

  while (i < lines.length) {
    const line = lines[i]
    const t = line.trim()
    const prevBlank = i === offset || isBlank(lines[i - 1])

    if (isBlank(line)) {
      inDialogue = false
      i++
      continue
    }

    if (t === "===") {
      elements.push({ type: "page-break", line: i })
      inDialogue = false
    } else if (t.startsWith("#")) {
      const level = Math.min((t.match(/^#+/) || ["#"])[0].length, 3)
      elements.push({ type: "section", level, text: t.replace(/^#+\s*/, ""), line: i })
      inDialogue = false
    } else if (t.startsWith("=")) {
      elements.push({ type: "synopsis", text: t.replace(/^=\s*/, ""), line: i })
      inDialogue = false
    } else if (t.startsWith(">") && t.endsWith("<")) {
      elements.push({ type: "centered", text: t.slice(1, -1).trim(), line: i })
      inDialogue = false
    } else if (isSceneHeading(line) && prevBlank) {
      const heading = t.startsWith(".") ? t.slice(1) : t
      elements.push({ type: "scene", text: heading.toUpperCase(), line: i })
      inDialogue = false
    } else if (isTransition(line) && prevBlank) {
      elements.push({
        type: "transition",
        text: t.startsWith(">") ? t.slice(1).trim() : t,
        line: i,
      })
      inDialogue = false
    } else if (isCharacterCue(line, prevBlank, lines[i + 1])) {
      elements.push({
        type: "character",
        text: t.startsWith("@") ? t.slice(1) : t,
        name: cueName(line),
        line: i,
      })
      inDialogue = true
    } else if (inDialogue && t.startsWith("(") && t.endsWith(")")) {
      elements.push({ type: "parenthetical", text: t, line: i })
    } else if (inDialogue) {
      const lyric = t.startsWith("~")
      elements.push({
        type: lyric ? "lyric" : "dialogue",
        text: lyric ? t.slice(1).trim() : t,
        line: i,
      })
    } else {
      elements.push({ type: "action", text: t.startsWith("!") ? t.slice(1) : line, line: i })
    }
    i++
  }

  return { titlePage, elements }
}

function levenshtein(a, b) {
  if (Math.abs(a.length - b.length) > 2) return 99
  const dp = Array.from({ length: a.length + 1 }, (_, i) => [i])
  for (let j = 1; j <= b.length; j++) dp[0][j] = j
  for (let i = 1; i <= a.length; i++) {
    for (let j = 1; j <= b.length; j++) {
      dp[i][j] = Math.min(
        dp[i - 1][j] + 1,
        dp[i][j - 1] + 1,
        dp[i - 1][j - 1] + (a[i - 1] === b[j - 1] ? 0 : 1)
      )
    }
  }
  return dp[a.length][b.length]
}

// For a cue used once, a frequent near-identical name is probably what was meant.
function typoSuggestions(elements) {
  const counts = new Map()
  for (const el of elements) {
    if (el.type === "character") counts.set(el.name, (counts.get(el.name) || 0) + 1)
  }
  const frequent = [...counts.entries()].filter(([, c]) => c >= 2).map(([n]) => n)
  const suggestions = new Map()
  for (const [name, count] of counts) {
    if (count > 1 || name.length < 4) continue
    for (const candidate of frequent) {
      if (candidate !== name && levenshtein(name, candidate) <= 2) {
        suggestions.set(name, candidate)
        break
      }
    }
  }
  return suggestions
}

// opts.helpers enables the inline chips (time-of-day picker, typo fix) that
// edit the source; only turn it on for users who can edit.
// opts.paginate (default true) draws on-screen page boundaries; pass false for
// print, where the browser paginates for real.
export function renderHtml(text, opts = {}) {
  const helpers = !!opts.helpers
  const paginate = opts.paginate !== false
  const { titlePage, elements } = parse(text)
  const typos = helpers ? typoSuggestions(elements) : new Map()
  const parts = []

  if (titlePage.length > 0) {
    // Industry-standard layout: title/credit/author centered in the upper
    // middle, contact bottom-left, draft date and copyright bottom-right.
    const get = (key) => titlePage.find((p) => p.key.toLowerCase() === key)
    const val = (p) => (p ? p.values.join("\n").trim() : "")
    const ml = (v) => v.split("\n").map(inline).join("<br/>")
    const title = val(get("title"))
    const credit = val(get("credit"))
    const author = val(get("author")) || val(get("authors"))
    const source = val(get("source"))
    const contact = val(get("contact"))
    const notes = val(get("notes"))
    const draftDate = val(get("draft date")) || val(get("date")) || val(get("revision"))
    const copyright = val(get("copyright"))

    parts.push('<div class="fp-title-page" data-line="0">')
    parts.push('<div class="fp-tp-center">')
    if (title) parts.push(`<div class="fp-title">${inline(title)}</div>`)
    if (author && credit) parts.push(`<div class="fp-credit">${inline(credit)}</div>`)
    if (author) parts.push(`<div class="fp-author">${inline(author)}</div>`)
    if (source) parts.push(`<div class="fp-source">${inline(source)}</div>`)
    parts.push("</div>")
    parts.push('<div class="fp-tp-bottom">')
    parts.push('<div class="fp-tp-left">')
    if (contact) parts.push(`<div>${ml(contact)}</div>`)
    if (notes) parts.push(`<div>${ml(notes)}</div>`)
    parts.push("</div>")
    parts.push('<div class="fp-tp-right">')
    if (draftDate) parts.push(`<div>${ml(draftDate)}</div>`)
    if (copyright) parts.push(`<div>${ml(copyright)}</div>`)
    parts.push("</div>")
    if (helpers) {
      parts.push('<button class="fp-edit-title" title="Edit the title page">edit title page</button>')
    }
    parts.push("</div></div>")
  } else if (helpers && (text || "").trim() !== "") {
    parts.push(
      '<div class="fp-helper-row"><button class="fp-add-title" title="Insert a standard title page (title, credit, author, draft date, contact)">+ title page</button></div>'
    )
  }

  // Standard screenplay pagination: ~55 content lines per page, page numbers
  // top-right starting with page 2. Estimates wrapped lines per element type.
  const LINES_PER_PAGE = 55
  const rows = (t, width) => Math.max(1, Math.ceil((t || "").length / width))
  const costOf = (el) => {
    switch (el.type) {
      case "scene": return rows(el.text, 60) + 2
      case "action": return rows(el.text, 60) + 1
      case "character": return 2
      case "parenthetical": return rows(el.text, 25)
      case "dialogue":
      case "lyric": return rows(el.text, 35)
      case "transition": return 2
      case "centered": return 2
      case "section": return 2
      case "synopsis": return 1
      default: return 0
    }
  }

  let sceneNumber = 0
  let pageNo = 1
  let used = 0
  for (const el of elements) {
    const ln = `data-line="${el.line}"`

    if (el.type === "page-break") {
      pageNo++
      used = 0
      parts.push(
        paginate
          ? `<div class="fp-page-edge" ${ln}><span>${pageNo}.</span></div>`
          : `<div class="fp-forced-break" ${ln}></div>`
      )
      continue
    }

    if (paginate) {
      const cost = costOf(el)
      // Never leave a scene heading or character cue orphaned at a page bottom.
      const orphanRisk =
        (el.type === "scene" || el.type === "character") && used + cost + 2 > LINES_PER_PAGE
      if (used + cost > LINES_PER_PAGE || orphanRisk) {
        pageNo++
        used = 0
        parts.push(`<div class="fp-page-edge"><span>${pageNo}.</span></div>`)
      }
      used += cost
    }

    switch (el.type) {
      case "scene": {
        sceneNumber++
        const hasTime = /\s-\s/.test(el.text)
        const chip =
          helpers && !hasTime
            ? ` <button class="fp-time-picker" data-line="${el.line}" title="Add a time of day">time&nbsp;&#9662;</button>`
            : ""
        parts.push(
          `<div class="fp-scene" ${ln}><span class="fp-scene-no">${sceneNumber}</span>${inline(el.text)}${chip}</div>`
        )
        break
      }
      case "action":
        parts.push(`<div class="fp-action" ${ln}>${inline(el.text)}</div>`)
        break
      case "character": {
        const suggestion = typos.get(el.name)
        const chip = suggestion
          ? ` <button class="fp-typo-chip" data-line="${el.line}" data-from="${escapeHtml(el.name)}" data-to="${escapeHtml(suggestion)}" title="Only used once - did you mean ${escapeHtml(suggestion)}?">&rarr; ${escapeHtml(suggestion)}?</button>`
          : ""
        parts.push(`<div class="fp-character" ${ln}>${inline(el.text)}${chip}</div>`)
        break
      }
      case "parenthetical":
        parts.push(`<div class="fp-paren" ${ln}>${inline(el.text)}</div>`)
        break
      case "dialogue":
        parts.push(`<div class="fp-dialogue" ${ln}>${inline(el.text)}</div>`)
        break
      case "lyric":
        parts.push(`<div class="fp-dialogue fp-lyric" ${ln}>${inline(el.text)}</div>`)
        break
      case "transition":
        parts.push(`<div class="fp-transition" ${ln}>${inline(el.text)}</div>`)
        break
      case "centered":
        parts.push(`<div class="fp-centered" ${ln}>${inline(el.text)}</div>`)
        break
      case "section":
        parts.push(`<div class="fp-section fp-section-${el.level}" ${ln}>${inline(el.text)}</div>`)
        break
      case "synopsis":
        parts.push(`<div class="fp-synopsis" ${ln}>${inline(el.text)}</div>`)
        break
    }
  }

  if (parts.length === 0) {
    return '<div class="fp-empty">The formatted preview appears here as you write.</div>'
  }
  return parts.join("")
}

// ---- Autocomplete data harvesting ------------------------------------------

// Character names used in the script (cues), without (extensions), by frequency.
export function harvestCharacters(text) {
  const counts = new Map()
  for (const el of parse(text).elements) {
    if (el.type === "character" && el.name) {
      counts.set(el.name, (counts.get(el.name) || 0) + 1)
    }
  }
  return [...counts.entries()].sort((a, b) => b[1] - a[1]).map(([name]) => name)
}

// Locations used in scene headings ("INT. COFFEE SHOP - DAY" -> "COFFEE SHOP"), by frequency.
export function harvestLocations(text) {
  const counts = new Map()
  for (const el of parse(text).elements) {
    if (el.type !== "scene") continue
    let rest = el.text.replace(SCENE_RE, "").trim()
    rest = rest.split(/\s+-\s+|\s+--\s+/)[0].trim().toUpperCase()
    if (rest) counts.set(rest, (counts.get(rest) || 0) + 1)
  }
  return [...counts.entries()].sort((a, b) => b[1] - a[1]).map(([loc]) => loc)
}

export const SCENE_PREFIXES = ["INT.", "EXT.", "INT./EXT.", "EST."]
export const TIMES = TIME_SUFFIXES
export const EXTENSIONS = ["(V.O.)", "(O.S.)", "(CONT'D)", "(O.C.)"]

// A readable Markdown rendering of the screenplay (for export).
export function toMarkdown(text) {
  const { titlePage, elements } = parse(text)
  const out = []

  if (titlePage.length > 0) {
    const get = (key) => titlePage.find((p) => p.key.toLowerCase() === key)
    const val = (p) => (p ? p.values.join(" ").trim() : "")
    const title = val(get("title"))
    const credit = val(get("credit"))
    const author = val(get("author")) || val(get("authors"))
    if (title) out.push(`# ${title}`, "")
    if (credit || author) out.push([credit, author].filter(Boolean).join(" "), "")
    out.push("---", "")
  }

  for (const el of elements) {
    switch (el.type) {
      case "section":
        out.push(`${"#".repeat(Math.min(el.level, 2))} ${el.text}`, "")
        break
      case "synopsis":
        out.push(`> ${el.text}`, "")
        break
      case "scene":
        out.push(`### ${el.text}`, "")
        break
      case "action":
      case "centered":
        out.push(el.text, "")
        break
      case "character":
        out.push(`**${el.text}**`)
        break
      case "parenthetical":
        out.push(`_${el.text}_`)
        break
      case "dialogue":
      case "lyric":
        out.push(el.text, "")
        break
      case "transition":
        out.push(`*${el.text}*`, "")
        break
      case "page-break":
        out.push("---", "")
        break
    }
  }

  return out.join("\n").replace(/\n{3,}/g, "\n\n").trim() + "\n"
}

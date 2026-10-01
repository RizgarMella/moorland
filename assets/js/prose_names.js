// Name autocomplete for prose. A screenplay announces its characters in
// cues; a story buries them mid-sentence among words that are capitalised
// only because they start a sentence ("The", "She", "When"). So a word
// counts as a name when it is capitalised somewhere other than the start of
// a sentence and never written in lower case: "Marchbanks" qualifies, "When"
// (sometimes "when") does not. Pure functions, unit-tested.

const TITLES = ["Mr", "Mrs", "Ms", "Mx", "Dr", "Prof", "St", "Sr", "Jr", "Capt", "Sgt", "Lt", "Col", "Rev"]
const TITLE_RE = new RegExp(`^(${TITLES.join("|")})\\.?$`)
// Capitalised for grammar's sake, never names.
const NEVER = new Set(["I", "I'm", "I'll", "I'd", "I've", "OK", "Ok", "TV"])

const WORD_RE = /[\p{L}][\p{L}'’\-]*/gu
const UPPER_RE = /^\p{Lu}/u
// Characters a sentence can open with before its first word.
const OPENERS = new Set(['"', "“", "'", "‘", "(", "[", "—", "–", "-", "*", "_", ">"])
const ENDERS = new Set([".", "!", "?", "…", ":"])

function stripBoneyard(text) {
  return text.replace(/\/\*[\s\S]*?\*\//g, (m) => m.replace(/[^\n]/g, ""))
}

// "Anna's" counts as "Anna".
function bare(word) {
  return word.replace(/['’]s$/u, "").replace(/['’\-]+$/u, "")
}

// Does the word starting at `index` in `line` open a sentence?
function sentenceInitial(line, index, prevWord) {
  if (prevWord && TITLE_RE.test(prevWord)) return false
  let i = index - 1
  while (i >= 0 && (line[i] === " " || line[i] === "\t" || OPENERS.has(line[i]))) i--
  return i < 0 || ENDERS.has(line[i])
}

// Every word occurrence: {word, initial, line, start}. Headings are skipped;
// "Chapter One" is not a cast list.
function occurrences(text) {
  const out = []
  stripBoneyard(text || "")
    .split("\n")
    .forEach((line, lineNo) => {
      if (/^\s*#/.test(line)) return
      let prev = null
      let prevEnd = -1
      for (const m of line.matchAll(WORD_RE)) {
        const word = bare(m[0])
        if (word === "") continue
        const adjacent = prev !== null && /^\.?\s$/.test(line.slice(prevEnd, m.index))
        out.push({
          word,
          initial: sentenceInitial(line, m.index, adjacent ? prev : null),
          line: lineNo,
          start: m.index,
          adjacentToPrev: adjacent,
        })
        prev = word
        prevEnd = m.index + m[0].length
      }
    })
  return out
}

// Names used in the text, most used first: [{name, count}]. Single names,
// plus runs of names (and a title with a name) seen together at least twice,
// such as "Anna Grey" or "Dr. Okafor". `skip` leaves out one occurrence (the
// word being typed, which would otherwise suggest itself).
export function harvestNames(text, skip = null) {
  const occ = occurrences(text).filter(
    (o) => !(skip && o.line === skip.line && o.start === skip.start)
  )

  const lower = new Set()
  const mid = new Map()
  const total = new Map()
  for (const o of occ) {
    if (!UPPER_RE.test(o.word)) {
      lower.add(o.word.toLowerCase())
      continue
    }
    total.set(o.word, (total.get(o.word) || 0) + 1)
    if (!o.initial) mid.set(o.word, (mid.get(o.word) || 0) + 1)
  }

  const isName = (w) =>
    mid.has(w) &&
    !lower.has(w.toLowerCase()) &&
    !NEVER.has(w) &&
    !TITLE_RE.test(w) &&
    w.length >= 2 &&
    w !== w.toUpperCase()

  const names = new Map()
  for (const w of total.keys()) if (isName(w)) names.set(w, total.get(w))

  // Runs on one line: a title or name, then names straight after it
  // ("Anna Grey", "Dr. Okafor"). Kept when seen together at least twice.
  const runs = new Map()
  let run = []
  const flush = () => {
    if (run.length >= 2) {
      const phrase = run.map((o) => (TITLE_RE.test(o.word) ? `${o.word}.` : o.word)).join(" ")
      runs.set(phrase, (runs.get(phrase) || 0) + 1)
    }
    run = []
  }
  for (const o of occ) {
    if (run.length > 0 && o.adjacentToPrev && isName(o.word)) {
      run.push(o)
    } else {
      flush()
      if (isName(o.word) || TITLE_RE.test(o.word)) run = [o]
    }
  }
  flush()
  for (const [phrase, count] of runs) if (count >= 2) names.set(phrase, count)

  return [...names.entries()]
    .map(([name, count]) => ({ name, count }))
    .sort((a, b) => b.count - a.count || a.name.localeCompare(b.name))
}

// What to offer for the text just before the cursor: {items, fragment} or
// null. Tries the last three, two, then one words, so "Anna G" can complete
// to "Anna Grey" and "Dr. Ok" to "Dr. Okafor". Needs two letters of a
// capitalised word; never offers what is already typed.
export function suggestNames(names, before, limit = 6) {
  const tail = before.match(/((?:\p{L}[\p{L}'’\-]*\.?\s){0,2}\p{Lu}[\p{L}'’\-]*)$/u)
  if (!tail) return null
  const words = tail[1].split(/\s/)
  if (words[words.length - 1].length < 2) {
    // One letter of the last word: only worth it when continuing a full name.
    if (words.length < 2) return null
  }

  for (let k = words.length; k >= 1; k--) {
    const fragment = words.slice(words.length - k).join(" ")
    if (!UPPER_RE.test(fragment)) continue
    if (k === 1 && fragment.length < 2) continue
    const items = names
      .map((n) => n.name)
      .filter((name) => name.startsWith(fragment) && name !== fragment)
      .slice(0, limit)
    if (items.length > 0) return { items, fragment }
  }
  return null
}

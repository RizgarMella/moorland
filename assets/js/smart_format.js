// Stream-of-consciousness formatter: turns loosely typed lines into proper
// Fountain when the writer presses Enter. Handles both styles:
//
//   Run-on:      "int coffee shop daisy Hey guys!"      (one line)
//   Line-by-line: "Int Coffee shop" / "daisy" / "Hey guys!"
//
// Pure functions, no DOM - unit-testable and fully offline.

const TIME_PHRASES = [
  "MOMENTS LATER",
  "SAME TIME",
  "DAY", "NIGHT", "MORNING", "EVENING", "AFTERNOON", "DUSK", "DAWN",
  "CONTINUOUS", "LATER", "SAME", "SUNSET", "SUNRISE",
].map((p) => p.split(" "))

const SCENE_PREFIX_RE = /^(int\.?\/ext\.?|int\/ext|i\/e|int|ext|est)\.?(?=\s|$)/i
const TRANSITION_RE = /to:$/i
const TITLE_KEY_RE =
  /^(title|credit|author|authors|source|contact|notes|copyright|draft date|date|revision):/i

// Words that frequently start action sentences - never treat them as names.
const ACTION_STARTERS = new Set([
  "the", "a", "an", "he", "she", "they", "it", "we", "i", "you",
  "his", "her", "their", "its", "and", "but", "then", "as", "at",
  "in", "on", "of", "with", "from", "to", "there", "this", "that",
])

function normalizePrefix(raw) {
  const up = raw.toUpperCase().replace(/\./g, "")
  if (up === "I/E") return "I/E"
  if (up === "INT/EXT") return "INT./EXT."
  if (up === "INT") return "INT."
  if (up === "EXT") return "EXT."
  if (up === "EST") return "EST."
  return raw.toUpperCase()
}

function bare(word) {
  return word.replace(/[^A-Za-z0-9'\-]/g, "").toUpperCase()
}

// Matches a time phrase at tokens[i]; returns its token length or 0.
function timeMatchAt(tokens, i) {
  for (const phrase of TIME_PHRASES) {
    if (i + phrase.length > tokens.length) continue
    let ok = true
    for (let j = 0; j < phrase.length; j++) {
      if (bare(tokens[i + j]) !== phrase[j]) { ok = false; break }
    }
    if (ok) return phrase.length
  }
  return 0
}

// Matches a known character (multi-word, longest first) at tokens[i]; returns
// {length, name} or null. `known` is a list of UPPERCASE names.
function knownMatchAt(tokens, i, known) {
  let best = null
  for (const name of known) {
    const words = name.split(/\s+/)
    if (i + words.length > tokens.length) continue
    let ok = true
    for (let j = 0; j < words.length; j++) {
      if (bare(tokens[i + j]) !== words[j]) { ok = false; break }
    }
    if (ok && (!best || words.length > best.words)) best = { length: words.length, name, words: words.length }
  }
  return best
}

// "daisy:" style explicit cue marker. Returns index of the colon token or -1.
function colonIndex(tokens, from, maxIndex) {
  for (let i = from; i < Math.min(tokens.length, maxIndex + 1); i++) {
    if (/^[A-Za-z][A-Za-z'\-]*:$/.test(tokens[i])) return i
  }
  return -1
}

// Interprets everything after a scene prefix. Returns array of output lines.
function parseSceneRest(rest, known) {
  const tokens = rest.split(/\s+/).filter((t) => t !== "" && !/^-+$/.test(t))
  if (tokens.length === 0) return null

  let timeIdx = -1
  let timeLen = 0
  for (let i = 1; i < tokens.length; i++) {
    const len = timeMatchAt(tokens, i)
    if (len > 0) { timeIdx = i; timeLen = len; break }
  }

  let charIdx = -1
  let charLen = 0
  let charName = null

  for (let i = 1; i < tokens.length; i++) {
    const m = knownMatchAt(tokens, i, known)
    if (m) { charIdx = i; charLen = m.length; charName = m.name; break }
  }

  if (charIdx === -1) {
    const ci = colonIndex(tokens, 1, tokens.length - 1)
    if (ci !== -1) { charIdx = ci; charLen = 1; charName = bare(tokens[ci]) }
  }

  // Time word acts as a separator: whatever follows it is a character + dialogue.
  if (charIdx === -1 && timeIdx !== -1 && timeIdx + timeLen < tokens.length) {
    charIdx = timeIdx + timeLen
    charLen = 1
    charName = bare(tokens[charIdx])
  }

  // Last resort: a lowercase non-action word right before a Capitalized word
  // usually marks where the speaker's name ends and dialogue begins.
  if (charIdx === -1 && timeIdx === -1) {
    for (let i = tokens.length - 2; i >= 1; i--) {
      const w = tokens[i]
      if (
        /^[a-z][a-z'\-]+$/.test(w) &&
        !ACTION_STARTERS.has(w.toLowerCase()) &&
        /^[A-Z]/.test(tokens[i + 1])
      ) {
        charIdx = i
        charLen = 1
        charName = bare(w)
        break
      }
    }
  }

  const locEnd = charIdx !== -1 && (timeIdx === -1 || charIdx <= timeIdx) ? charIdx
    : timeIdx !== -1 ? timeIdx
    : tokens.length
  if (locEnd === 0) return null

  const location = tokens.slice(0, locEnd).map(bare).join(" ")
  let heading = location
  if (timeIdx !== -1 && (charIdx === -1 || timeIdx < charIdx)) {
    heading += " - " + tokens.slice(timeIdx, timeIdx + timeLen).map(bare).join(" ")
  }

  const out = { heading, character: null, dialogue: null }
  if (charIdx !== -1) {
    out.character = charName
    const after = tokens.slice(charIdx + charLen).join(" ")
    out.dialogue = after || null
  }
  return out
}

// Splits dialogue text so stage directions live on their own parenthetical
// lines: "(whispering) hey (beat) sit down" -> ["(whispering)", "hey", "(beat)", "sit down"]
function splitDialogueLines(text) {
  const out = []
  for (const part of (text || "").trim().split(/\s*(\([^)]{1,40}\))\s*/)) {
    const p = part.trim()
    if (p !== "") out.push(p)
  }
  return out.length > 0 ? out : [text.trim()]
}

// True when lines[idx] sits inside a dialogue block (an unbroken run of lines
// headed by an ALL-CAPS character cue).
function inDialogueBlock(lines, idx) {
  let i = idx - 1
  while (i >= 0 && lines[i].trim() !== "") i--
  const top = lines[i + 1]
  if (top === undefined || i + 1 >= idx + 1) return false
  const t = top.trim().replace(/\s*\([^)]*\)\s*$/, "")
  return (
    t !== "" &&
    t === t.toUpperCase() &&
    /^[A-Z0-9 .'\-@]+$/.test(t) &&
    t.split(/\s+/).length <= 3 &&
    !SCENE_PREFIX_RE.test(t) &&
    !TRANSITION_RE.test(t)
  )
}

// A short line that reads like a character name about to speak.
function nameLike(line, known) {
  const t = line.trim()
  if (t === "") return false
  if (SCENE_PREFIX_RE.test(t) || TRANSITION_RE.test(t) || TITLE_KEY_RE.test(t)) return false
  const noExt = t.replace(/\s*\([^)]*\)\s*$/, "").replace(/:$/, "")
  if (known.includes(noExt.toUpperCase())) return true
  const words = noExt.split(/\s+/)
  if (words.length > 2) return false
  if (/[.!?,]$/.test(noExt)) return false
  if (ACTION_STARTERS.has(words[0].toLowerCase())) return false
  return words.every((w) => /^[A-Za-z][A-Za-z'\-]*$/.test(w))
}

/**
 * Called when Enter is pressed at the end of lines[idx].
 * Returns null (nothing to do) or {start, lines} where `lines` replaces
 * the document lines from `start` through `idx` (inclusive).
 */
export function smartFormatOnEnter(lines, idx, known) {
  known = known || []
  const cur = lines[idx]
  if (cur === undefined) return null
  const t = cur.trim()
  if (t === "") return null

  // Never touch title-page lines ("Title: ...") or their indented values.
  if (TITLE_KEY_RE.test(t)) return null

  const prev = idx > 0 ? lines[idx - 1] : undefined
  const prevBlank = prev === undefined || prev.trim() === ""

  const finish = (start, outLines) => {
    // Insert a separating blank line if the block directly follows text.
    const before = start > 0 ? lines[start - 1] : undefined
    if (before !== undefined && before.trim() !== "") outLines = ["", ...outLines]
    const original = lines.slice(start, idx + 1)
    if (
      original.length === outLines.length &&
      original.every((l, i) => l === outLines[i])
    ) {
      return null
    }
    return { start, lines: outLines }
  }

  // Transitions: "cut to:" -> "CUT TO:"
  if (TRANSITION_RE.test(t) && t.split(/\s+/).length <= 4 && !SCENE_PREFIX_RE.test(t)) {
    return finish(idx, [t.toUpperCase()])
  }

  // Scene heading lines, possibly run-on with speaker and dialogue.
  const prefixMatch = SCENE_PREFIX_RE.exec(t)
  if (prefixMatch) {
    const prefix = normalizePrefix(prefixMatch[0])
    const rest = t.slice(prefixMatch[0].length).trim()
    if (rest === "") return finish(idx, [prefix + " "])
    const parsed = parseSceneRest(rest, known)
    if (!parsed) return null
    const out = [`${prefix} ${parsed.heading}`]
    if (parsed.character) {
      out.push("", parsed.character)
      if (parsed.dialogue) out.push(...splitDialogueLines(parsed.dialogue))
    }
    return finish(idx, out)
  }

  // Explicit cue marker on a plain line: "daisy: Hey guys!" or "aunt may: Hi."
  const tokens = t.split(/\s+/)
  const ci = colonIndex(tokens, 0, 2)
  if (ci !== -1 && (ci < tokens.length - 1 || tokens.length <= 3)) {
    const name = tokens.slice(0, ci + 1).map(bare).join(" ")
    if (name !== "" && !ACTION_STARTERS.has(tokens[0].toLowerCase().replace(":", ""))) {
      const dialogue = tokens.slice(ci + 1).join(" ")
      const out = dialogue ? [name, ...splitDialogueLines(dialogue)] : [name]
      return finish(idx, out)
    }
  }

  // Line-by-line style: the previous line was a name, this line is its dialogue.
  // Indented lines are title-page continuations, never dialogue.
  if (!prevBlank && !/^\s/.test(cur) && nameLike(prev, known)) {
    const cue = prev.trim().replace(/:$/, "").toUpperCase()
    return finish(idx - 1, [cue, ...splitDialogueLines(cur)])
  }

  // Inside a dialogue block, keep dialogue and stage direction apart:
  if (!prevBlank && inDialogueBlock(lines, idx)) {
    // Inline directions split onto their own parenthetical lines.
    const split = splitDialogueLines(cur)
    if (split.length > 1) return finish(idx, split)
    // An action sentence ("He slams the door.") ends the block - give it air.
    const words = t.split(/\s+/)
    if (
      words.length >= 4 &&
      /[.]$/.test(t) &&
      /^(He|She|They|It|We|The)$/.test(words[0]) &&
      /^[a-z]/.test(words[1] || "")
    ) {
      return { start: idx, lines: ["", cur] }
    }
  }

  // A bare known character name typed in lowercase becomes a cue.
  if (known.includes(t.replace(/\s*\([^)]*\)\s*$/, "").toUpperCase()) && t !== t.toUpperCase()) {
    return finish(idx, [t.toUpperCase()])
  }

  return null
}

/**
 * Retro-formats a whole document by replaying the on-Enter formatter over
 * every line. Newly discovered character names feed later lines, so
 * "daisy / Hey guys!" early in the doc still helps "daisy" later on.
 */
export function tidyDocument(text, known) {
  const src = (text || "").split("\n")
  const chars = [...(known || [])]
  let out = []

  for (const line of src) {
    out.push(line)
    const res = smartFormatOnEnter(out, out.length - 1, chars)
    if (res) {
      out = out.slice(0, res.start).concat(res.lines)
      // A cue line is any short ALL-CAPS line the formatter just produced.
      for (const l of res.lines) {
        const t = l.trim().replace(/\s*\([^)]*\)\s*$/, "")
        if (
          t !== "" &&
          t === t.toUpperCase() &&
          /^[A-Z][A-Z0-9 .'\-]*$/.test(t) &&
          t.split(/\s+/).length <= 3 &&
          !SCENE_PREFIX_RE.test(t) &&
          !TRANSITION_RE.test(t) &&
          !chars.includes(t)
        ) {
          chars.push(t)
        }
      }
    }
  }

  return out.join("\n")
}

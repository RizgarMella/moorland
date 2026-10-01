// Two-column audio/visual scripts, as lessons and explainers are written:
// what is seen on the left, what is heard on the right, row by row. The
// text is ordinary Fountain: action lines are the VIDEO column, cued
// dialogue the AUDIO column, # sections the lesson's parts. A row is a run
// of visuals with the narration that follows it; the next visual after
// some narration starts a new row. Pure, so it renders and prints alike.

import { parse, inline, escapeHtml } from "./fountain"

// Rows in order: {kind: "part", text, line} or {kind: "row", video, audio, line}
// where video is [{text, line}] and audio is [{speaker, text, paren, line}].
export function avRows(text) {
  const { elements } = parse(text)
  const rows = []
  let row = null
  let speaker = null

  const close = () => {
    if (row) rows.push(row)
    row = null
  }
  const open = (line) => {
    if (!row) row = { kind: "row", video: [], audio: [], line }
  }

  for (const el of elements) {
    switch (el.type) {
      case "section":
        close()
        rows.push({ kind: "part", text: el.text, line: el.line })
        break
      case "scene":
      case "action":
      case "centered":
      case "transition":
        if (row && row.audio.length > 0) close()
        open(el.line)
        row.video.push({ text: el.text, line: el.line })
        break
      case "character":
        speaker = el.name
        open(el.line)
        break
      case "parenthetical":
        open(el.line)
        row.audio.push({ speaker, text: el.text, paren: true, line: el.line })
        break
      case "dialogue":
      case "lyric":
        open(el.line)
        row.audio.push({ speaker, text: el.text, paren: false, line: el.line })
        break
      default:
        break
    }
  }
  close()
  return rows
}

// Objectives from the title page ("Objectives:" with one per line).
export function objectives(text) {
  const entry = parse(text).titlePage.find((p) => p.key.toLowerCase() === "objectives")
  return entry ? entry.values.map((v) => v.replace(/^[-*•]\s*/, "")).filter(Boolean) : []
}

export function renderAV(text) {
  const { titlePage } = parse(text)
  const title = (titlePage.find((p) => p.key.toLowerCase() === "title") || { values: [] }).values.join(" ")
  const goals = objectives(text)
  const parts = []

  if (title || goals.length > 0) {
    parts.push('<div class="av-head" data-line="0">')
    if (title) parts.push(`<div class="av-title">${inline(title)}</div>`)
    if (goals.length > 0) {
      parts.push('<div class="av-objectives"><div class="av-label">Objectives</div><ol>')
      for (const goal of goals) parts.push(`<li>${inline(goal)}</li>`)
      parts.push("</ol></div>")
    }
    parts.push("</div>")
  }

  const rows = avRows(text)
  if (rows.length === 0) {
    parts.push('<div class="fp-empty">Write what we see as action lines and what we hear under a cue such as NARRATOR.</div>')
    return parts.join("")
  }

  parts.push('<div class="av-grid"><div class="av-colhead">Video</div><div class="av-colhead">Audio</div>')
  for (const row of rows) {
    if (row.kind === "part") {
      parts.push(`<div class="av-part" data-line="${row.line}">${inline(row.text)}</div>`)
      continue
    }
    const video = row.video
      .map((v) => `<div class="av-video" data-line="${v.line}">${inline(v.text)}</div>`)
      .join("")
    let last = null
    const audio = row.audio
      .map((a) => {
        const who = a.speaker && a.speaker !== last ? `<span class="av-speaker">${escapeHtml(a.speaker)}</span>` : ""
        last = a.speaker
        return `<div class="${a.paren ? "av-paren" : "av-audio"}" data-line="${a.line}">${who}${inline(a.text)}</div>`
      })
      .join("")
    parts.push(`<div class="av-cell av-left">${video}</div><div class="av-cell">${audio}</div>`)
  }
  parts.push("</div>")
  return parts.join("")
}

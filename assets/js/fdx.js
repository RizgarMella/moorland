// Final Draft (.fdx) interchange: export via pure string building (testable),
// import via DOMParser (browser only).

import { parse } from "./fountain"

// Fountain emphasis markers don't survive into FDX text runs.
function stripMarkup(text) {
  return text
    .replace(/\*\*\*([^*]+)\*\*\*/g, "$1")
    .replace(/\*\*([^*]+)\*\*/g, "$1")
    .replace(/\*([^*\n]+)\*/g, "$1")
    .replace(/_([^_\n]+)_/g, "$1")
    .replace(/\[\[[^\]]*\]\]/g, "")
    .trim()
}

function esc(text) {
  return text
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
}

const TYPE_MAP = {
  scene: "Scene Heading",
  action: "Action",
  character: "Character",
  parenthetical: "Parenthetical",
  dialogue: "Dialogue",
  lyric: "Dialogue",
  transition: "Transition",
  centered: "Action",
  section: null,
  synopsis: null,
  "page-break": null,
}

export function fountainToFdx(text) {
  const { titlePage, elements } = parse(text)

  const paras = []
  for (const el of elements) {
    const type = TYPE_MAP[el.type]
    if (!type) continue
    const body = stripMarkup(el.text || "")
    if (body === "") continue
    paras.push(`    <Paragraph Type="${type}"><Text>${esc(body)}</Text></Paragraph>`)
  }

  let titleXml = ""
  if (titlePage.length > 0) {
    const get = (key) => titlePage.find((p) => p.key.toLowerCase() === key)
    const rows = []
    const push = (value) => {
      if (value) {
        rows.push(
          `      <Paragraph Type="Centered"><Text>${esc(stripMarkup(value))}</Text></Paragraph>`
        )
      }
    }
    push(get("title")?.values.join(" "))
    push(get("credit")?.values.join(" "))
    push((get("author") || get("authors"))?.values.join(" "))
    if (rows.length > 0) {
      titleXml = `\n  <TitlePage>\n    <Content>\n${rows.join("\n")}\n    </Content>\n  </TitlePage>`
    }
  }

  return (
    `<?xml version="1.0" encoding="UTF-8" standalone="no"?>\n` +
    `<FinalDraft DocumentType="Script" Template="No" Version="5">\n` +
    `  <Content>\n${paras.join("\n")}\n  </Content>${titleXml}\n` +
    `</FinalDraft>\n`
  )
}

const FOUNTAIN_SCENE_RE = /^(INT|EXT|EST|INT\.\/EXT|INT\/EXT|I\/E)[.\s]/i

// Returns Fountain text, or null when the XML is not a usable FDX document.
export function fdxToFountain(xml) {
  const doc = new DOMParser().parseFromString(xml, "text/xml")
  if (doc.querySelector("parsererror")) return null
  const root = doc.documentElement
  if (!root || root.nodeName !== "FinalDraft") return null
  const content = [...root.children].find((c) => c.nodeName === "Content")
  if (!content) return null

  const out = []
  for (const p of content.children) {
    if (p.nodeName !== "Paragraph") continue
    const type = p.getAttribute("Type") || "Action"
    const text = [...p.querySelectorAll("Text")]
      .map((n) => n.textContent)
      .join("")
      .replace(/\s+/g, " ")
      .trim()
    if (text === "") continue

    switch (type) {
      case "Scene Heading": {
        const heading = text.toUpperCase()
        // Force non-standard headings (e.g. "FLASHBACK") with Fountain's "." marker.
        out.push("", FOUNTAIN_SCENE_RE.test(heading) ? heading : `.${heading}`)
        break
      }
      case "Character":
        out.push("", text.toUpperCase())
        break
      case "Parenthetical":
        out.push(text.startsWith("(") ? text : `(${text})`)
        break
      case "Dialogue":
        out.push(text)
        break
      case "Transition":
        out.push("", /TO:$/i.test(text) ? text.toUpperCase() : `> ${text}`)
        break
      default:
        out.push("", text)
    }
  }

  const result = out.join("\n").replace(/^\n+/, "")
  return result === "" ? null : result + "\n"
}

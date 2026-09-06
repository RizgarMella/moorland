import {
  renderHtml,
  parse,
  toMarkdown,
  harvestCharacters,
  harvestLocations,
  SCENE_PREFIXES,
  TIMES,
  EXTENSIONS,
} from "./fountain"
import { smartFormatOnEnter, tidyDocument } from "./smart_format"
import { sceneList, navList, moveScene } from "./scene_tools"
import { fountainToFdx } from "./fdx"
import { applyUI, autoHideHeader, typewriterOn } from "./ui_prefs"

const AUTOSAVE_MS = 1200
const SCENE_START_RE = /^(INT\.\/EXT\.|INT\/EXT|INT\.?|EXT\.?|EST\.?|I\/E)\s+/i
const TITLE_KEYS = [
  "Title:", "Credit:", "Author:", "Source:", "Draft date:",
  "Contact:", "Copyright:", "Notes:",
]
const TIME_CHOICES = ["DAY", "NIGHT", "MORNING", "EVENING", "DUSK", "DAWN", "CONTINUOUS", "LATER"]

// Buffers edits to localStorage so a lost connection never loses work.
function storageKey(scriptId) {
  return `moorland:script:${scriptId}`
}

function readLocal(scriptId) {
  try {
    const raw = localStorage.getItem(storageKey(scriptId))
    return raw ? JSON.parse(raw) : null
  } catch {
    return null
  }
}

function writeLocal(scriptId, content, baseVersion) {
  try {
    localStorage.setItem(
      storageKey(scriptId),
      JSON.stringify({ content, at: Date.now() / 1000, baseVersion })
    )
  } catch {
    // Storage full or blocked - the server copy still saves when online.
  }
}

function clearLocal(scriptId) {
  try {
    localStorage.removeItem(storageKey(scriptId))
  } catch {}
}

export const ScreenplayEditor = {
  mounted() {
    this.scriptId = this.el.dataset.scriptId
    this.canEdit = this.el.dataset.canEdit === "true"
    this.canComment = this.el.dataset.canComment === "true"
    this.textarea = this.el.querySelector("#screenplay-input")
    this.preview = document.getElementById("screenplay-preview")
    this.previewWrap = this.el.querySelector("#preview-wrap")
    this.bubble = this.el.querySelector("#comment-bubble")
    this.helperMenu = this.el.querySelector("#helper-menu")
    this.menu = this.el.querySelector("#autocomplete-menu")
    this.status = document.getElementById("save-status")
    this.saveTimer = null
    this.dirty = false
    this.offline = false
    this.suggestions = []
    this.selectedIndex = 0
    this.pendingSelection = null

    // The content_version our edits are built on - the merge base for saves.
    this.baseVersion = parseInt(this.el.dataset.contentVersion || "0", 10)
    this.lastSent = null

    // If the connection died mid-edit last time, the freshest copy may be
    // local. Its stored baseVersion lets the server merge it correctly even
    // if others kept writing while we were gone.
    const local = readLocal(this.scriptId)
    const serverAt = parseInt(this.el.dataset.updatedAt || "0", 10)
    if (this.canEdit && local && local.at > serverAt && local.content !== this.textarea.value) {
      this.textarea.value = local.content
      if (typeof local.baseVersion === "number") this.baseVersion = local.baseVersion
      this.markDirty()
    }

    applyUI()
    this.renderPreview()
    this.refreshVocab()

    this.textarea.addEventListener("input", () => {
      autoHideHeader()
      this.renderPreview()
      this.updateAutocomplete()
      this.syncPreview()
      this.renderSceneNav()
      this.typewriterCenter()
      if (this.canEdit) this.markDirty()
    })

    this.textarea.addEventListener("keydown", (e) => this.onKeydown(e))
    this.textarea.addEventListener("click", () => {
      this.hideMenu()
      this.pushCursorLine()
    })
    this.textarea.addEventListener("keyup", (e) => {
      if (["ArrowUp", "ArrowDown", "ArrowLeft", "ArrowRight", "Home", "End"].includes(e.key)) {
        this.pushCursorLine()
      }
    })
    this.textarea.addEventListener("blur", () => setTimeout(() => this.hideMenu(), 150))

    if (this.previewWrap) {
      this.previewWrap.addEventListener("mouseup", () => this.onPreviewSelect())
      this.previewWrap.addEventListener("click", (e) => this.onPreviewClick(e))
      this.previewWrap.addEventListener("scroll", () => {
        this.hideBubble()
        this.hideHelperMenu()
      })
    }
    this.tidyButton = this.el.querySelector("#tidy-button")
    if (this.tidyButton) {
      this.tidyButton.addEventListener("click", () => this.tidy())
    }
    this.sceneNav = this.el.querySelector("#scene-nav")
    this.renderSceneNav()

    // Ctrl+P / the browser's own print always gets the formatted script.
    this.onBeforePrint = () => this.fillPrintRoot()
    window.addEventListener("beforeprint", this.onBeforePrint)
    if (this.bubble) {
      this.bubble.querySelector("[data-comment]")?.addEventListener("mousedown", (e) => {
        e.preventDefault()
        this.commentOnSelection()
      })
      this.bubble.querySelector("[data-goto]")?.addEventListener("mousedown", (e) => {
        e.preventDefault()
        const selection = this.pendingSelection
        this.hideBubble()
        window.getSelection()?.removeAllRanges()
        if (selection) this.jumpToPosition(selection.line, selection.text, 0)
      })
    }

    // Double-clicking text in the preview puts the cursor on that exact word
    // in the editor (expanding the editor pane first if it's collapsed).
    if (this.previewWrap) {
      this.previewWrap.addEventListener("dblclick", (e) => {
        const block = e.target.closest && e.target.closest("[data-line]")
        if (!block) return
        const line = parseInt(block.dataset.line, 10)

        // The browser selects the double-clicked word; work out which
        // occurrence of it inside the block was hit, so repeated words land
        // on the right one.
        const sel = window.getSelection()
        let word = ""
        let occurrence = 0
        if (sel && !sel.isCollapsed && sel.rangeCount > 0) {
          word = sel.toString().trim()
          const range = sel.getRangeAt(0)
          const before = document.createRange()
          before.selectNodeContents(block)
          try {
            before.setEnd(range.startContainer, range.startOffset)
            const preceding = before.toString().toLowerCase()
            const needle = word.toLowerCase()
            let idx = needle === "" ? -1 : preceding.indexOf(needle)
            while (idx !== -1) {
              occurrence++
              idx = preceding.indexOf(needle, idx + 1)
            }
          } catch {
            occurrence = 0
          }
        }

        this.hideBubble()
        window.getSelection()?.removeAllRanges()
        this.jumpToPosition(line, word, occurrence)
      })
    }

    // When a collapsed pane comes back, center it on the cursor.
    this.onLayoutChanged = () => {
      this.syncPreview()
      this.markActiveScene()
    }
    window.addEventListener("moorland:layout-changed", this.onLayoutChanged)

    // Ctrl/Cmd+S saves immediately instead of the browser dialog.
    this.onGlobalKey = (e) => {
      if ((e.ctrlKey || e.metaKey) && e.key === "s") {
        e.preventDefault()
        this.flushSave()
      }
    }
    window.addEventListener("keydown", this.onGlobalKey)

    this.handleEvent("remote_content", ({ content, version }) =>
      this.applyRemote(content, version)
    )
    this.handleEvent("save_ack", ({ version, content }) => {
      const stillTyping = this.textarea.value !== this.lastSent
      if (!stillTyping) {
        // Clean ack, or our save was merged with someone else's edits: the
        // server text is now the authority.
        this.baseVersion = version
        if (content !== undefined && content !== this.textarea.value) {
          this.applyServerText(content)
        }
        this.dirty = false
        clearLocal(this.scriptId)
        this.setStatus("saved")
      } else if (content === undefined) {
        // We typed on while the save was in flight but nothing was merged:
        // our text extends what the server now holds.
        this.baseVersion = version
        this.flushSoon()
      } else {
        // Merged on the server while we kept typing: keep our old base so the
        // next save re-merges against the true ancestor, and save promptly.
        this.flushSoon()
      }
      this.refreshVocab()
    })
    this.handleEvent("save_error", () => this.setStatus("saving"))
    this.handleEvent("jump_to_line", ({ line }) => this.jumpToLine(line))
    this.handleEvent("scene_nav", ({ open }) => {
      if (this.sceneNav) {
        this.sceneNav.hidden = !open
        if (open) this.renderSceneNav()
      }
    })
    this.handleEvent("export", ({ format, watermark }) => this.doExport(format, watermark))
    this.handleEvent("set_title_page", ({ block }) => this.setTitlePage(block))

    // Bin & Shelf: cut the selection out of the script, or drop text back in.
    this.handleEvent("cut_selection", () => {
      const start = this.textarea.selectionStart
      const end = this.textarea.selectionEnd
      if (start === end) return
      const body = this.textarea.value.slice(start, end)
      this.replaceRange(start, end, "")
      this.pushEvent("bin_add", { body })
    })

    this.handleEvent("insert_at_cursor", ({ text }) => {
      const pos = this.textarea.selectionStart
      const value = this.textarea.value
      const before = value.slice(0, pos)
      const prefix = before === "" || before.endsWith("\n") ? "" : "\n"
      const suffix = value.slice(pos).startsWith("\n") || pos === value.length ? "\n" : "\n"
      this.replaceRange(pos, pos, prefix + text.trim() + suffix)
    })

    this.setStatus("saved")
  },

  destroyed() {
    window.removeEventListener("keydown", this.onGlobalKey)
    window.removeEventListener("beforeprint", this.onBeforePrint)
    window.removeEventListener("moorland:layout-changed", this.onLayoutChanged)
    if (this.saveTimer) clearTimeout(this.saveTimer)
  },

  // ---- export / print -------------------------------------------------------

  fillPrintRoot(watermark) {
    // A sides export already filled the root; don't clobber it mid-print.
    if (this.customPrint) {
      this.customPrint = false
      return
    }
    const root = document.getElementById("print-root")
    if (!root) return
    if (watermark !== undefined) root.dataset.watermark = watermark || ""
    const mark = root.dataset.watermark || ""
    root.innerHTML =
      (mark ? `<div class="print-watermark">${mark.replace(/[<>&"]/g, "")}</div>` : "") +
      renderHtml(this.textarea.value, { helpers: false, paginate: false })
  },

  doExport(format, watermark) {
    const title = (this.el.dataset.title || "script").replace(/[\\/:*?"<>|]/g, "_")
    if (format === "pdf") {
      this.fillPrintRoot(watermark || "")
      window.print()
    } else if (format === "fountain") {
      this.download(`${title}.fountain`, this.textarea.value, "text/plain")
    } else if (format === "fdx") {
      this.download(`${title}.fdx`, fountainToFdx(this.textarea.value), "text/xml")
    } else if (format === "markdown") {
      this.download(`${title}.md`, toMarkdown(this.textarea.value), "text/markdown")
    } else if (format === "html") {
      this.download(`${title}.html`, this.buildHtmlExport(title), "text/html")
    } else if (format === "sides") {
      this.exportSides()
    }
  },

  // Script sides: a printable PDF of just the chosen scenes.
  exportSides() {
    const scenes = sceneList(this.textarea.value)
    if (scenes.length === 0) return
    const listing = scenes.map((s) => `${s.index + 1}. ${s.text}`).join("\n")
    const answer = window.prompt(
      `Which scenes? e.g. 1-3,5\n\n${listing.slice(0, 900)}`,
      `1-${scenes.length}`
    )
    if (!answer) return

    const wanted = new Set()
    for (const part of answer.split(",")) {
      const m = part.trim().match(/^(\d+)(?:\s*-\s*(\d+))?$/)
      if (!m) continue
      const from = parseInt(m[1], 10)
      const to = m[2] ? parseInt(m[2], 10) : from
      for (let i = from; i <= to; i++) wanted.add(i - 1)
    }
    if (wanted.size === 0) return

    const lines = this.textarea.value.split("\n")
    const blocks = scenes
      .filter((s) => wanted.has(s.index))
      .map((s, _i) => {
        const next = scenes.find((n) => n.index === s.index + 1)
        const end = next ? next.line : lines.length
        return lines.slice(s.line, end).join("\n").trimEnd()
      })

    const root = document.getElementById("print-root")
    if (!root) return
    root.dataset.watermark = ""
    root.innerHTML = renderHtml(blocks.join("\n\n"), { helpers: false, paginate: false })
    this.customPrint = true
    window.print()
    // Next ordinary print refills from the full script via beforeprint.
  },

  buildHtmlExport(title) {
    const body = renderHtml(this.textarea.value, { helpers: false, paginate: false })
    const style = `
      body { background:#fbfaf8; margin:0 }
      .screenplay { font-family:"Courier Prime","Courier New",Courier,monospace;
        font-size:14px; line-height:1.5; color:#262624; max-width:62ch;
        margin:0 auto; padding:3rem 2rem 6rem }
      .fp-title-page { display:flex; flex-direction:column; min-height:90vh;
        margin-bottom:4rem; border-bottom:1px dashed #d6d3cb; padding-bottom:1.5rem }
      .fp-tp-center { text-align:center; margin-top:22vh }
      .fp-title { font-weight:700; text-transform:uppercase;
        text-decoration:underline; margin-bottom:2rem }
      .fp-credit { margin-bottom:1rem } .fp-author { margin-bottom:1.5rem }
      .fp-source, .fp-tp-bottom { font-size:12px; color:#55534d }
      .fp-tp-bottom { margin-top:auto; display:flex;
        justify-content:space-between; align-items:flex-end; gap:2rem }
      .fp-tp-right { text-align:right }
      .fp-scene { font-weight:700; text-transform:uppercase; margin:1.75rem 0 .75rem; position:relative }
      .fp-scene-no { position:absolute; left:-3ch; color:#b6b3ac; font-weight:400 }
      .fp-action { margin:.75rem 0; white-space:pre-wrap }
      .fp-character { margin:1rem 0 0 22ch; text-transform:uppercase }
      .fp-paren { margin-left:16ch; max-width:25ch }
      .fp-dialogue { margin-left:10ch; max-width:35ch }
      .fp-lyric { font-style:italic }
      .fp-transition { text-align:right; text-transform:uppercase; margin:1rem 0 }
      .fp-centered { text-align:center; margin:1rem 0 }
      .fp-section { color:#8a877f; font-weight:700; margin:2rem 0 .5rem;
        font-family:ui-sans-serif,system-ui,sans-serif }
      .fp-synopsis { color:#8a877f; font-style:italic; margin:.5rem 0 }
      .fnote { background:#fdf3c9; border-radius:3px; padding:0 3px }
      .fp-forced-break { border-top:1px dashed #d6d3cb; margin:2.5rem 0 }
    `
    return (
      `<!doctype html>\n<html><head><meta charset="utf-8">` +
      `<title>${title.replace(/[<>&]/g, "")}</title>` +
      `<style>${style}</style></head>` +
      `<body><div class="screenplay">${body}</div></body></html>\n`
    )
  },

  download(filename, content, mime) {
    const blob = new Blob([content], { type: `${mime};charset=utf-8` })
    const url = URL.createObjectURL(blob)
    const a = document.createElement("a")
    a.href = url
    a.download = filename
    document.body.appendChild(a)
    a.click()
    a.remove()
    setTimeout(() => URL.revokeObjectURL(url), 5000)
  },

  // ---- scene navigator ------------------------------------------------------

  renderSceneNav() {
    if (!this.sceneNav || this.sceneNav.hidden) return
    const rows = navList(this.textarea.value)
    this.sceneNav.innerHTML = ""

    if (rows.length === 0) {
      const empty = document.createElement("div")
      empty.className = "scene-nav-empty"
      empty.textContent = "Scenes, sections and notes appear here as you write."
      this.sceneNav.appendChild(empty)
      return
    }

    rows.forEach((row) => {
      const item = document.createElement("div")
      item.dataset.line = row.line

      if (row.kind === "section") {
        item.className = `scene-nav-section scene-nav-section-${row.level}`
        item.textContent = row.text
        item.addEventListener("click", () => this.jumpToLine(row.line))
        this.sceneNav.appendChild(item)
        return
      }

      if (row.kind === "note") {
        item.className = "scene-nav-note"
        item.innerHTML = `<span class="scene-nav-no">✎</span><span class="scene-nav-text"></span>`
        item.querySelector(".scene-nav-text").textContent = row.text
        item.addEventListener("click", () => this.jumpToLine(row.line))
        this.sceneNav.appendChild(item)
        return
      }

      item.className = "scene-nav-item"
      item.draggable = this.canEdit
      item.dataset.index = row.index
      item.innerHTML =
        `<span class="scene-nav-no">${row.index + 1}</span>` +
        `<span class="scene-nav-text"></span>`
      item.querySelector(".scene-nav-text").textContent = row.text
      item.addEventListener("click", () => this.jumpToLine(row.line))

      if (this.canEdit) {
        item.addEventListener("dragstart", (e) => {
          e.dataTransfer.effectAllowed = "move"
          this.dragIndex = row.index
        })
        item.addEventListener("dragover", (e) => {
          e.preventDefault()
          item.classList.add("drag-over")
        })
        item.addEventListener("dragleave", () => item.classList.remove("drag-over"))
        item.addEventListener("drop", (e) => {
          e.preventDefault()
          item.classList.remove("drag-over")
          if (this.dragIndex === undefined || this.dragIndex === row.index) return
          const next = moveScene(this.textarea.value, this.dragIndex, row.index)
          this.dragIndex = undefined
          if (next !== this.textarea.value) {
            this.replaceRange(0, this.textarea.value.length, next)
          }
        })
      }

      this.sceneNav.appendChild(item)
    })
    this.markActiveScene()
  },

  markActiveScene() {
    if (!this.sceneNav || this.sceneNav.hidden) return
    const { lineNo } = this.currentLineInfo()
    let active = null
    for (const item of this.sceneNav.querySelectorAll(".scene-nav-item")) {
      item.classList.remove("is-active")
      if (parseInt(item.dataset.line, 10) <= lineNo) active = item
    }
    if (active) active.classList.add("is-active")
  },

  disconnected() {
    this.offline = true
    this.setStatus("offline")
  },

  reconnected() {
    this.offline = false
    if (this.dirty) {
      this.flushSave()
    } else {
      this.setStatus("saved")
    }
  },

  // ---- saving --------------------------------------------------------------

  markDirty() {
    this.dirty = true
    writeLocal(this.scriptId, this.textarea.value, this.baseVersion)
    this.setStatus(this.offline ? "offline" : "saving")
    if (this.saveTimer) clearTimeout(this.saveTimer)
    this.saveTimer = setTimeout(() => this.flushSave(), AUTOSAVE_MS)
  },

  flushSave() {
    if (!this.canEdit || !this.dirty || this.offline) return
    this.lastSent = this.textarea.value
    this.pushEvent("autosave", { content: this.lastSent, base_version: this.baseVersion })
  },

  flushSoon() {
    if (this.saveTimer) clearTimeout(this.saveTimer)
    this.saveTimer = setTimeout(() => this.flushSave(), 150)
  },

  applyRemote(content, version) {
    if (this.dirty) {
      // We have unsaved local edits built on an older base. Don't clobber the
      // textarea - save promptly instead, and the server will merge both
      // sides. Our baseVersion intentionally stays at our true ancestor.
      this.flushSoon()
      return
    }
    if (typeof version === "number") this.baseVersion = version
    if (this.textarea.value === content) return
    this.applyServerText(content)
    clearLocal(this.scriptId)
    this.setStatus("saved")
  },

  // Replaces the buffer with server-authoritative text, keeping the caret near
  // its old spot and all the derived UI in sync.
  applyServerText(content) {
    const hadFocus = document.activeElement === this.textarea
    const start = this.textarea.selectionStart
    this.textarea.value = content
    if (hadFocus) {
      const pos = Math.min(start, content.length)
      this.textarea.setSelectionRange(pos, pos)
    }
    this.renderPreview()
    this.refreshVocab()
    this.renderSceneNav()
  },

  setStatus(state) {
    if (!this.status) return
    const text = this.status.dataset[`${state}Text`] || ""
    this.status.textContent = text
    this.status.classList.toggle("text-warning", state === "offline")
  },

  // ---- preview -------------------------------------------------------------

  renderPreview() {
    if (this.preview) {
      this.preview.innerHTML = renderHtml(this.textarea.value, { helpers: this.canEdit })
    }
  },

  refreshVocab() {
    this.characters = harvestCharacters(this.textarea.value)
    this.locations = harvestLocations(this.textarea.value)
  },

  // ---- editing helpers (undo-friendly range replacement) --------------------

  replaceRange(start, end, text) {
    const ta = this.textarea
    ta.focus()
    ta.setSelectionRange(start, end)
    let ok = false
    try {
      ok = document.execCommand("insertText", false, text)
    } catch {
      ok = false
    }
    if (!ok) {
      ta.setRangeText(text, start, end, "end")
      ta.dispatchEvent(new Event("input", { bubbles: true }))
    }
  },

  lineStartOffset(lines, lineNo) {
    let offset = 0
    for (let i = 0; i < lineNo; i++) offset += lines[i].length + 1
    return offset
  },

  // ---- stream-of-consciousness smart formatting -----------------------------

  // Retro-formats the whole document (loose headings, cues, dialogue).
  tidy() {
    if (!this.canEdit) return
    const before = this.textarea.value
    const after = tidyDocument(before, this.characters)
    if (after === before) return
    this.replaceRange(0, before.length, after)
    this.textarea.setSelectionRange(after.length, after.length)
    this.refreshVocab()
  },

  trySmartExpand() {
    if (!this.canEdit) return false
    const ta = this.textarea
    const pos = ta.selectionStart
    if (ta.selectionEnd !== pos) return false
    const value = ta.value
    const nl = value.indexOf("\n", pos)
    const lineEndPos = nl === -1 ? value.length : nl
    if (value.slice(pos, lineEndPos).trim() !== "") return false // only when finishing the line
    const lineNo = value.slice(0, pos).split("\n").length - 1
    const lines = value.split("\n")
    const result = smartFormatOnEnter(lines, lineNo, this.characters)
    if (!result) return false
    const startPos = this.lineStartOffset(lines, result.start)
    this.replaceRange(startPos, lineEndPos, result.lines.join("\n") + "\n")
    this.refreshVocab()
    return true
  },

  // ---- preview selection -> anchored comment --------------------------------

  onPreviewSelect() {
    if (!this.canComment || !this.bubble) return
    setTimeout(() => {
      const sel = window.getSelection()
      if (!sel || sel.isCollapsed || sel.rangeCount === 0) return this.hideBubble()
      const range = sel.getRangeAt(0)
      if (!this.preview.contains(range.commonAncestorContainer)) return this.hideBubble()
      const startNode =
        range.startContainer.nodeType === 1
          ? range.startContainer
          : range.startContainer.parentElement
      const block = startNode && startNode.closest("[data-line]")
      if (!block) return this.hideBubble()
      const text = sel.toString().trim().replace(/\s+/g, " ").slice(0, 120)
      if (!text) return this.hideBubble()

      this.pendingSelection = { line: parseInt(block.dataset.line, 10), text }
      const rect = range.getBoundingClientRect()
      const wrap = this.previewWrap.getBoundingClientRect()
      this.bubble.style.top = `${rect.bottom - wrap.top + this.previewWrap.scrollTop + 6}px`
      this.bubble.style.left = `${Math.max(
        8,
        Math.min(
          rect.left - wrap.left + this.previewWrap.scrollLeft,
          this.previewWrap.clientWidth - 140
        )
      )}px`
      this.bubble.hidden = false
    }, 0)
  },

  hideBubble() {
    if (this.bubble) this.bubble.hidden = true
    this.pendingSelection = null
  },

  commentOnSelection() {
    if (this.pendingSelection) {
      this.pushEvent("comment_on_selection", this.pendingSelection)
      window.getSelection()?.removeAllRanges()
    }
    this.hideBubble()
  },

  // ---- inline helper chips in the preview -----------------------------------

  onPreviewClick(e) {
    const timeChip = e.target.closest(".fp-time-picker")
    if (timeChip) {
      e.preventDefault()
      const line = parseInt(timeChip.dataset.line, 10)
      this.showHelperMenu(timeChip, TIME_CHOICES, (choice) => this.appendTime(line, choice))
      return
    }
    const typoChip = e.target.closest(".fp-typo-chip")
    if (typoChip) {
      e.preventDefault()
      this.fixTypo(parseInt(typoChip.dataset.line, 10), typoChip.dataset.from, typoChip.dataset.to)
      return
    }
    const titleChip = e.target.closest(".fp-add-title") || e.target.closest(".fp-edit-title")
    if (titleChip) {
      e.preventDefault()
      this.openTitleForm()
      return
    }
    this.hideHelperMenu()
  },

  // Collects current title-page values and asks the server for the form.
  openTitleForm() {
    const pairs = parse(this.textarea.value).titlePage
    const get = (key) => {
      const pair = pairs.find((p) => p.key.toLowerCase() === key)
      return pair ? pair.values.join("\n") : ""
    }
    this.pushEvent("open_title_form", {
      title: get("title") || this.el.dataset.title || "",
      credit: get("credit") || "Written by",
      author: get("author") || get("authors"),
      source: get("source"),
      draft_date: get("draft date") || get("date"),
      contact: get("contact") || this.el.dataset.userEmail || "",
      copyright: get("copyright"),
    })
  },

  // Replaces (or inserts) the title-page block at the top of the document.
  setTitlePage(block) {
    const lines = this.textarea.value.split("\n")
    let end = 0
    if (lines.length > 0 && /^[A-Za-z ]+:/.test(lines[0])) {
      while (
        end < lines.length &&
        lines[end].trim() !== "" &&
        (/^[A-Za-z ]+:/.test(lines[end]) || /^\s+\S/.test(lines[end]))
      ) {
        end++
      }
      // Swallow the blank separator too; the new block brings its own.
      if (end < lines.length && lines[end].trim() === "") end++
    }
    const endOffset = this.lineStartOffset(lines, end)
    this.replaceRange(0, endOffset, block)
    this.textarea.setSelectionRange(0, 0)
    this.refreshVocab()
  },

  showHelperMenu(anchorEl, options, onPick) {
    if (!this.helperMenu) return
    this.helperMenu.innerHTML = ""
    for (const opt of options) {
      const item = document.createElement("div")
      item.className = "autocomplete-item"
      item.textContent = opt
      item.addEventListener("mousedown", (ev) => {
        ev.preventDefault()
        this.hideHelperMenu()
        onPick(opt)
      })
      this.helperMenu.appendChild(item)
    }
    const rect = anchorEl.getBoundingClientRect()
    const wrap = this.previewWrap.getBoundingClientRect()
    this.helperMenu.style.top = `${rect.bottom - wrap.top + this.previewWrap.scrollTop + 4}px`
    this.helperMenu.style.left = `${Math.max(
      8,
      Math.min(rect.left - wrap.left + this.previewWrap.scrollLeft, this.previewWrap.clientWidth - 180)
    )}px`
    this.helperMenu.hidden = false
  },

  hideHelperMenu() {
    if (this.helperMenu) this.helperMenu.hidden = true
  },

  appendTime(lineNo, time) {
    const lines = this.textarea.value.split("\n")
    if (lines[lineNo] === undefined) return
    const end = this.lineStartOffset(lines, lineNo) + lines[lineNo].length
    this.replaceRange(end, end, ` - ${time}`)
  },

  fixTypo(lineNo, from, to) {
    const lines = this.textarea.value.split("\n")
    if (lines[lineNo] === undefined) return
    const idx = lines[lineNo].indexOf(from)
    if (idx === -1) return
    const start = this.lineStartOffset(lines, lineNo) + idx
    this.replaceRange(start, start + from.length, to)
    this.refreshVocab()
  },

  // ---- cursor / comment anchoring -------------------------------------------

  currentLineInfo() {
    const pos = this.textarea.selectionStart
    const before = this.textarea.value.slice(0, pos)
    const lineNo = before.split("\n").length - 1
    const lineStart = before.lastIndexOf("\n") + 1
    const lineEnd = this.textarea.value.indexOf("\n", pos)
    const lineText = this.textarea.value.slice(lineStart, lineEnd === -1 ? undefined : lineEnd)
    return { lineNo, lineStart, lineText, colBefore: before.slice(lineStart) }
  },

  pushCursorLine() {
    const { lineNo, lineText } = this.currentLineInfo()
    this.pushEvent("cursor_line", { line: lineNo, text: lineText.slice(0, 120) })
    this.syncPreview()
    this.markActiveScene()
    this.typewriterCenter()
  },

  // Typewriter mode: keep the line being written vertically centered.
  typewriterCenter() {
    if (!typewriterOn()) return
    const { lineNo } = this.currentLineInfo()
    const lineHeight = parseFloat(getComputedStyle(this.textarea).lineHeight) || 24
    const target = Math.max(0, lineNo * lineHeight - this.textarea.clientHeight / 2 + lineHeight)
    if (Math.abs(this.textarea.scrollTop - target) > lineHeight / 2) {
      this.textarea.scrollTop = target
    }
  },

  // Keeps the preview centered on the block the editor cursor sits in.
  syncPreview() {
    if (!this.previewWrap || !this.preview) return
    const { lineNo } = this.currentLineInfo()
    let target = null
    for (const block of this.preview.querySelectorAll("[data-line]")) {
      if (parseInt(block.dataset.line, 10) <= lineNo) target = block
      else break
    }
    if (!target) return

    this.preview.querySelector(".fp-active")?.classList.remove("fp-active")
    target.classList.add("fp-active")

    const desired = Math.max(
      0,
      target.offsetTop - this.previewWrap.clientHeight / 2 + target.offsetHeight / 2
    )
    if (Math.abs(this.previewWrap.scrollTop - desired) > 40) {
      if (this.syncTimer) clearTimeout(this.syncTimer)
      this.syncTimer = setTimeout(
        () => this.previewWrap.scrollTo({ top: desired, behavior: "smooth" }),
        120
      )
    }
  },

  // Puts the caret at the exact spot: finds the nth occurrence of the text in
  // the source line and places the cursor there (no selection). Falls back to
  // the first word, then the line start.
  jumpToPosition(line, searchText, occurrence = 0) {
    window.moorlandUI?.showEditor?.()
    const lines = this.textarea.value.split("\n")
    const target = Math.max(0, Math.min(parseInt(line, 10) || 0, lines.length - 1))
    const lineText = lines[target] || ""
    const haystack = lineText.toLowerCase()

    const findNth = (needle, nth) => {
      if (!needle) return -1
      let idx = -1
      let from = 0
      for (let i = 0; i <= nth; i++) {
        idx = haystack.indexOf(needle, from)
        if (idx === -1) return -1
        from = idx + 1
      }
      return idx
    }

    const needle = (searchText || "").trim().toLowerCase()
    let col = findNth(needle, occurrence)
    if (col === -1 && needle.includes(" ")) col = findNth(needle.split(/\s+/)[0], 0)
    if (col === -1) col = 0

    const pos = this.lineStartOffset(lines, target) + col
    this.textarea.focus()
    this.textarea.setSelectionRange(pos, pos)
    const lineHeight = parseFloat(getComputedStyle(this.textarea).lineHeight) || 24
    this.textarea.scrollTop = Math.max(0, target * lineHeight - this.textarea.clientHeight / 2)
    this.pushCursorLine()
  },

  jumpToLine(line) {
    // Jumping into the editor brings it back if it was collapsed.
    window.moorlandUI?.showEditor?.()
    const lines = this.textarea.value.split("\n")
    const target = Math.min(parseInt(line, 10), lines.length - 1)
    const pos = this.lineStartOffset(lines, target)
    this.textarea.focus()
    this.textarea.setSelectionRange(pos, pos + (lines[target] || "").length)
    const lineHeight = parseFloat(getComputedStyle(this.textarea).lineHeight) || 24
    this.textarea.scrollTop = Math.max(0, target * lineHeight - this.textarea.clientHeight / 2)
  },

  // ---- autocomplete ---------------------------------------------------------

  onKeydown(e) {
    if (this.menu.hidden) {
      if (e.key === "Enter") {
        if (this.trySmartExpand()) {
          e.preventDefault()
          return
        }
        this.pushCursorLine()
      }
      return
    }
    switch (e.key) {
      case "ArrowDown":
        e.preventDefault()
        this.moveSelection(1)
        break
      case "ArrowUp":
        e.preventDefault()
        this.moveSelection(-1)
        break
      case "Enter":
      case "Tab":
        e.preventDefault()
        this.acceptSuggestion(this.suggestions[this.selectedIndex])
        break
      case "Escape":
        e.preventDefault()
        this.hideMenu()
        break
      default:
        break
    }
  },

  // True while the caret sits in the title-page block at the very top.
  inTitlePageRegion(lines, lineNo) {
    for (let i = 0; i < lineNo; i++) {
      const l = lines[i]
      if (l.trim() === "") return false
      if (!/^[A-Za-z ]+:/.test(l) && !/^\s+\S/.test(l)) return false
    }
    return lineNo === 0 || /^[A-Za-z ]+:/.test(lines[0])
  },

  // Decides what to suggest given the text before the caret on this line.
  computeSuggestions() {
    if (!this.canEdit) return null
    const { lineNo, colBefore } = this.currentLineInfo()
    const lines = this.textarea.value.split("\n")
    const prevBlank = lineNo === 0 || (lines[lineNo - 1] || "").trim() === ""
    const typed = colBefore

    // Title page keys at the very top of the document.
    if (/^[A-Za-z ]{1,12}$/.test(typed) && this.inTitlePageRegion(lines, lineNo)) {
      const frag = typed.toLowerCase()
      const keys = TITLE_KEYS.filter((k) => k.toLowerCase().startsWith(frag))
      if (keys.length > 0 && keys[0].toLowerCase() !== `${frag}:`) {
        return { items: keys, replaceFrom: 0, suffix: " " }
      }
    }

    // Inside a scene heading?
    const sceneMatch = typed.match(SCENE_START_RE)
    if (sceneMatch) {
      const rest = typed.slice(sceneMatch[0].length)
      const dashIdx = rest.search(/\s+-\s*/)
      if (dashIdx === -1) {
        // Typing the location.
        const frag = rest.toUpperCase()
        const pool = this.locations.filter((l) => l.startsWith(frag) && l !== frag)
        if (pool.length > 0 && frag.length >= 1) {
          return { items: pool.slice(0, 8), replaceFrom: typed.length - rest.length, suffix: " - " }
        }
      } else {
        // Typing the time of day after " - ".
        const after = rest.slice(dashIdx).replace(/^\s*-+\s*/, "")
        const frag = after.toUpperCase()
        const pool = TIMES.filter((t) => t.startsWith(frag) && t !== frag)
        if (pool.length > 0) {
          return { items: pool.slice(0, 8), replaceFrom: typed.length - after.length, suffix: "" }
        }
      }
      return null
    }

    // A fresh line after a blank: suggest characters and scene prefixes.
    if (prevBlank && typed.length >= 1 && /^[A-Za-z@]/.test(typed)) {
      const raw = typed.replace(/^@/, "")
      const frag = raw.toUpperCase()
      const chars = this.characters.filter((c) => c.startsWith(frag) && c !== frag)
      const prefixes = SCENE_PREFIXES.filter((p) => p.startsWith(frag))
      const items = [...chars.slice(0, 6), ...prefixes]
      if (items.length > 0) {
        return { items: items.slice(0, 8), replaceFrom: typed.length - raw.length, suffix: "" }
      }
    }

    // After a character cue, typing "(" suggests extensions.
    if (typed.trim().startsWith("(") === false && /\($/.test(typed)) {
      const prev = (lines[lineNo] || "").slice(0, typed.length - 1).trim()
      if (prev && prev === prev.toUpperCase()) {
        return { items: EXTENSIONS, replaceFrom: typed.length - 1, suffix: "" }
      }
    }

    return null
  },

  updateAutocomplete() {
    const result = this.computeSuggestions()
    if (!result) {
      this.hideMenu()
      return
    }
    this.suggestions = result.items
    this.replaceFrom = result.replaceFrom
    this.suffix = result.suffix
    this.selectedIndex = 0
    this.showMenu()
  },

  showMenu() {
    this.menu.innerHTML = ""
    this.suggestions.forEach((item, idx) => {
      const div = document.createElement("div")
      div.className = "autocomplete-item" + (idx === this.selectedIndex ? " is-selected" : "")
      div.textContent = item
      div.addEventListener("mousedown", (e) => {
        e.preventDefault()
        this.acceptSuggestion(item)
      })
      this.menu.appendChild(div)
    })
    const { top, left } = this.caretCoords()
    this.menu.style.top = `${top + 24}px`
    this.menu.style.left = `${left}px`
    this.menu.hidden = false
  },

  hideMenu() {
    this.menu.hidden = true
    this.suggestions = []
  },

  moveSelection(delta) {
    this.selectedIndex =
      (this.selectedIndex + delta + this.suggestions.length) % this.suggestions.length
    ;[...this.menu.children].forEach((child, idx) =>
      child.classList.toggle("is-selected", idx === this.selectedIndex)
    )
  },

  acceptSuggestion(item) {
    if (!item) return
    const { lineStart } = this.currentLineInfo()
    const replaceAt = lineStart + this.replaceFrom
    const pos = this.textarea.selectionStart
    const inserted = item + this.suffix
    this.hideMenu()
    this.replaceRange(replaceAt, pos, inserted)
  },

  // Measures the caret position with a mirror div so the menu can sit under it.
  caretCoords() {
    const ta = this.textarea
    const mirror = document.createElement("div")
    const style = getComputedStyle(ta)
    for (const prop of [
      "fontFamily", "fontSize", "fontWeight", "lineHeight", "letterSpacing",
      "paddingTop", "paddingLeft", "paddingRight", "borderLeftWidth", "borderTopWidth",
      "whiteSpace", "wordWrap", "overflowWrap", "tabSize",
    ]) {
      mirror.style[prop] = style[prop]
    }
    mirror.style.position = "absolute"
    mirror.style.visibility = "hidden"
    mirror.style.whiteSpace = "pre-wrap"
    mirror.style.width = `${ta.clientWidth}px`
    mirror.textContent = ta.value.slice(0, ta.selectionStart)
    const marker = document.createElement("span")
    marker.textContent = "​"
    mirror.appendChild(marker)
    ta.parentElement.appendChild(mirror)
    const top = marker.offsetTop - ta.scrollTop
    const left = marker.offsetLeft - ta.scrollLeft
    mirror.remove()
    return {
      top: Math.max(0, Math.min(top, ta.clientHeight - 30)),
      left: Math.max(0, Math.min(left, ta.clientWidth - 220)),
    }
  },
}

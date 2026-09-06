// Distraction-free chrome state: auto-hiding top bar (with pin) and the
// collapsible editor/preview panes. Held as classes on <body> so LiveView
// re-renders never disturb it, persisted in localStorage per browser.

const KEY = "moorland:ui"

function load() {
  try {
    return JSON.parse(localStorage.getItem(KEY)) || {}
  } catch {
    return {}
  }
}

function save(ui) {
  try {
    localStorage.setItem(KEY, JSON.stringify(ui))
  } catch {}
}

const PAPERS = ["default", "sepia", "slate"]
const FONTS = ["default", "mono", "serif"]

export function applyUI() {
  const ui = load()
  const body = document.body
  body.classList.toggle("mo-header-pinned", !!ui.pinned)
  body.classList.toggle("mo-header-hidden", !!ui.headerHidden && !ui.pinned)
  body.classList.toggle("mo-editor-only", ui.layout === "editor")
  body.classList.toggle("mo-preview-only", ui.layout === "preview")
  for (const paper of PAPERS) {
    body.classList.toggle(`mo-paper-${paper}`, (ui.paper || "default") === paper)
  }
  for (const font of FONTS) {
    body.classList.toggle(`mo-font-${font}`, (ui.font || "default") === font)
  }
  body.classList.toggle("mo-typewriter", !!ui.typewriter)
  // Let the editor re-center panes that just became visible.
  window.dispatchEvent(new CustomEvent("moorland:layout-changed"))
}

export function typewriterOn() {
  return !!load().typewriter
}

// Called on every keystroke: writing tucks the toolbar away unless pinned.
export function autoHideHeader() {
  const ui = load()
  if (ui.pinned || ui.headerHidden) return
  ui.headerHidden = true
  save(ui)
  applyUI()
}

// Keep the fullscreen button's icon in sync however fullscreen is entered or
// left (button, F11, or Esc).
document.addEventListener("fullscreenchange", () => {
  document.body.classList.toggle("mo-fullscreen", !!document.fullscreenElement)
})

window.moorlandUI = {
  setPaper(name) {
    const ui = load()
    ui.paper = PAPERS.includes(name) ? name : "default"
    save(ui)
    applyUI()
  },

  setFont(name) {
    const ui = load()
    ui.font = FONTS.includes(name) ? name : "default"
    save(ui)
    applyUI()
  },

  toggleTypewriter() {
    const ui = load()
    ui.typewriter = !ui.typewriter
    save(ui)
    applyUI()
  },

  // Small screens: flip between editor and preview (transient, not saved).
  toggleMobilePane() {
    document.body.classList.toggle("mo-mobile-preview")
    window.dispatchEvent(new CustomEvent("moorland:layout-changed"))
  },

  // "Go to" support: make sure a pane is on screen before jumping into it.
  showEditor() {
    const ui = load()
    if (ui.layout === "preview") {
      ui.layout = "split"
      save(ui)
      applyUI()
    }
  },

  showPreview() {
    const ui = load()
    if (ui.layout === "editor") {
      ui.layout = "split"
      save(ui)
      applyUI()
    }
  },

  toggleFullscreen() {
    if (document.fullscreenElement) {
      document.exitFullscreen().catch(() => {})
    } else {
      document.documentElement.requestFullscreen().catch(() => {})
    }
  },

  toggleHeader() {
    const ui = load()
    ui.headerHidden = !ui.headerHidden
    // Explicitly hiding overrides a pin - the user just asked for it gone.
    if (ui.headerHidden) ui.pinned = false
    save(ui)
    applyUI()
  },

  togglePin() {
    const ui = load()
    ui.pinned = !ui.pinned
    if (ui.pinned) ui.headerHidden = false
    save(ui)
    applyUI()
  },

  // The divider's left chevron: collapse the editor (read-only page view),
  // or restore the split when the preview is the collapsed side.
  layoutLeft() {
    const ui = load()
    ui.layout = ui.layout === "editor" ? "split" : "preview"
    save(ui)
    applyUI()
  },

  // The divider's right chevron: collapse the preview (pure writing),
  // or restore the split when the editor is the collapsed side.
  layoutRight() {
    const ui = load()
    ui.layout = ui.layout === "preview" ? "split" : "editor"
    save(ui)
    applyUI()
  },
}

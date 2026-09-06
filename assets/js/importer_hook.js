import { fdxToFountain } from "./fdx"

// Dashboard "Import" button: reads .fountain/.txt/.fdx files locally and hands
// the resulting Fountain text to the LiveView, which creates the script.
export const ScriptImporter = {
  mounted() {
    this.input = this.el.querySelector("input[type=file]")
    if (!this.input) return

    this.input.addEventListener("change", async () => {
      const file = this.input.files && this.input.files[0]
      this.input.value = ""
      if (!file) return

      if (file.size > 2_000_000) {
        this.pushEvent("import_failed", { reason: "That file is too large (2 MB max)." })
        return
      }

      const raw = await file.text()
      const title = file.name.replace(/\.(fountain|fdx|txt)$/i, "")
      let content = raw

      if (/\.fdx$/i.test(file.name)) {
        content = fdxToFountain(raw)
        if (content === null) {
          this.pushEvent("import_failed", {
            reason: "That doesn't look like a valid Final Draft file.",
          })
          return
        }
      }

      this.pushEvent("import_script", { title, content })
    })
  },
}

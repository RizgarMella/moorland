// The update banner: dismissal is remembered per release tag, and the
// version picker expands client-side. Everything inside phx-update="ignore".
export const UpdateBanner = {
  mounted() {
    const tag = this.el.dataset.latest

    try {
      if (localStorage.getItem("moorland:update-dismissed") === tag) {
        this.el.hidden = true
        return
      }
    } catch {}

    this.el.querySelector("[data-dismiss]")?.addEventListener("click", () => {
      try {
        localStorage.setItem("moorland:update-dismissed", tag)
      } catch {}
      this.el.hidden = true
    })

    const versions = this.el.querySelector("[data-versions]")
    this.el.querySelector("[data-toggle-versions]")?.addEventListener("click", () => {
      if (versions) versions.hidden = !versions.hidden
    })
  },
}

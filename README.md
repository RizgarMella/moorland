# Moorland

A clean, collaborative screenwriting app in the spirit of Highland — built to
**democratise scriptwriting**: free software, an open format, your files on
your own disk or your own cloud, and collaboration without a central server.

One piece of software, distributed. Every install is identical; solo writer,
peer circle, or (future) studio are just configuration.

## The stack

- **Elixir / Phoenix LiveView** — server-rendered UI with real-time updates
- **SQLite** (via `ecto_sqlite3`) — a single local database file, no DB server
- **Tailwind v4 + daisyUI** — styling; **esbuild** — JS bundling
- Client-side JS (no framework): the Fountain parser, editor smarts, and all
  offline behavior live in `assets/js/`

## Quick start

Prereqs: Erlang/OTP 29 + Elixir 1.20 (on this machine they're installed at
`C:\Program Files\Erlang OTP` and `C:\Program Files\Elixir`, already on PATH).

```sh
mix deps.get
mix ecto.migrate
mix phx.server        # http://localhost:4000
mix test              # full suite (~180 tests)
```

Register an account at `/users/register` (the confirmation email appears in
the dev mailbox at `/dev/mailbox`). If you ever see *"could not compile
application ... restart your server"* it means a file in `config/` changed —
stop the server and start it again; code changes hot-reload, config doesn't.

## What it does

### Writing
- **Fountain editor with live preview** — plain text on the left, a properly
  typeset screenplay page on the right (Courier, industry margins, scene
  numbers, ~55-lines-per-page numbering, title page laid out to standard).
- **Stream-of-consciousness smart formatting** — press Enter and loose text
  becomes structure: `int coffee shop daisy Hey guys!` → a scene heading, a
  `DAISY` cue, and dialogue. Works line-by-line too, splits `(whispering)`
  and `(beat)` onto parenthetical lines, separates action from dialogue, and
  never touches title-page lines. The **Tidy** button (bottom-right of the
  editor) retro-formats a whole messy document. Ctrl+Z undoes everything.
- **Autocomplete** — characters, locations, scene prefixes, times of day,
  `(V.O.)`-style extensions, and title-page keys, harvested live from the
  script itself. Tab/Enter accepts, arrows navigate, Esc dismisses.
- **Script helper chips** (subtle, in the preview, editors only): add a
  missing DAY/NIGHT to a heading, fix a probable character-name typo
  ("DASIY → NORA?"), insert a standard title page.
- **Scene navigator** — list icon in the toolbar; click to jump, drag to
  reorder whole scenes.
- **Distraction-free chrome** — the toolbar auto-hides while typing (pin it
  to stop that, ⌃ hides it on demand, the top-center chevron brings it
  back); the divider chevrons `‹ ›` collapse either pane; a fullscreen
  button (Esc leaves). Layout is remembered per browser.
- **Light/dark themes**, offline-first editing (localStorage buffer that
  syncs — and merges — when the connection returns), Ctrl+S to force-save.

### Collaboration
- **Multi-user scripts** — share by email with a role: Editor, Commenter, or
  Viewer. Presence avatars show who's in the script; edits appear live.
- **Merge-safe co-editing** — every save carries the version it was built on;
  concurrent saves are three-way merged line-by-line on the server (both
  sides' work survives; only a same-line conflict falls to the newer write).
- **Comments & notes** — threaded, resolvable comments anchored to lines;
  highlight text in the preview to comment on exactly that bit; color-coded
  pinnable note cards.
- **Version history** — named snapshots, auto-snapshots every 10 minutes,
  line diffs against the current draft, non-destructive restore.
- **Reports** — page count, estimated runtime, speaking parts with dialogue
  share, scene mix (INT/EXT, DAY/NIGHT), locations.

### Peer-to-peer (phase one)
- Every install has an **Ed25519 identity** and a shareable peer code
  (`moor:<key>@host:port`) — see the **Peers** page.
- Both sides add each other's codes; then scripts shared from the editor's
  Share panel mirror onto the peer's machine and sync every ~10 s, merging
  through the same engine as local co-editing. All traffic is end-to-end
  encrypted and signed: each request is a sealed envelope (X25519 +
  ChaCha20-Poly1305 over the Ed25519 identities), unknown keys are rejected,
  and nothing about a script — not even its id — crosses the wire in the
  clear. Works on a LAN, VPN (e.g. Tailscale), a forwarded port, or the open
  internet. See `ROADMAP.md` for the path to holepunching + studios.
- **Comments, notes and history travel with the script.** Threads, replies
  and resolutions, sticky notes, and named snapshots sync both ways,
  deletions included, each record keyed by its own id. Authors on other
  installs show by handle with a "via peer" mark. The origin's history is
  the shared history; your own named snapshots join it.
- Try it locally: run a second copy with `PORT=4001 mix phx.server`.

### Your files are yours
- Everything lives in one **data folder** (default: this project directory) —
  the SQLite database plus `scripts/`, a **plain-text `.fountain` mirror of
  every script**, rewritten on every save. Readable in any text editor,
  forever, without Moorland.
- The Peers page → **Storage** card moves the data folder anywhere: an
  external drive or a Google Drive / iCloud / Dropbox folder for automatic
  cloud backup (one machine at a time against a synced folder). Env override:
  `MOORLAND_DATA_DIR`.
- **Export**: PDF via print (clean, or DRAFT/FINAL watermark), `.fountain`,
  Final Draft `.fdx`. **Import**: `.fountain`, `.txt`, `.fdx`.

### Updates
- Set `config :moorland, :update_repo, "owner/repo"` (or the
  `MOORLAND_UPDATE_REPO` env var) to your GitHub repo and Moorland checks its
  releases every 6 hours. A quiet banner on the Scripts page announces a
  newer version, with a version picker (latest highlighted, installed
  marked, pre-releases labeled) linking to each release. "Check for updates"
  lives on the Peers page. Until packaged builds land, updating = pull the
  release and restart.

## Code map

```
lib/moorland/
  scripts.ex               Core context: scripts, roles, comments, notes,
                           versions, peer shares, mirrors. All authz here.
  scripts/merge.ex         Line-based three-way merge (the collaboration core)
  scripts/content_cache.ex Recent-version cache + per-script save lock
  scripts/stats.ex         Report computation (Elixir port of the classifier)
  scripts/activity.ex      Comments, notes and history sync between installs
  storage.ex               Data folder, relocation, .fountain mirroring
  updates.ex               GitHub release checker for the update banner
  peers.ex                 P2P identity, peer codes, trust
  peers/crypto.ex          Ed25519 keys, signing, peer-code format
  peers/envelope.ex        The encrypted wire: sealed X25519 + ChaCha20-
                           Poly1305 envelopes, signed hello (pure functions)
  peers/transport.ex       Per-run key-exchange pair, peer keys, replay guard
  peers/client.ex          Encrypted outbound HTTP (:httpc, no deps)
  peers/sync.ex            Background reconciler (plan/2 is the pure logic)

lib/moorland_web/
  live/script_live/index.ex    Dashboard (+ import, update banner)
  live/script_live/editor.ex   The editor: toolbar, panels, all events
  live/peer_live/index.ex      Peers, storage, identity, update check
  controllers/peer_api_controller.ex  Encrypted peer wire (hello + envelope)

assets/js/
  fountain.js        Fountain parser + HTML renderer (line-tracked, paginated)
  smart_format.js    On-Enter smart formatting + tidyDocument
  editor_hook.js     The big editor hook: autosave/offline/merge sync,
                     autocomplete, preview sync, scene nav, export/print
  scene_tools.js     Scene list + drag-reorder (pure)
  fdx.js             Final Draft import/export
  ui_prefs.js        Distraction-free chrome + fullscreen (body classes)
  importer_hook.js   Dashboard file import
  update_banner_hook.js  Banner dismissal + version picker
```

Conventions worth knowing: all context functions take a `%Scope{}` first and
enforce roles; real-time flows through `Phoenix.PubSub` topic `script:<id>`;
the editor DOM under `#editor-root` is `phx-update="ignore"` (the hook owns
it); pure logic lives in plain modules/functions so `mix test` covers it, and
the JS logic modules were built to run under plain Node for testing.

## Roadmap

See `ROADMAP.md` — phase one's honest limitations, the path to the fully
distributed "last phase" (studio mode, encryption, holepunching, single-exe
packaging), Highland Pro parity gaps, and the editor backlog. AI features are
deliberately excluded (separate plan).

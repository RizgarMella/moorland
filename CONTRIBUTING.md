# Contributing to Moorland

Thanks for helping. This guide covers the stack, how to run and test the
app, where things live in the code, and the conventions that keep it
coherent. Product features and the roadmap are in [README.md](README.md)
and [ROADMAP.md](ROADMAP.md).

## Stack

- **Elixir / Phoenix LiveView**: server rendered UI with live updates.
- **SQLite** through `ecto_sqlite3`: one database file, no database server.
- **Tailwind v4 + daisyUI** for styling, **esbuild** for bundling.
- **Plain JavaScript, no framework**, for everything client side: the
  Fountain parser and renderer, smart formatting, the editor hook, offline
  behaviour, import and export. The logic modules run under Node as well as
  the browser so they can be tested in isolation.

## Setup

You need Elixir 1.17 or newer with a matching Erlang/OTP.

```sh
mix setup          # dependencies, database, asset tooling
mix phx.server     # http://localhost:4000, code reloads on save
mix test           # the whole suite
mix precommit      # what to run before you commit: compile with warnings
                   # as errors, prune unused deps, format, test
```

Register at `/users/register`; confirmation emails land in the dev mailbox
at `/dev/mailbox`.

Things that trip people up:

- Changing anything under `config/` needs a server restart. Code hot
  reloads; configuration does not. The error mentions it when it happens.
- To exercise peer to peer sync locally, run a second copy on another port
  with its own data folder:

  ```sh
  MOORLAND_DATA_DIR=/tmp/moorland-two PORT=4001 mix phx.server
  ```

  Add each copy's peer code to the other from the Peers page.
- The data folder is chosen by `MOORLAND_DATA_DIR`, else the pointer file
  `~/.moorland/data_dir` (written when a user relocates storage in the app),
  else the project directory.

## Code map

```
lib/moorland/
  scripts.ex               Core context: scripts, roles, comments, notes,
                           versions, peer shares, mirrors. All authorisation
                           lives here; every function takes a %Scope{} first.
  scripts/merge.ex         Line based three way merge (the collaboration core)
  scripts/content_cache.ex Recent version cache and per script save lock
  scripts/activity.ex      Comments, notes and history sync between installs
  scripts/stats.ex         Report computation (Elixir port of the classifier)
  storage.ex               Data folder, relocation, .fountain mirroring
  updates.ex               GitHub release checker behind the update banner
  peers.ex                 Installation identity, peer codes, trust
  peers/crypto.ex          Ed25519 keys, signing, peer code format
  peers/envelope.ex        The encrypted wire, as pure functions: sealed
                           X25519 + ChaCha20-Poly1305 envelopes, signed hello
  peers/transport.ex       Per run key exchange pair, learned peer keys,
                           replay guard
  peers/client.ex          Outbound calls over :httpc (no extra dependencies)
  peers/sync.ex            Background reconciler; plan/2 is the pure logic
  peers/discovery.ex       LAN discovery beacon

lib/moorland_web/
  live/script_live/index.ex    Dashboard: scripts, search, import, updates
  live/script_live/editor.ex   The editor: toolbar, panels, every event
  live/peer_live/index.ex      Peers, storage, identity, update check
  live/contact_live/index.ex   Contacts
  controllers/peer_api_controller.ex  Peer wire endpoints (hello, envelope)

assets/js/
  fountain.js            Fountain parser and HTML renderer, line tracked
                         and paginated
  smart_format.js        On Enter smart formatting and tidyDocument
  editor_hook.js         The editor hook: autosave, offline buffer and
                         merge sync, autocomplete, preview sync, scene
                         navigator, export and print
  scene_tools.js         Scene list and drag reorder (pure)
  fdx.js                 Final Draft import and export
  ui_prefs.js            Distraction free chrome and fullscreen
  importer_hook.js       Dashboard file import
  update_banner_hook.js  Update banner dismissal and version picker
```

## Conventions

- **Authorisation in the context, not the view.** Every function in
  `Moorland.Scripts` takes a `%Scope{}` and checks the caller's role. Views
  never decide who may do what.
- **Real time flows through PubSub.** Each script has the topic
  `script:<id>`; the editor subscribes and reloads panel data on events.
- **The editor owns its DOM.** Everything under `#editor-root` is
  `phx-update="ignore"` and driven by the hook.
- **Pure logic in plain modules.** Merge, sync planning, the envelope
  protocol, stats and the JavaScript logic modules are all side effect free
  and covered directly by tests.
- **No new runtime dependencies without a reason.** Peer networking uses
  what Erlang ships with (`:crypto`, `:httpc`, `:gen_udp`) so the eventual
  single file build stays small.
- **Peer sync is origin authoritative.** The installation that owns a script
  merges and decides; mirrors push and pull. New wire operations go through
  the sealed envelope in `PeerApiController` and `Peers.Client`.

## Packaging

Users get Moorland as one file per platform, built with
[Burrito](https://github.com/burrito-elixir/burrito), which wraps a Mix
release together with the Erlang runtime into a single executable.

- `mix release moorland` builds the packaged targets defined in `mix.exs`
  (`windows`, `macos`, `macos_arm`, `linux`) into `burrito_out/`. Set
  `BURRITO_TARGET` to build one. It needs exactly the Zig version Burrito
  pins (0.16.0 for Burrito 1.6), `xz`, and `7z` for the Windows target, and
  cannot run on a Windows host; use the Docker recipe below instead.
- `mix release moorland_server` is a plain OTP release for running Moorland
  on a server. It honours `DATABASE_PATH`, `SECRET_KEY_BASE`, `PORT` and
  `PHX_HOST`; without them it configures itself like the desktop build.
- Cross builds take SQLite's native library precompiled for the target.
  Set `TARGET_OS`, `TARGET_ARCH` and `TARGET_ABI` (for example `windows`,
  `x86_64`, `msvc`) and run `mix deps.compile exqlite --force` before the
  release; the workflow in `.github/workflows/release.yml` and
  `release/Dockerfile` show the values for each target.
- On any machine with Docker, including Windows:

  ```sh
  docker build -t moorland-release release/
  docker run --rm -v "$PWD:/app" -v moorland-build:/build \
    -e BURRITO_TARGET=windows -e TARGET_OS=windows -e TARGET_ARCH=x86_64 -e TARGET_ABI=msvc \
    moorland-release
  ```

- The packaged build has its own VM flags in `rel/desktop/vm.args.eex`.
  Two matter: `-noinput`, so the app survives a closed standard input, and
  `-extra --no-halt`, because Burrito starts the VM through the Elixir CLI
  without `--no-halt` and the VM would otherwise exit the moment boot
  finishes. Keep `-extra` last in that file.
- Burrito unpacks a binary once per version into a per-user cache
  (`%APPDATA%\.burrito` on Windows, `~/.local/share/.burrito` elsewhere)
  and reuses it. Bump the version in `mix.exs` for every release; when
  iterating on a build with the same version, delete that cache folder or
  run `moorland_<target> maintenance uninstall` first.
- Pushing a tag such as `v0.2.0` runs the release workflow: all four builds
  are attached to a GitHub release, which the in-app update banner reads.

Production configuration lives in `config/runtime.exs`: the data folder
(`MOORLAND_DATA_DIR`, else the pointer file, else the platform's application
data folder), a secret generated once and kept beside the database, a server
that is always on, and the browser launch (`MOORLAND_NO_BROWSER=1` to skip).

## Tests

`mix test` runs everything, including the peer wire against a real HTTP
listener on a loopback peer. Database tests use the Ecto sandbox. When you
add a feature, add its test beside the others under `test/moorland` or
`test/moorland_web`; pure logic gets unit tests, anything touching the wire
gets a controller test and, where it matters, a loopback client test.

## Roadmap and larger changes

Bigger pieces of work are listed and ordered in [ROADMAP.md](ROADMAP.md).
If you want to take one on, open an issue first so the approach can be
agreed before the code arrives.

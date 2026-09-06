# Moorland Roadmap

Principle: **one piece of software, distributed, no centralisation unless you want it.**
Every install is identical; roles (writer, peer, studio) are configuration, not products.
AI features are deliberately excluded from this roadmap — there is a separate plan for those.

## Where we are: phase one (shipped) and its limitations

Phase one delivered installation identity (Ed25519 keypair + `moor:` peer codes),
signed peer-to-peer HTTP sync, per-script sharing (editor/viewer), and mirrored
scripts that three-way merge through the same engine as same-server co-editing.

Known limitations, each mapped to the phase that removes it:

| # | Limitation | Removed in |
|---|------------|-----------|
| 1 | Reachability: peers connect only where the address is directly reachable (LAN, VPN, forwarded port) — no NAT traversal | Phase 3 |
| 2 | Discovery is manual: both sides must paste each other's codes | Phase 3 (mDNS on LAN, studio introductions beyond it) |
| 3 | Transport is signed but **not encrypted** — safe on LAN/VPN, not for the open internet | Phase 2 |
| 4 | Content-only sync: comments, notes, and version history stay on each machine | Phase 2 |
| 5 | Poll-based (~10 s) propagation between installs, not keystroke-live | Phase 2 |
| 6 | The origin machine is the authority and must be online for its scripts to sync — no third copy holds them | Phase 2 (studio backup) |
| 7 | If a save's base version falls out of the origin's cache (~200 versions), that save degrades to last-write-wins | Phase 2 (persist merge bases) |
| 8 | Mirrors attach to whichever local user added the peer; peer trust is per-installation, not per-user | Phase 2 |
| 9 | Runs as a dev server started by hand; nothing claims a `.local` name or updates itself | Phase 4 |

## The road to the last phase

Each phase is shippable on its own and none breaks the one before it.

**Phase 2 — Studio mode & a trustworthy wire.** The settings toggle that makes
any install also act as a studio: backup of members' shared scripts (fixes #6),
sharing management, and member introduction. Encrypt peer traffic (fixes #3),
sync comments/notes/history (#4), replace polling with peer-to-peer push
notifications (#5), persist merge bases (#7), and make peer trust per-user (#8).

**Phase 3 — Finding each other.** mDNS LAN discovery (`moorland-<shortid>.local`,
`_moorland._tcp`) so nearby peers appear with no code pasting (#2 on LAN), then
NAT holepunching (STUN/ICE-style, libp2p-inspired, `ex_webrtc` as a candidate)
with studios as rendezvous and, when punching fails, relays (#1, rest of #2).
After this, two writers anywhere on the internet can link with only their codes.

**Phase 4 — A product you double-click.** Burrito single-exe packaging that
claims its `.local` name on launch (#9), hot-swap release installs behind the
existing update banner, and the donation link.

**The last phase, reached:** download one file, run it, and you're a solo
writer; swap codes (or share a LAN) and you're a writing circle; flip one
switch and you're a studio others can join for backup and introductions —
with no central server anywhere unless someone chose to run one.

**The phase after that — production.** Once studios exist, Moorland grows from
writing into pre-production (the StudioBinder-class features below): a
production crew is exactly the studio trust-circle those documents distribute
through. Dependency chain there: breakdown → stripboard → DOOD/call sheets;
shot lists, contacts, and calendars are independent.

---

# The backlog, smallest to biggest

Everything not yet built, ordered by expected effort. Tags: [editor],
[peer] (phase 2–3 architecture), [production] (StudioBinder-class),
[packaging]. Sources of each set: user requests, Highland Pro parity
research, StudioBinder research (both Aug 2026).

## Tier 1 — Small — ALL SHIPPED (Aug 31 2026)

Donation link (config `:support_url`, About card on Peers page) · title page
form (chip opens a fill-in modal; hover the title page for "edit") · HTML &
Markdown export · paper palettes + font choices (Aa menu) · navigator now
lists sections and [[notes]] · writing goals with progress bars in Reports ·
merge bases persisted in the DB (limitation #7 closed) · gender tags on
speaking parts with a dialogue-balance line.

## Tier 2 — Medium — SHIPPED except one (Sep 1 2026)

Shipped: writing sprints (5/15/25 min timer with live word count, in
Reports) · typewriter scrolling (Aa menu) · Lookup panel (definitions/
synonyms/rhymes via Datamuse; needs internet, fails soft) · Bin & Shelf (cut
selection to per-script Bin, private cross-script Shelf, insert-at-cursor) ·
full-text search across scripts/comments/notes on the dashboard ·
@mentions + notifications (unread badges live via PubSub, email on mention,
read on opening Comments) · mobile layout (editor/preview flip button,
overlay panels) · push-based peer sync (save → signed notify → instant
sync; closes limitation #5) · LAN discovery (dependency-free signed UDP
beacon; "Nearby on this network" with one-click Add — the mDNS `.local`
name still comes with packaging) · per-user peer trust (closes #8) ·
script sides (Export → pick scenes → filtered PDF) · Contacts page.

Deferred from this tier:
- **Server-side PDF generation** [editor] — headless-Chromium print so
  Firefox/Safari exports get page numbers; deferred to avoid a browser-binary
  dependency before packaging. Revisit alongside the Burrito build.

## Tier 3 — Large (a week-ish each)

Shipped (Sep 6 2026): **encrypted peer transport** [peer, closes #3] — every
peer request is one sealed envelope: a fresh X25519 ephemeral key against
the peer's per-run key-exchange key (published by a signed, timestamped
`hello`), HKDF-SHA256, ChaCha20-Poly1305, and an Ed25519 signature over the
transcript; the reply comes back under a derived reply key; timestamps and a
replay guard bound reuse. Nothing about a script — not even its id — is in
the clear, so a future relay forwards only ciphertext. No new dependencies
(Erlang `:crypto` only). Installs from before this cannot talk to installs
after it; the Peers page says so.

Shipped (Sep 6 2026): **comments, notes & history peer sync** [peer, closes
#4] — the sync loop now carries activity alongside content. A mirror pushes
its own new or changed comments and notes, named snapshots, and deletions,
then pulls the origin's full comment and note lists plus unseen versions;
records match by a per-script `uid`, "still to push" is a revision counter
(`rev`/`synced_rev`), and the origin's share list carries an activity stamp
so mirrors pull only when something moved. Peer authors show by handle with
no local user (comments and notes were rebuilt with a nullable author). A
peer may add records and resolve any comment, but change or delete only what
it wrote; the origin's owner can delete anything and the next pull follows.

- **PDF import ("melt")** [editor] — extract editable Fountain from PDF
  screenplays.
- **Revision mode** [editor] — tracked changes: revision text in a chosen
  color with margin marks, steppable revision sets. Later feeds production's
  locked pages and colored draft revisions.
- **More document types & templates** [editor] — treatment, stage play,
  multi-cam, comic book, prose/novel (Markdown) with matching PDF layouts.
- **Production drafts** [production] — locked pages, colored revision drafts,
  scene numbers frozen for the shoot (builds on Revision mode).
- **Script breakdown** [production] — tag scene elements (cast, props,
  wardrobe, SFX/VFX…) by highlighting preview text (the comment-anchoring
  mechanism); auto-seed cast/locations from the parser; per-scene sheets and
  per-department reports.
- **Stripboard / shooting schedule** [production] — scenes as colored strips
  (INT/EXT, day/night, page-eighths from the pagination model) dragged into
  shoot days; grows out of the scene navigator's drag-reorder.
- **Shot lists & storyboards** [production] — per-scene shot tables created by
  highlighting a script line; storyboard images and mood boards stored in the
  data folder.
- **Media library** [production] — shared reference files in the data folder,
  synced to production peers like scripts are.
- **Production calendar & tasks** [production] — prep/shoot/post timeline and
  a simple assignable task board.
- **Day-out-of-days + call sheets** [production] — the cast-by-day grid
  derived from stripboard + breakdown, then per-day call sheets (schedule,
  call times, locations with map/weather, attachments) distributed via peer
  sync or PDF/email with received/confirmed tracking. Biggest of the
  production set because it depends on breakdown and stripboard.

## Tier 4 — Epic (multi-week, architectural)

- **Studio mode** [peer, phase 2 core; fixes #6] — the settings toggle that
  makes any install a studio: backup of members' shared scripts, sharing
  management, member introduction/relay.
- **Single-exe packaging + hot-swap updates** [packaging, fixes #9] — Burrito
  builds one file per OS; it claims `moorland-<shortid>.local` on launch;
  the existing update banner gains true install-on-restart (signature-checked
  downloads, rollback via the version picker).
  *In progress (Sep 6 2026):* shipped the self-configuring production build
  (data folder per platform, generated secret, server always on, browser
  launch, migrations on boot, mailbox loopback-only), Burrito targets for
  Windows, macOS (Intel and Apple silicon) and Linux with precompiled SQLite
  per target, a Docker recipe for building on any host, and a release
  workflow that attaches all four files to a tagged GitHub release. Left:
  the `.local` name claim (mDNS), install-on-restart with signature checks,
  and code signing for Windows and macOS.
- **NAT holepunching** [peer, phase 3 core; fixes #1–2] — STUN/ICE-style
  holepunching (libp2p-inspired; `ex_webrtc` a candidate) with studios as
  rendezvous and relay fallback, so any two writers on the internet can link
  with only their codes.

---

## Shipped along the way

- Fountain editor with live preview, industry typesetting, pagination, title
  pages; autocomplete; stream-of-consciousness smart formatting + Tidy;
  script helper chips (time-of-day, typo fix, title page).
- Multi-user roles, presence, merge-safe co-editing; threaded anchored
  comments (highlight-to-comment), notes; version history with diff and
  non-destructive restore; reports (pages/runtime/speaking parts/scene mix/
  locations).
- Export: watermarked PDF (clean/DRAFT/FINAL), Fountain, FDX; import:
  Fountain/txt/FDX.
- Peer-to-peer phase one: identity, peer codes, signed wire, per-script
  sharing, merging mirrors.
- Encrypted peer wire (Sep 2026): sealed, signed X25519 + ChaCha20-Poly1305
  envelopes over the Ed25519 identities; per-run key-exchange keys, replay
  guard, no new dependencies. Limitation #3 closed.
- Comments, notes and version history sync between installs (Sep 2026):
  two-way by per-script uid with revision counters, tombstoned deletions,
  peer authors by handle. Limitation #4 closed.
- Distraction-free chrome (auto-hiding pinned toolbar, collapsible panes,
  fullscreen); light/dark; scene navigator with drag-reorder.
- Position-precise go-to: double-click in the preview lands the cursor on
  that exact word; selection bubble with Comment/Go to; pane auto-expand and
  re-centering.
- Offline-first editing with merge-on-reconnect; movable data folder; plain
  `.fountain` mirrors of every script (no lock-in); GitHub update banner with
  version picker.

Already at or beyond Highland parity: comments and all collaboration,
version control, reports, offline mode, open storage — Highland has none of
these; its remaining edges are listed in the tiers above.

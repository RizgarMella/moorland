# Moorland Roadmap

Principle: **one piece of software, distributed, no centralisation unless you want it.**
Every install is identical; roles (writer, peer, studio) are configuration, not products.
AI stays outside the core: the only AI item here is the peer-shaped hook for
an external assistant (Directions, [ai]); the assistant itself has a separate plan.

## Where we are: phase one (shipped) and its limitations

Phase one delivered installation identity (Ed25519 keypair + `moor:` peer codes),
signed peer-to-peer HTTP sync, per-script sharing (editor/viewer), and mirrored
scripts that three-way merge through the same engine as same-server co-editing.

Known limitations of phase one, each mapped to the phase that removes it, and
where each stands now:

| # | Limitation | Removed in | Status |
|---|------------|-----------|--------|
| 1 | Reachability: peers connect only where the address is directly reachable (LAN, VPN, forwarded port) — no NAT traversal | Phase 3 | Open |
| 2 | Discovery is manual: both sides must paste each other's codes | Phase 3 (mDNS on LAN, studio introductions beyond it) | Partly: LAN beacon shipped Sep 1 2026; beyond the LAN still open |
| 3 | Transport is signed but **not encrypted** — safe on LAN/VPN, not for the open internet | Phase 2 | Closed Sep 6 2026 |
| 4 | Content-only sync: comments, notes, and version history stay on each machine | Phase 2 | Closed Sep 6 2026 |
| 5 | Poll-based (~10 s) propagation between installs, not keystroke-live | Phase 2 | Closed Sep 1 2026 (push notify) |
| 6 | The origin machine is the authority and must be online for its scripts to sync — no third copy holds them | Phase 2 (studio backup) | Open |
| 7 | If a save's base version falls out of the origin's cache (~200 versions), that save degrades to last-write-wins | Phase 2 (persist merge bases) | Closed Aug 31 2026 |
| 8 | Mirrors attach to whichever local user added the peer; peer trust is per-installation, not per-user | Phase 2 | Closed Sep 1 2026 |
| 9 | Runs as a dev server started by hand; nothing claims a `.local` name or updates itself | Phase 4 | Partly: one-file builds shipped Sep 6 2026; `.local` name and install-on-restart still open |

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
[packaging], and for the unsized Directions at the end: [prose], [ai],
[formats], [pipeline]. Sources of each set: user requests, Highland Pro
parity research, StudioBinder research (both Aug 2026), owner directions
(Sep 2026).

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
  *Shipped (Sep 30 2026):* History → Revisions starts sets in production
  order (Blue, Pink, Yellow... Double Blue), each keeping the saved text it
  began from (`RevisionSet`). `revisions.js` diffs that base against the
  live text (Myers, trimmed to the changed middle, ignoring fixed scene
  numbers) and stars changed lines in the preview and in print; any set
  can be picked to show changes since it began. Left: coloured page
  headers and page-level locking, and peer sync of the sets.
- **More document types & templates** [editor] — treatment, stage play,
  multi-cam, comic book, prose/novel (Markdown) with matching PDF layouts
  (prose/novel now developed under Directions below).
- **Production drafts** [production] — locked pages, colored revision drafts,
  scene numbers frozen for the shoot (builds on Revision mode).
  *Scene numbers shipped (Sep 30 2026):* "Lock scene numbers" in the scene
  navigator writes Fountain `#12#` numbers into the headings (plain text,
  survives any tool, round-trips through FDX's Number attribute); scenes
  added later show no number until "Number new scenes" gives them
  production numbers (12A, A1). Breakdown, stripboard and call sheets show
  these labels. Left: locked pages and coloured revision drafts.
- **Script breakdown** [production] — tag scene elements (cast, props,
  wardrobe, SFX/VFX…) by highlighting preview text (the comment-anchoring
  mechanism); auto-seed cast/locations from the parser; per-scene sheets and
  per-department reports.
  *Shipped (Sep 30 2026):* `BreakdownTag` rows (category, name, anchor words
  and line) placed into scenes fresh from the text by `Scripts.Breakdown`, so
  tags follow their words and report as unplaced when the words are cut;
  13 standard categories with colours; Tag in the preview's selection bubble
  and a Breakdown panel in the editor; `/scripts/:id/breakdown` with printable
  scene sheets (eighths, INT/EXT, time of day, speaking cast seeded) and a
  department view with rename/recategorise. Tags sync between installs
  through `Scripts.Activity` exactly like notes (a peer changes or deletes
  only its own tags at the origin). Left: CSV export, and the stripboard
  that grows out of the scene sheets.
- **Stripboard / shooting schedule** [production] — scenes as colored strips
  (INT/EXT, day/night, page-eighths from the pagination model) dragged into
  shoot days; grows out of the scene navigator's drag-reorder.
  *Shipped (Sep 30 2026):* `/scripts/:id/schedule`. One ordered list of
  `ScheduleItem`s per script (scene strips and end-of-day breaks with date
  and note); `Scripts.Schedule` matches strips to scenes by heading nearest
  the remembered line, then by location, so a DAY→NIGHT rewrite keeps its
  strip; cast numbered by size of part; day totals in eighths. Drag and
  drop from Unscheduled and within the board, arrows for touch and
  keyboard; edit rights to change it. The board syncs between installs as
  a whole (`Activity.replace_schedule`): the origin's replaces a mirror's
  on pull unless the mirror has unpushed changes (`schedule_rev` /
  `schedule_synced_rev` on Script), and an editor mirror's push replaces
  the origin's, last push wins. Left: per-item merging if two people
  schedule at once turns out to matter.
- **Shot lists & storyboards** [production] — per-scene shot tables created by
  highlighting a script line; storyboard images and mood boards stored in the
  data folder.
  *Shot lists shipped (Oct 1 2026):* **Shot** in the preview's selection
  bubble, `/scripts/:id/shots` with per-scene shots numbered 12A, 12B (I and
  O skipped), size/angle/movement/lens/description edited in place, up/down
  ordering, print layout. Shots anchor to words like tags
  (`Breakdown.place/2`, `Scripts.ShotList`) and sync between installs like
  tags. Left: storyboard images and mood boards (file storage).
- **Media library** [production] — shared reference files in the data folder,
  synced to production peers like scripts are.
- **Production calendar & tasks** [production] — prep/shoot/post timeline and
  a simple assignable task board.
- **Day-out-of-days + call sheets** [production] — the cast-by-day grid
  derived from stripboard + breakdown, then per-day call sheets (schedule,
  call times, locations with map/weather, attachments) distributed via peer
  sync or PDF/email with received/confirmed tracking. Biggest of the
  production set because it depends on breakdown and stripboard.
  *Day out of days shipped (Sep 30 2026)* as a view of the stripboard
  (`Schedule.day_out_of_days/1`: SW/W/WF/SWF/H per cast member per shoot
  day, work and hold totals). *Call sheets shipped (Sep 30 2026)* at
  `/scripts/:id/schedule/day/:n`, printable: crew/shooting call, location
  and per-cast calls stored on the day's break, scenes with synopses, cast
  with DOOD status and actors from the viewer's Contacts by role,
  department needs from the breakdown, advance schedule; they reach every
  peer the script is shared with, since the board syncs. Left: map and
  weather (need the network), attachments, and received/confirmed
  tracking.

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

## Far future — see VISION.md

Not a tier and not sized: `VISION.md` describes where Moorland is heading in the long run
(an AI-enabled movie, show and podcast maker built as a reproducible virtual studio: fixed
virtual characters, a props database, sketch -> decompose -> generate -> reassemble scenes,
conventional tooling for credits and overlays). It is context, not a commitment. Items
below or in the tiers that move towards it cite `VISION.md` explicitly; nothing else does.

## Directions — unsized

Owner directions from Sep 2026, not yet estimated or tiered: the place where
half-formed product ideas are recorded and developed until they are shaped
enough to join a tier. Each names what it builds on, the smallest step that
ships, and what is still open.

- **Idea sketch zone** [editor] — a place in the app for ideas that are not
  yet a script: half-formed premises, characters, scraps of dialogue,
  developed over time. Builds on per-script Notes (`Scripts.Note`: colour,
  pinned, peer-synced through `Scripts.Activity`), the private cross-script
  Shelf (`Scripts.Snippet`), and inline `[[notes]]` in the navigator.
  *First step:* a `kind` on Note (`note` | `sketch`), a Sketches tab in the
  Notes pane, and "Start a script from this sketch" calling
  `Scripts.create_script`; sync is free once `kind` rides in the note
  payload. *First step shipped (Sep 30 2026):* exactly that; the new script
  is titled from the sketch's first line and keeps the sketch in its
  boneyard, and notes from peers without a `kind` keep theirs. *Open:* sketches before any script exists need a home above
  scripts (a project, see the pipeline, or a nullable `script_id`); whether
  the Shelf folds into this.
- **Short stories and books** [prose] — prose as a first-class document;
  supersedes the prose/novel clause of "More document types" in Tier 3.
  Builds on `goal_words`, sprints, Markdown export in `fountain.js`, the
  section-aware navigator, and the `.fountain` data-folder mirror
  (`Moorland.Storage`). *First step:* a `kind` column on Script
  (`screenplay` | `prose`); in prose the editor skips `smart_format.js` and
  cue autocomplete, the preview renders Markdown, the navigator lists `#`
  and `##` headings as chapters and scenes, and the mirror is written as
  `.md`. *Open:* one document per book or one per chapter; which manuscript
  standard the PDF follows. Research (Sep 2026) into what prose needs that
  the screenplay editor lacks, with the cost of each:

  | Feature | Cost |
  |---|---|
  | `kind` column on Script, default `screenplay` | small |
  | Prose editor mode: no smart formatting or cue autocomplete, soft paragraphs, `*italic*` | medium |
  | Chapter and scene navigator from headings | reuses existing |
  | Word-count goals, sprints, live counts | reuses existing |
  | Front matter (title, author, contact, word count) via the title page form | reuses existing |
  | `.md` chapter files in the data-folder mirror | small |
  | Standard manuscript PDF (12pt, double-spaced, header slug) | small, a print stylesheet |
  | DOCX export, hand-rolled OOXML through Erlang `:zip`, no dependency | medium |
  | EPUB export (zip of XHTML plus OPF) | medium |
  | Style checks: repeated words, adverbs, passive voice, dialogue-tag counts (JS, like `typoSuggestions`) | small |
  | Reading time and chapter-length report | small |
  | Comments, notes, history, peer sync, offline | reuses existing |
  | Index cards per chapter or scene | medium |

- **AI collaborator as a peer** [ai] — an assistant that comments, checks
  consistency and proposes edits, connected exactly like a peer
  installation, so no AI runs inside Moorland. The assistant is a headless
  peer: its own Ed25519 identity and `moor:` code, speaking the existing
  sealed envelope (`hello`, `shared`, `fetch`, `activity`, `activity_push`,
  `save`, `notify`) against `PeerApiController`; the writer adds it on the
  Peers page and shares a script with it. Core changes, all small: (1) a
  `commenter` peer role (`PeerShare` allows `editor` and `viewer` only), with
  `Scripts.peer_apply_activity` accepting comments and notes from commenters
  while `peer_save` stays editor-only; (2) an `assistant` flag on
  `Peers.Peer`, so its comments and notes carry a badge and never trigger
  mention email; (3) optionally a `suggestion` activity kind, a Version-like
  record (proposed content plus a message) listed in History with Apply
  (the existing three-way merge) or Dismiss, so a commenter assistant can
  propose edits without write access. With the editor role it simply saves
  and merges like any peer. Consistency findings are ordinary anchored
  comments (`line_no`, `anchor_text`, `remote_author`). Outside the app: the
  assistant runtime, model choice, keys, prompts, and its own release, which
  is the separate plan. *First step:* the commenter role and the assistant
  badge, verified with a test that plays the peer. *First step shipped
  (Oct 1 2026):* `commenter` peer shares (comments, notes, breakdown tags
  and deletions of its own; never saves, snapshots or the board), an
  Assistant checkbox per peer on the Peers page, and `from_assistant` on
  comments and notes so the AI badge survives relaying to other mirrors;
  an assistant's @mentions notify in the app but send no email.
  `test/moorland_web/controllers/assistant_peer_test.exs` plays the
  assistant over the sealed wire. *Open:* size and rate
  limits on assistant pushes; whether "may propose edits" is a per-share
  toggle; suggestion records versus plain editor saves.
- **Podcast and educational scripts** [formats] — podcast episodes (hosts,
  segments, ad breaks, timings) and lesson scripts (objectives, narration,
  on-screen text). Builds on the Fountain parser (sections, synopses,
  character cues), the runtime and speaking-part reports, sides export, and
  the Tier 3 templates item. *First step:* `kind: podcast` as a Fountain
  flavour: a template, cues as hosts, sections as segments, runtime from
  words at speech rate, and one PDF layout. *Open:* whether educational
  scripts need a two-column audio/visual layout of their own; whether
  formats share one `kind` field with prose.
- **Story-to-script pipeline** [pipeline] — one project carries a work from
  idea to short story to fleshed-out story to script, with collaborators,
  enterable at any stage (drop a whole story in), and with Moorland helping
  build character specs. Builds on the sketch zone, the prose kind,
  Fountain/txt import, Bin & Shelf, `harvestCharacters`, gender tags on
  speaking parts, and peer sharing. *First step:* `stage` and
  `parent_script_id` on Script, a Stages strip in the editor, and "Start the
  next stage from this", which creates the next document prefilled (prose
  headings become scene stubs). Character specs: a Characters panel seeded
  from `harvestCharacters` plus a proper-noun pass over prose, each sheet
  stored as a `character` Note so it syncs to peers. *Open:* lineage fields
  versus a first-class Project schema; whether a peer share covers the whole
  lineage; where the AI peer hooks in to check consistency across stages.

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

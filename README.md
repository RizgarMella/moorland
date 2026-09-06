# Moorland

**Collaborative screenwriting that runs on your own machine, syncs directly
with the people you write with, and keeps every script as plain text you
own.**

Moorland is a screenwriting app for writers and writing rooms. Write in
Fountain with a properly typeset page beside you. Share a script with
collaborators by role. Link installations to each other and your scripts,
comments, notes and history flow between machines with no server in the
middle. It is free software built on an open format.

## Why Moorland

- **Your files are yours.** Every script is mirrored as a plain `.fountain`
  file in a folder you choose. Readable in any text editor, forever, with or
  without Moorland.
- **No central server.** Every installation is complete on its own. Link two
  and they talk to each other directly, end to end encrypted.
- **One install, any role.** Write alone, form a circle with the people you
  trust, or run a studio for a whole team. It is the same software with a
  different configuration.
- **Open formats in and out.** Fountain and Final Draft in. Fountain, Final
  Draft, PDF, HTML and Markdown out.

## Features

### Writing

- **A real page while you type.** Plain text on the left, an industry
  standard screenplay page on the right: Courier, correct margins, scene
  numbers, page breaks and a title page laid out to standard.
- **Smart formatting.** Type loosely and press Enter. `int coffee shop daisy
  Hey guys!` becomes a scene heading, a character cue and a line of dialogue.
  Parentheticals split onto their own lines, action separates from dialogue,
  and one click tidies a whole messy document. Undo reverts everything.
- **Autocomplete** for characters, locations, times of day, extensions like
  `(V.O.)` and title page keys, learned from the script itself.
- **Helper chips** in the preview offer fixes as you go: a missing DAY or
  NIGHT, a probable character name typo, a standard title page.
- **Scene navigator.** Click to jump, drag to reorder whole scenes. Sections
  and inline notes are listed too.
- **Focus.** The toolbar hides while you type. Collapse either pane, go
  fullscreen, switch on typewriter scrolling, and pick your paper colour and
  font. Light and dark themes. Works on a phone or tablet.
- **Goals and sprints.** Set word or page goals and watch the progress bar.
  Run a timed writing sprint with a live word count.
- **Lookup.** Definitions, synonyms and rhymes without leaving the editor.
- **Bin and Shelf.** Text you cut goes to the script's Bin. Text you want to
  keep across scripts goes to your private Shelf. Nothing is ever lost.
- **Offline first.** Keep writing without a connection. Your work merges
  back when the connection returns.

### Collaboration

- **Share by email** with a role: Editor, Commenter or Viewer. See who is in
  the script with you and watch edits appear live.
- **Merge safe editing.** When two people save at once, both sets of changes
  survive. Only a change to the very same line falls to the newer write.
- **Comments where they belong.** Highlight text in the preview to comment on
  exactly that passage. Threads, replies and resolution. Colour coded,
  pinnable note cards for everything else.
- **Mentions.** Write `@name` in a comment and they get a notification and an
  email.
- **Version history.** Named snapshots, automatic snapshots as you work, line
  by line diffs against the current draft, and restore that never destroys
  anything.
- **Search** across every script, comment and note you can access.
- **Contacts.** A rolodex for cast and crew, ready for production paperwork.

### Reports

Page count, estimated running time, speaking parts with each character's
share of dialogue, scene mix by interior and exterior and by day and night,
locations, and a dialogue balance line from optional gender tags.

### Working with someone on another machine

Moorland installations link to each other directly.

- Every installation has an identity and a short **peer code**. Swap codes
  with a collaborator, or find each other automatically on the same network,
  and you are linked.
- **Share a script** from its Share panel to a peer as Editor or Viewer. It
  appears on their Scripts page and stays in sync from then on. Edits from
  both sides merge, the same way they do between collaborators on one
  install.
- **Comments, notes and history travel too.** Threads, resolutions, notes and
  named snapshots sync in both directions. Authors on other installations are
  shown by name with a small "via peer" mark.
- **Private by construction.** Everything between installations is end to
  end encrypted and signed. Only peers you have added are served, and nothing
  about a script crosses the wire in the clear.
- Works on a local network, over a VPN such as Tailscale, through a
  forwarded port, or across the open internet.

### Import and export

- **Import** Fountain, plain text and Final Draft (`.fdx`) files.
- **Export** to PDF (clean, or watermarked DRAFT or FINAL), sides for chosen
  scenes, Fountain, Final Draft, HTML and Markdown.

### Your data, your folder

Everything Moorland knows lives in one data folder: a single database file
plus a `scripts` folder holding the plain text mirror of every script,
rewritten on every save. Move the folder to an external drive or a cloud
synced folder from the Storage card on the Peers page, and you have backup
without giving anyone your scripts.

## Getting started

Moorland runs on your own computer. You need Elixir 1.17 or newer with a
matching Erlang/OTP release ([install guide](https://elixir-lang.org/install.html)).

```sh
git clone https://github.com/RizgarMella/moorland.git
cd moorland
mix setup
mix phx.server
```

Open <http://localhost:4000> and create an account. Confirmation emails are
delivered to the built in mailbox at `/dev/mailbox`, so no mail server is
needed.

### Linking with a collaborator

1. Open the **Peers** page and copy your peer code. Send it to your
   collaborator, and add theirs. On the same network, they appear under
   **Nearby on this network** with a one click Add.
2. Open a script, choose **Share**, and pick the peer and their role.
3. The script appears on their Scripts page within seconds and stays in sync.

Your installation needs an address the other side can reach: the same
network, a VPN, or a forwarded port. Connecting through home routers without
any setup is on the roadmap.

## Staying up to date

Point Moorland at a GitHub repository with `config :moorland, :update_repo,
"owner/repo"` (or the `MOORLAND_UPDATE_REPO` environment variable) and it
checks for releases every six hours. A quiet banner on the Scripts page
announces a newer version with a version picker, and the Peers page has a
manual check. Updating today means pulling the release and restarting; one
file installers with in place updates are on the roadmap.

## Roadmap

Studio mode, so any installation can also back up and introduce a circle of
writers. Connecting across the internet with nothing more than two peer
codes. One file installers for every platform. Then pre-production: script
breakdowns, stripboards and shooting schedules, shot lists, day out of days
and call sheets, distributed through the same peer circle. Details and
current status are in [ROADMAP.md](ROADMAP.md).

## For developers

Moorland is written in Elixir with Phoenix LiveView, stores everything in
SQLite, and keeps its editor logic in dependency free JavaScript. See
[CONTRIBUTING.md](CONTRIBUTING.md) for setup, the test suite, and a map of
the code.

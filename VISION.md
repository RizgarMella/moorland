# Moorland: the far-future vision, the Beard of Evil studio

> **Status: vision, not plan.** Nothing in this file is scheduled, sized or approved for work.
> It exists so that everyone (and every agent) working on Moorland knows where it is heading
> and does not build against it by accident. Do not implement, scaffold or "prepare for"
> anything here unless a `ROADMAP.md` item explicitly cites this file. The roadmap's principle
> stands: AI stays outside the core until a roadmap item says otherwise.

## In one paragraph

Moorland grows from a screenwriting app into an **AI-enabled movie, show and podcast maker**:
the **Beard of Evil** studio, a virtual studio with its own website, that takes a project through each step of development with AI doing the
work and humans steering, approving and correcting at every stage. It writes and develops
scripts, develops characters, and produces the visuals and audio through different specialised
agents (model access via OpenRouter, so the best model for each job can be swapped in). It
never goes straight from idea to finished content: **reproducibility is the core**. A scene is
first rendered as an AI sketch, that sketch is decomposed into its props and elements, each
element is generated and stored, and the scene is reassembled from those stored parts, so the
same scene, character or prop comes out the same way every time it is needed. Things that
conventional tooling already does deterministically (credits, titles, overlays, text on
screen) are done with conventional movie-creation software, not generated.

## Beard of Evil: the studio and its website

The studio has a name, **Beard of Evil**, and a public face of its own: a website that is the
studio's front door rather than Moorland's. Moorland is the tool; Beard of Evil is what the
tool produces and presents. The website is where the studio's productions (films, shows,
podcasts), its fixed virtual characters and its universes are published and can be watched,
listened to and followed, with the studio's identity, credits and catalogue. Internally it is
also the studio's control room: projects in development, their stage in the pipeline, and the
props and character databases behind them. Which parts are public and which are private is a
decision for when the studio exists; the split is: **Moorland = making, Beard of Evil = the
studio and its output**.

## What it is made of (eventually)

| Piece | Role | Notes |
|---|---|---|
| Development pipeline | idea -> premise -> outline -> characters -> script -> revisions | AI agents per step, a human gate at each step; Moorland's editor, comments, versions and sharing are the workbench |
| Story-writing agents | develop scripts and characters | the parked prototype in `incoming/show-script-maker` (eight agents, frameworks, templates) is the reference for this layer |
| Character studio | **fixed virtual characters**: identity, appearance, voice, mannerisms defined once and reused across scenes and projects | the same character must look and sound the same in every shot |
| Props database | a **massive library of generated props and elements**, each stored with the inputs that produced it | scenes are assembled from the database, not regenerated from scratch |
| Scene pipeline | AI sketch of the scene -> decomposition into props/elements -> generate or fetch each -> reassemble the scene -> render | reproducible by construction; a change to one prop propagates |
| Rendering agents | image, video, voice and music generation via OpenRouter-routed models | interchangeable models behind one interface |
| Conventional finishing | credits, titles, overlays, text, packaging | movie-creation software, deterministic, not generative |
| Podcast path | the same pipeline with audio-only output: script -> voices -> sound -> episode | |
| Beard of Evil website | the studio's own site: catalogue of productions, characters, universes; the studio's identity and credits; internal control room for projects in development | separate from Moorland's own site/docs |

## Principles that must survive

- **Reproducibility first.** Every generated asset records what produced it; the pipeline can
  be re-run to the same result. No "one-shot" generation of a finished scene.
- **Human in the loop at every step.** AI proposes, people approve. The development steps stay
  visible and editable, they are not hidden inside a single prompt.
- **Fixed characters and reusable props**, so continuity is a property of the data, not luck.
- **Moorland's existing principle holds**: one piece of software, distributed, no
  centralisation unless you want it; AI outside the core. The studio is a layer that
  talks to Moorland the way a peer does.
- **Generate only what must be generated.** Deterministic tooling wherever it exists.

## Where the pieces are today

- Moorland (this repo): writing, typesetting, collaboration, versions, sync. Shipped.
- `incoming/show-script-maker`: a working Claude Code screenwriting pipeline, kept for later
  integration into the story-writing layer. Not wired in; not part of the build.
- The Beard of Evil studio and its website: name chosen, nothing built.
- Everything else in the table above: not started.

## How this file is used

- Roadmap items that move towards this vision cite `VISION.md` in their text. Until an item
  does, treat the vision as background only.
- When a piece here becomes real, its description moves out of this file and into
  `ROADMAP.md` (sized) and then into the code and README.

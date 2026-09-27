# Scratch

A floating scratchpad for macOS: one pad you type into, transform, copy and clear. macOS 14+.

## What it is

Scratch lives in the menu bar (no Dock icon) and opens a glass panel (Control-Option-N) on
the pad you last worked on, with the caret at the end, ready to type. When you are done, Clear
(Cmd-K) empties it in one undoable step. Pads are ordinary markdown files, saved as you type.

The slim header holds the pad's title (click to rename), then Clear, Copy, Transform, Pin, the
Pads menu (switch, create or delete pads) and dismiss. The list of pads beside the editor is
optional: the chevron at the left of the header or Cmd-Shift-L shows it, and the choice is kept
as the `sidebar.visible` setting (off by default).

Scratch is a MacHUD app: it uses HUDKit's panel and glass, ships a `machud.json` manifest and
answers the MacHUD control socket (see [docs/CONTRACT.md](docs/CONTRACT.md)), including a compact
one-line strip (click it to open the pad). Its panel is a `hover` panel: MacHUD drops it down
while the pointer is over its dock button and hides it when the pointer leaves. A socket show
never takes keyboard focus; the pad becomes key when you click it, and the app is never
activated. The `scratch` command-line tool drops text into it from shell pipelines, which is
also how an agent hands you text:

```sh
pbpaste | scratch append           # onto the Inbox pad under a timestamp
make 2>&1 | scratch new title="build log" show=1
```

## Install

Check out HUDKit (the shared kit and build scripts) next to this repo, then install:

```sh
ls ~/dev            # hudkit  scratch
~/dev/scratch/install.sh
```

`install.sh` builds a release, quits a running copy, installs `/Applications/Scratch.app`, links
the `scratch` command onto your PATH and launches it.

## Use

| Key | Action |
|---|---|
| Control-Option-N | show or hide the panel (global) |
| Control-Option-Shift-V | paste to Scratch: append the clipboard to the Inbox pad and show the panel for a moment (global) |
| Cmd-K | clear the pad (Cmd-Z brings it back; pads of 2,000 characters or more also show "Cleared — Undo" for 5 s) |
| Cmd-Shift-L | show or hide the pad list |
| Cmd-N | new pad |
| Cmd-F | find in the pad (from the editor) or search all pads (from the sidebar); Cmd-Option-F always searches pads |
| Cmd-Shift-V | paste as plain text, with Strip Formatting applied (straight quotes, plain spaces, no zero-width characters) |
| Cmd-Shift-C | copy the whole pad |
| Cmd-Shift-M | monospaced / proportional font |
| Cmd-Shift-Delete | delete the pad (Undo in the footer, or Cmd-Z from the sidebar); also in the Pads menu and the sidebar |
| Cmd-Z / Cmd-Shift-Z | undo / redo (each pad has its own history) |
| Cmd-S | nothing to do: pads save automatically |
| Esc, Cmd-W | clear the search, then hide (the panel comes back at the same place) |

The wand button (and the editor's context menu, and the menu bar's Transform Pad) transforms the
selection, or the whole pad when nothing is selected, as one undoable edit: trim, trim lines,
remove duplicate lines, sort / reverse lines, strip formatting, markdown to plain text, JSON
pretty / minify, base64 encode / decode, URL encode / decode, UPPER / lower / Title / Sentence
case, camelCase, snake_case, kebab-case.

Drag a selection out of the editor to drop it anywhere. Drop text onto the sidebar (or anywhere
outside the editor) to make a new pad; drop files to make a pad per file with a `file:` link and,
for UTF-8 text under 1 MB, the contents.

## Pads

Each pad is `~/Library/Application Support/Scratch/pads/<id>.md`:

```markdown
---
id: 20260926-140305-a1b2c3
created: 2026-09-26T14:03:05.000Z
updated: 2026-09-26T14:10:00.000Z
pinned: false
---
# Shopping
- eggs
```

The title is the first non-empty line (markdown markers removed) unless the front matter has a
`title:`. Markdown files you put in the folder yourself show up too (read at launch). Pinned pads
sort first, then the most recently edited. The Inbox pad is created on first paste and pinned.

## MacHUD contract

Panel `pad`, kind `hover`, order 1 (the first hover button in the MacHUD dock), socket `scratch`.
Verbs: the HUDKit set (`hello`, `state`, `subscribe`, `panel show|hide|toggle|frame|mode`,
`settings get|set|schema`, `action`, `quit`) plus the actions `append`, `new`, `open`, `list`,
`get`, `clear` and `drop`. Files dropped on the MacHUD dock button arrive as `action drop` and
become a pad each, as if dropped on the panel. Full reference:
[docs/CONTRACT.md](docs/CONTRACT.md).

```sh
scratch hello
pbpaste | scratch append show=1
scratch new title="Notes" text="first line"
scratch list query=eggs
scratch body id=inbox
scratch panel mode id=pad compact
scratch quit
```

## Settings

| Key | Type | Default | |
|---|---|---|---|
| `sidebar.visible` | bool | `false` | the list of pads beside the editor (Cmd-Shift-L) |
| `defaultMonospace` | bool | `true` | editor starts in a monospaced font |
| `autosaveDelay` | number (0.1-10, step 0.05) | `0.75` | seconds after the last keystroke before the pad is written |
| `inboxPosition` | `append` / `prepend` | `append` | where new inbox entries go |
| `inboxShowsPanel` | bool | `true` | the paste-to-Scratch hotkey shows the panel briefly |

Set them in MacHUD's settings window or with `scratch settings set key=value`. Stored in
`~/Library/Application Support/Scratch/preferences.json` (`menuBar.consumed`, HUDKit's menu bar
opt-out, in `menubar.json` beside it).

## Build from source

Needs Swift 5.9+ and HUDKit checked out next to this repo (`../hudkit`).

```sh
swift test          # ScratchKitTests (store, search, inbox, transforms) + ScratchTests (host, manifest)
./build.sh          # build/Scratch.app (release; ./build.sh debug), CLI at Contents/Helpers/scratch
./install.sh        # build, install to /Applications, link `scratch` onto PATH, launch
build/Scratch.app/Contents/MacOS/Scratch --snapshot /tmp/scratch.png [--snapshot-mode compact] [--select <id>] [--search <query>]
```

`--snapshot` writes a PNG of the panel two seconds after launch (the glass is drawn as a dark
stand-in), for checking the UI without Screen Recording permission.

`build.sh` and `install.sh` call HUDKit's shared `scripts/hud-build.sh` and `scripts/hud-install.sh`
(set `HUDKIT_DIR` if HUDKit lives elsewhere). The version comes from [VERSION](VERSION); changes
are in [CHANGELOG.md](CHANGELOG.md).

Layout: `Sources/ScratchKit` (pads, store, search, transforms; no UI), `Sources/Scratch` (the app;
`Resources` holds `Info.plist`, the manifest and the settings schema), `Sources/ScratchCLI` (the
`scratch` tool).

## Isolation env vars for testing

| Variable | Effect |
|---|---|
| `SCRATCH_HOME` | base directory for pads and preferences (default `~/Library/Application Support/Scratch`); an isolated instance also keeps its panel frames apart |
| `SCRATCH_SOCKET` | socket name (default `scratch`); the CLI honours it too |
| `SCRATCH_NO_HOTKEYS` | set to skip registering global hotkeys |

```sh
SCRATCH_HOME=$(mktemp -d) SCRATCH_SOCKET=scratch-test SCRATCH_NO_HOTKEYS=1 build/Scratch.app/Contents/MacOS/Scratch &
SCRATCH_SOCKET=scratch-test build/Scratch.app/Contents/Helpers/scratch hello
```

## License

MIT, see [LICENSE](LICENSE).

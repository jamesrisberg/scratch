# Scratch's MacHUD contract

Scratch implements the MacHUD contract through HUDKit. MacHUD reads
`Scratch.app/Contents/Resources/machud.json` without launching the app and talks to the running
app over a Unix socket. The shared parts are specified in HUDKit's
[docs/CONTRACT.md](https://github.com/jamesrisberg/hudkit/blob/main/docs/CONTRACT.md): the [manifest](https://github.com/jamesrisberg/hudkit/blob/main/docs/CONTRACT.md#manifest), [socket](https://github.com/jamesrisberg/hudkit/blob/main/docs/CONTRACT.md#socket)
framing and errors, the [required verbs](https://github.com/jamesrisberg/hudkit/blob/main/docs/CONTRACT.md#verbs), [subscribe](https://github.com/jamesrisberg/hudkit/blob/main/docs/CONTRACT.md#subscribe-and-state-events),
the [settings schema](https://github.com/jamesrisberg/hudkit/blob/main/docs/CONTRACT.md#settings-schema), [hover behaviour](https://github.com/jamesrisberg/hudkit/blob/main/docs/CONTRACT.md#behaviour-hover-and-windowed),
[file drops](https://github.com/jamesrisberg/hudkit/blob/main/docs/CONTRACT.md#file-drops) and [menu bar consolidation](https://github.com/jamesrisberg/hudkit/blob/main/docs/CONTRACT.md#menu-bar-consolidation). This page
lists what Scratch adds.

- Manifest: `Sources/Scratch/Resources/machud.json`: app `xyz.machud.scratch`, socket `scratch`, one panel `pad`
  (`kind: hover`, `order: 1` (first hover button in the MacHUD dock), symbol `note.text`, default 560x400, compact 360x44, capabilities
  `acceptsFileDrop` and `acceptsTextDrop` (MacHUD uses only the first), settings schema `settings.json`).
- Hover: MacHUD shows the pad while the pointer is over its dock button and hides it on leave.
  Plain `panel show`/`hide`/`toggle` fade in 0.22 s / out 0.18 s (HUDAnimation's durations) and keep
  the last frame. With MacHUD's dock options: the pad rests at the frame `panel frame` last
  assigned (until the user moves it), else next to the button (`anchor=` + `from=`,
  `HUDPanelTransition.panelFrame`), else its last frame; `reason=hover` fades in within 0.08 s;
  `from=<edge>` without hover slides out of that edge (`HUDAnimation.slide(in:)`); `hide to=<edge>`
  slides toward the dock while fading out in 0.1 s (a hover hide without `to=` fades in 0.1 s). A
  show that arrives mid-hide (moving between hover buttons) wins: the hide never orders the panel
  out afterwards. `reason=click|summon` make the panel key so typing lands in the pad; hover and
  option-less socket shows never make it key, and Scratch is never activated. The editor is first
  responder with the caret at the end, so a click on the pad (which makes the non-activating
  panel key) is all it takes to type. The Control-Option-N hotkey and the menu bar item show it
  focused. Dismiss (the header's close button, Esc, Cmd-W) hides; it never quits.
- Socket: `~/Library/Application Support/MacHUD/sockets/scratch.sock` (0600), one JSON object per
  line: `{"command": "...", "args": {...}}` in, `{"ok": true, ...}` or `{"ok": false, "error": "..."}` out
  ([framing](https://github.com/jamesrisberg/hudkit/blob/main/docs/CONTRACT.md#framing-and-connections)).
  Request lines are limited to 1,000,000 bytes by HUDKit, which bounds `text=`.
- CLI: `scratch <command> [key=value ...]` (in `Scratch.app/Contents/Helpers/scratch`, linked onto
  PATH by `install.sh`). `append`, `new`, `open`, `list`, `get`, `clear` and `body` are shorthands for
  `action name=<verb>`; `append` (and `new`, when stdin is piped) read the text from stdin when no
  `text=` is given.

## Verbs

| Command | Args | Result |
|---|---|---|
| `hello` | | `{app, name, hudkit, version, panels, verbs}`: `hudkit` is the contract version, `version` the app's (`VERSION`) |
| `state` | | `{panels: [{id: "pad", visible, mode, badge, status}]}`: `badge` is the number of pads, `status` the selected pad's title |
| `subscribe` | `events=state` (optional) | acknowledged, then `{"event": "state", "panels": [...]}` on visibility, mode, frame, selection and pad changes. Pad changes (including typing) are coalesced over 0.4 s and only pushed when the badge or status changed. `scratch watch` prints them. |
| `panel show` / `hide` / `toggle` | `id=pad` | fades in or out at the last frame, without taking focus |
| `panel frame` | `id=pad x= y= w= h=` | AppKit screen coordinates; kept as the frame for the current mode |
| `panel mode` | `id=pad` + `full`, `compact` or `parked` | `compact` is a 44 pt strip with the selected pad's title, when it last changed and the pad count (a click returns to full); `parked` slides to the nearest screen edge leaving a 14 pt sliver, or to `edge=left/right/top/bottom` with a `peek=` pt sliver when given (as MacHUD does; they are remembered for later bare `parked`s) |
| `settings get` | `key=` (optional) | see below |
| `settings set` | `key=value ...` | validates every value before applying any |
| `settings schema` | | `{schema}` from `settings.json` |
| `action append` | `text=`, `id=` (optional), `show=1` (optional) | without `id=`: adds the text to the **inbox** pad under a `--- yyyy-MM-dd HH:mm:ss ---` separator (bottom or top per `inboxPosition`), creating the inbox on first use. With `id=`: appends to that pad on a new line, no separator. Written to disk at once. `show=1` selects the pad and shows the panel briefly without taking focus. Returns `{pad: {...}}` |
| `action new` | `text=` (optional), `title=` (optional), `show=1` (optional) | creates and selects a pad; `title=` overrides the first-line title. Returns `{pad: {...}}` |
| `action open` | `id=` | selects the pad and shows the panel |
| `action clear` | `id=` (default: selected pad) | empties the pad's body and keeps the pad; a title derived from the body goes back to "Untitled", an explicit one (`title=`, the Inbox's) stays. One undoable step. Written at once. Returns `{pad: {...}}` |
| `action list` | `query=` (optional) | `{count, pads: [...]}`, pinned first then most recently edited; `query=` runs the full-text search |
| `action get` | `id=` (default: selected pad) | `{pad: {..., body}}` |
| `action drop` | `paths=` (percent-encoded paths joined with `\|`, `HUDDrop.encode`) | files dropped on MacHUD's dock button, handled like a drop on the panel: one pad per file titled with its name, holding a link to the file plus its contents when it is UTF-8 text under 1 MB (other files: just the link). Missing files are skipped; none left is an error. The last pad is selected. Returns `{count, pads: [...]}` |
| `menu` / `menu-invoke` | `id=` (`title=` optional) | the status menu, so MacHUD can host it ([menu bar consolidation](https://github.com/jamesrisberg/hudkit/blob/main/docs/CONTRACT.md#menu-bar-consolidation)) |
| `action show` / `hide` / `toggle` | | same as the panel verbs |
| `quit` | | replies, then quits (pending autosaves are written; the socket file is removed) |
| `help` | | lists the registered commands |

A pad summary is `{id, title, pinned, inbox, created, updated, chars}` (ISO 8601 dates).

## Settings

`Sources/Scratch/Resources/settings.json` describes them for MacHUD's shared settings window in
HUDKit's [settings schema](https://github.com/jamesrisberg/hudkit/blob/main/docs/CONTRACT.md#settings-schema) format; `autosaveDelay` uses its `number` type
with `min`/`max`/`step`, which the router enforces on `settings set` before Scratch sees the value.
Values are stored in `<home>/preferences.json`, where home is `~/Library/Application Support/Scratch`
or `$SCRATCH_HOME`, and merged over the defaults key by key when read (a missing or unreadable value
takes its default alone). HUDKit adds `menuBar.consumed` (bool, default `true`), kept in
`<home>/menubar.json`.

| Key | Type | Default | Meaning |
|---|---|---|---|
| `sidebar.visible` | bool | `false` | the list of pads beside the editor (Cmd-Shift-L); off, the header's Pads menu switches pads |
| `defaultMonospace` | bool | `true` | editor starts in a monospaced font |
| `autosaveDelay` | number (0.1-10, step 0.05) | `0.75` | seconds after the last keystroke before the pad is written |
| `inboxPosition` | `append` / `prepend` | `append` | where new inbox entries go |
| `inboxShowsPanel` | bool | `true` | the paste-to-Scratch hotkey shows the panel briefly |

## Handing text to the user (agents, scripts)

```sh
some-command | scratch append              # onto the inbox, timestamped, quietly
some-command | scratch append show=1       # and flash the panel so the user sees it
git diff | scratch new title="Review notes" show=1
scratch body id=inbox                      # read it back
```

## Environment

| Variable | Read by | Effect |
|---|---|---|
| `SCRATCH_HOME` | app | base directory for pads (`<home>/pads`), preferences and `menubar.json`; an isolated instance also keeps its panel frames in a separate defaults suite |
| `SCRATCH_SOCKET` | app, CLI | socket name instead of `scratch` |
| `SCRATCH_NO_HOTKEYS` | app | skip global hotkeys |

They let a second instance run beside the real one, e.g. for tests:

```sh
SCRATCH_HOME=/tmp/scratch-test SCRATCH_SOCKET=scratch-test SCRATCH_NO_HOTKEYS=1 \
  build/Scratch.app/Contents/MacOS/Scratch &
SCRATCH_SOCKET=scratch-test build/Scratch.app/Contents/Helpers/scratch state
```

## Launch flags

| Flag | Effect |
|---|---|
| `--snapshot <path.png>` | show the panel, write a PNG of it after it settles (about 2 s; the glass is a dark stand-in); the app keeps running |
| `--snapshot-mode compact` | with `--snapshot`: picture the compact strip |
| `--select <id>` | start on that pad |
| `--search <query>` | start with a sidebar search |

# Changelog

All notable changes to Scratch are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/); the current version is in [VERSION](VERSION).

## [Unreleased]

## [0.3.0] - 2026-10-02

### Fixed
- `--snapshot` draws the panel only: it no longer starts the control socket under the app's default name (which clashed with the running app), registers the hotkey or adds a second menu bar icon.

## [0.2.0] - 2026-09-29

### Changed
- Built with HUDKit 0.2.0: `hello` reports contract version 0.2.0, and a socket request's
  `args` values that are JSON objects or arrays reach the app as JSON text.

## [0.1.0] - 2026-09-27

### Added
- ScratchKit: pads as markdown files with front matter (`<home>/pads/<id>.md`), debounced
  autosave, delete/restore, the pinned, timestamped Inbox pad, full-text search, text stats,
  dropped-file drafts, and transforms (trim, line dedupe/sort/reverse, strip formatting,
  markdown to plain text, JSON pretty/minify, base64, URL encoding, case changes).
- Scratch app: menu bar item (no Dock icon) and a hover panel on HUD glass (Control-Option-N)
  opening on the last pad with the caret at the end; slim header with an editable title, Clear,
  Copy, Transform, Pin, the Pads menu and dismiss; optional pad list (`sidebar.visible`,
  Cmd-Shift-L); paste-to-Scratch hotkey (Control-Option-Shift-V); drag and drop of text and
  files; compact one-line strip.
- Clear a pad in one undoable step (Cmd-K, menu bar, `clear`), with a "Cleared — Undo" toast
  for long pads; explicit titles survive a clear.
- MacHUD contract through HUDKit: manifest (panel `pad`, kind `hover`, order 1, capabilities
  `acceptsFileDrop` and `acceptsTextDrop`), the `append`, `new`, `open`, `list`, `get`, `clear`
  and `drop` actions, debounced state events, `panel mode parked` at the edge and peek MacHUD
  asks for, and the dock's show/hide transitions. Socket shows never take focus.
- `action drop paths=`: files dropped on Scratch's MacHUD dock button become a pad each, as a
  drop on the panel does: a link to the file plus its contents when it is UTF-8 text under
  1 MB. Replies `{count, pads}`.
- Settings schema for MacHUD's settings window; `autosaveDelay` is a `number` with `min` 0.1,
  `max` 10 and `step` 0.05, enforced by the router. Saved settings are merged over the defaults
  key by key, so a value that fails to decode takes its default alone.
- Menu bar consolidation (HUDKit): while MacHUD runs, Scratch's menu appears in MacHUD's status
  menu (served by the `menu` and `menu-invoke` verbs) and its own menu bar icon hides; the icon
  returns when MacHUD quits or when MacHUD's `menuBar.consumeSiblings` is off. Opt out with
  `settings set menuBar.consumed=false`, kept in `<home>/menubar.json`. `hello` reports
  `statusItem`.
- App icon and menu bar icon from the MacHUD family set (`AppIcon.icns`,
  `MenuBarIcon.png`/`@2x`), shown through `HUDStatusIcon` with an SF Symbol fallback.
- `scratch` CLI (Contents/Helpers/scratch): shorthands, stdin for `append`/`new`, `body`,
  `watch`.
- `SCRATCH_HOME` / `SCRATCH_SOCKET` / `SCRATCH_NO_HOTKEYS` isolation (an isolated instance
  keeps its preferences, menu bar opt-out and panel frames apart) and `--snapshot <png>`.
- Repo layout, build and CI per the MacHUD conventions: bundle files in
  `Sources/Scratch/Resources`, `build.sh`/`install.sh` as shims into HUDKit's `hud-build.sh` /
  `hud-install.sh` (version from `VERSION`, build number from the commit count), `swift test`
  on macos-26 in CI.

# RunPwsh — Nextpad++ macOS Plugin

**Version:** 3.1.5 — see [CHANGELOG.md](CHANGELOG.md) for the version history.

A PowerShell-ISE-like panel for Nextpad++ (macOS): run the current script or
just the current selection against a **single persistent `pwsh` session**
(variables and functions survive across runs, exactly like the real ISE) in
a **real embedded terminal** — type directly into it, arrow-key history and
tab-completion work, masked credential prompts stay hidden, exactly like a
real terminal window — interrupt a running command without losing the
session, start a brand-new session when you actually want a clean slate,
jump to an interactive `pwsh` session in Terminal.app, and — if PowerShell
isn't installed yet — install it with one click via Homebrew. Built on the
same native Nextpad++ plugin
API for macOS (`NppPluginInterfaceMac.h`, see `vendor/README.md`) as the
[Finder plugin](../finder/README.md) in this repo, and follows several of
its established conventions directly (panel docking, SF-Symbol panel
buttons, German/English localization).

## Dependencies

The plugin itself (Cocoa/AppKit, Foundation) has no third-party
dependencies. Since v2.0.0 it also embeds a small Swift bridge
(`swift/RunPwshTerminalBridge/`, its own SwiftPM package) around
[SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) for the terminal
widget itself — see "Building" below for what that means for the build.
Beyond that, it shells out to `pwsh`, `/usr/bin/open`, and (only when the
user explicitly clicks "Install via Homebrew") `brew` — none of these are
build-time dependencies, just runtime executables the plugin looks for and,
in the `pwsh` case, offers to install.

## Important: can only be built on macOS

This plugin is Objective-C++ (`.mm`) and links against `Cocoa`/`Foundation`.
It **cannot** be compiled in a Linux sandbox — that requires a Mac with the
Command Line Tools (or Xcode) installed. Everything here was written by
hand against the header conventions and existing patterns of the host repo
and the Finder plugin (see "Known limitations" in CHANGELOG.md), but an
actual compile run and manual test pass are still required on your end.

## Structure

```
RunPwsh/
├── CMakeLists.txt              Build configuration (produces RunPwsh.dylib;
│                                also shells out to `swift build` for
│                                swift/RunPwshTerminalBridge/ and links it in)
├── resources/
│   ├── toolbar.png              Main toolbar/menu-band icon (light mode)
│   └── toolbar_dark.png         Main toolbar/menu-band icon (dark mode)
├── vendor/
│   ├── NppPluginInterfaceMac.h  Unmodified copy of the plugin ABI from the host repo
│   └── README.md                Provenance/sync note for the vendored file
├── swift/
│   └── RunPwshTerminalBridge/   SwiftPM package: @objc wrapper around
│                                SwiftTerm's LocalProcessTerminalView (the
│                                actual terminal widget embedded in the panel)
└── src/
    ├── RunPwshPlugin.mm         Mandatory exports (setInfo/getName/getFuncsArray/
    │                            beNotified/messageProc), panel registration,
    │                            menu commands, auto-save-before-run, selection
    │                            text retrieval via Scintilla SCI_GETSELTEXT,
    │                            lazy persistent-session startup
    ├── RunPwshPanelView.h/.mm   Toolbar (Run Script / Run Selection / Stop /
    │                            New Session / Open in Terminal),
    │                            install-via-Homebrew banner, embedded
    │                            terminal (RunPwshTerminalBridge)
    ├── RunPwshEngine.h/.mm      pwsh/brew discovery, Terminal.app launch,
    │                            Homebrew install (non-interactive NSTask)
    └── RunPwshLocalization.h/.mm  DE/EN localization (same pattern as the
                                    Finder plugin's FinderLocalization)
```

## Building (on a Mac)

Prerequisite: Nextpad++ has already been built from
`nextpad-plus-plus-macos` (or installed) — this plugin builds
independently of that, but has to be loaded by a running Nextpad++ instance
at runtime.

Also requires the **Swift toolchain** (ships with Xcode / the Command Line
Tools — `swift build` must be on PATH) and, the *first* time only, **network
access**: `cmake --build` shells out to `swift build` for the
`swift/RunPwshTerminalBridge/` SwiftPM package, which fetches
[SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) as a dependency.

```sh
cd /Volumes/S-Drive/Privat/Repository/Nextpad-plusplus/plugins/Plugins/RunPwsh
cmake -S . -B build
cmake --build build
cmake --build build --target install_plugin
```

Result: `build/RunPwsh.dylib` (universal binary, arm64 + x86_64) plus
`swift/RunPwshTerminalBridge/.build/universal/libRunPwshTerminalBridge.dylib`
(itself built as arm64+x86_64 and combined with `lipo` — see "Note on the
Swift bridge's build" below), copied by `install_plugin` to
`~/Library/Application Support/Nextpad++/plugins/RunPwsh/` (both files,
alongside `resources/`) — RunPwsh.dylib finds the Swift bridge dylib next to
itself via an `@loader_path` rpath. Restart Nextpad++ to load it.

**Note on the Swift bridge's build (v3.1.1)**: `swift build` with no `--arch`
flag only ever builds for the host's own architecture (arm64 on Apple
Silicon) — a real first build (2026-08-28) showed this as a linker warning
(`ld: warning: ignoring file '...libRunPwshTerminalBridge.dylib': found
architecture 'arm64', required architecture 'x86_64'`) rather than a hard
failure, because `-undefined,dynamic_lookup` defers symbol resolution at
link time. The build "succeeded" but would have produced an x86_64 slice of
`RunPwsh.dylib` that could never actually load its Swift bridge on an Intel
Mac. Fixed by building the Swift package for each architecture explicitly
(`swift build --arch arm64` / `--arch x86_64`, each landing in SwiftPM's own
`.build/<arch>-apple-macosx/release/`) and combining the two with `lipo`
into a genuinely universal dylib, matching what `CMAKE_OSX_ARCHITECTURES`
already does for `RunPwsh.dylib` itself.

**Note on the Swift bridge's API calls**: `RunPwshTerminalBridge.swift` was
originally written from memory of SwiftTerm's public API. The first real
`swift build` (2026-08-26) caught one mismatch — `stopProcess()` tried to
read `LocalProcessTerminalView.process` directly, but that property is
`internal`, not `public`, in SwiftTerm 1.2.0 — fixed in v2.0.1 via Swift
reflection (`Mirror`) to reach the pid, with a Ctrl+C-via-pty fallback if
that ever breaks in a future SwiftTerm version. Everything else (`startProcess`,
`feed(text:)`, the delegate protocol methods) has since been confirmed
against the real vendored source and needed no changes. Since v3.0.0 the
`@objc` surface RunPwshPanelView.mm relies on is
start/feed/typeText/interrupt/killSession/onProcessExited (`stopProcess()`
was renamed to `killSession()`; `typeText(_:)`/`interrupt()` were added for
the persistent-session model — see "Using it" below) and stays stable
regardless of any future SwiftTerm-facing internal adjustments.

## Using it

Since v3.0.0, the embedded terminal hosts one **persistent** interactive
`pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass` session, started lazily on
the first "Run Script"/"Run Selection" click rather than a fresh throwaway
process per run. `$variables` and functions defined by one run are still
there for the next — the whole point being that building `$cred` in one
selection and reusing it in the next (e.g. for `Enter-PSSession
-Credential $cred`) no longer requires retyping it.

- **Script ausführen / Run Script** (green play button): saves the current
  file (matching the PowerShell ISE's F5 behavior — if the buffer is
  untitled, the host's Save dialog appears first), starts the session if one
  isn't already running, then dot-sources the file (`. '<path>'`, after a
  `Set-Location` into its folder) into that session — dot-sourcing, not the
  call operator, so top-level variables/functions the script defines leak
  into the session instead of vanishing with a child scope.
- **Auswahl ausführen / Run Selection** (green rectangle button, matching
  Run Script since v3.1.0): starts the session if needed, then types the
  selected text directly into it — same effect as pasting it by hand at the
  prompt, no temp `.ps1` file involved anymore. If nothing is selected, it
  runs the line the cursor is currently on instead (v3.1.0, matching the real
  PowerShell ISE's F8 behavior) — only if the caret isn't on any line and
  there's truly nothing to run does it print "Keine Auswahl und keine
  aktuelle Zeile vorhanden." / "No selection and no current line." If this
  is the very first Run against a brand-new session, there's a short (~0.6s)
  pause before it's actually typed in, so it doesn't race `pwsh`'s own
  startup (v3.1.2), plus a follow-up safety-net Enter press ~1.5s later for
  that first command only, in case the session was still slower to start
  than that (v3.1.4). What's typed always ends with a real Enter keypress
  (`\r`, not `\n` — v3.1.3, see the changelog if a command ever just sits
  there un-executed again).
- **Aktuellen Befehl abbrechen / Stop** (gray/red square): sends Ctrl+C to
  interrupt whatever's currently running in the session — the session itself
  (and everything defined in it so far) stays alive.
- **Neue Sitzung starten / New Session** (circular-arrow icon): the
  destructive action — ends the current `pwsh` process outright (SIGTERM,
  escalating to SIGKILL after a short grace period) for a genuinely clean
  slate. A later Run Script/Run Selection click lazily starts a fresh session.
- **Pwsh in Terminal starten / Start Pwsh in Terminal** (terminal icon):
  opens a new Terminal.app window with an interactive `pwsh` session, `cd`'d
  into the current file's folder.
- All of the above are also reachable from the editor's native right-click
  context menu, under **"Plugin-Befehle" / "Plugin Commands" → RunPwsh**
  (the host lists every plugin's commands there automatically) — select
  text first, then choose "Auswahl ausführen" / "Run Selection" there for
  the same effect as the toolbar button.
- If no `pwsh` binary can be found, a banner appears above the console with
  an **"Installieren via Homebrew" / "Install via Homebrew"** button (runs
  `brew install --cask powershell`). If Homebrew itself isn't installed
  either, the banner instead points to <https://brew.sh>.
- **The console is a real, typeable terminal** (since v2.0.0): click into it
  and type directly, same as any terminal app — arrow-key history,
  tab-completion, and masked/secure prompts (`Get-Credential`,
  `Enter-PSSession`'s credential fallback, `Read-Host -AsSecureString`,
  `Connect-AzAccount`'s tenant/subscription picker) all work exactly like in
  Terminal.app, because they're now backed by a real terminal widget
  (SwiftTerm) instead of a read-only text view. There is no separate input
  field anymore.
- The console always uses a **fixed dark background with light text**
  (regardless of the host's light/dark appearance setting), matching the
  PowerShell ISE and most terminal apps.

## Known limitations

See [CHANGELOG.md](CHANGELOG.md) — most notably: the panel currently docks
via the same side-panel API as the Finder plugin; bottom-docking (like the
real ISE) is planned for host release 1.1.1 (confirmed by the Nextpad++
maintainer, 2026-08-24) — a small follow-up change is planned once that's
out. (The previous "no persistent session across runs" limitation was
addressed in v3.0.0 — see above.)

## License

MIT — see [LICENSE](LICENSE).

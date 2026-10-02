# RunPwsh — Nextpad++ macOS Plugin

**Version:** 4.0.0 — see [CHANGELOG.md](CHANGELOG.md) for the version history.

A PowerShell-ISE-like panel for Nextpad++ (macOS): run the current script or
just the current selection against a **single persistent `pwsh` session**
(variables and functions survive across runs, exactly like the real ISE) in
a **real embedded terminal** — type directly into it, arrow-key history and
tab-completion work, masked credential prompts stay hidden, exactly like a
real terminal window — interrupt a running command without losing the
session, restart it when you actually want a clean slate, and — if PowerShell
isn't installed yet — install it with one click via Homebrew. The behavior
follows the PowerShell terminal of Visual Studio Code's PowerShell extension. Built on the
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
    │                            Restart Session),
    │                            install-via-Homebrew banner, embedded
    │                            terminal (RunPwshTerminalBridge)
    ├── RunPwshSession.h/.mm     Session state machine (Idle → Starting → Ready
    │                            ⇄ Running → Ended); "ready" = pwsh printed a prompt
    ├── RunPwshEngine.h/.mm      pwsh/brew discovery,
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

The embedded terminal hosts one **persistent** interactive
`pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass` session. Since v4.0.0 it
**starts as soon as the panel is shown**, so the banner and the
`PS <path>>` prompt are there and you can type right away. `$variables` and
functions defined by one run are still there for the next.

How "ready" is detected: the session starts `pwsh` with a `prompt` override
that emits an OSC 7 sequence before every prompt. The terminal reports it to
the plugin, which then knows `pwsh` is at a prompt. Runs requested earlier
(while `pwsh` is still starting, or while another command is running) wait in
a single queue slot and are sent at the next prompt; there are no timers.

- **Run Script** (green play button): saves the current file (if the buffer
  is untitled, the host's Save dialog appears first), then dot-sources it
  (`. '<path>'`, after a `Set-Location` into its folder) so top-level
  variables/functions stay in the session.
- **Run Selection** (green rectangle button): types the selected text into
  the session. With no selection it runs the current line (like F8 in VS
  Code). Multi-line text is typed with a real Enter (`\r`) after each line.
- **Stop** (gray/red square): Ctrl+C — interrupts the running command and
  drops anything still queued. The session stays alive.
- **Restart Session** (circular arrow): ends the `pwsh` process (SIGTERM,
  then SIGKILL after a short grace period) and starts a fresh one.
- If `pwsh` exits (`exit`, crash), the terminal prints "Session ended" and
  **Restart Session** starts a new one.
- All commands are also in the editor's right-click menu under
  **Plugin Commands → RunPwsh**.
- **Keyboard shortcuts:** the host ignores shortcuts proposed by plugins.
  Assign F5 / F8 (or any key) yourself under **Edit → Shortcut Mapper… →
  Plugins**.
- If no `pwsh` binary can be found, a banner appears with an **Install via
  Homebrew** button (runs `brew install --cask powershell`). If Homebrew is
  missing too, the banner points to <https://brew.sh>.
- **The console is a real, typeable terminal:** click into it and type
  directly — arrow-key history, tab completion and masked prompts
  (`Get-Credential`, `Read-Host -AsSecureString`, …) work as in any terminal,
  because the widget is SwiftTerm. The console always uses a fixed dark
  background with light text.

## Running the unit tests

The session state machine has plain assert-style tests (no XCTest, no host
needed):

```sh
cmake -S . -B build
cmake --build build --target run_session_tests
```

Everything else (terminal, docking, focus, keyboard input) is verified by hand
in the running Nextpad++: open the panel, type, run a line and a selection,
Stop, Restart Session, hide and show the panel, and dock it at the side and at
the bottom.

## Known limitations

See [CHANGELOG.md](CHANGELOG.md). Notably: only one terminal session (no
terminal list like VS Code), and the panel is docked wherever the host puts it
(side or bottom, via the panel's own dock buttons).

## License

MIT — see [LICENSE](LICENSE).

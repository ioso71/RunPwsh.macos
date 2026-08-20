# RunPwsh — Nextpad++ macOS Plugin

**Version:** 1.1.0 — see [CHANGELOG.md](CHANGELOG.md) for the version history.

A PowerShell-ISE-like panel for Nextpad++ (macOS): run the current script or
just the current selection through `pwsh` (PowerShell 7+), watch the output
live, stop a run in progress, jump to an interactive `pwsh` session in
Terminal, and — if PowerShell isn't installed yet — install it with one
click via Homebrew. Built on the same native Nextpad++ plugin API for macOS
(`NppPluginInterfaceMac.h`, see `vendor/README.md`) as the
[Finder plugin](../finder/README.md) in this repo, and follows several of
its established conventions directly (panel docking, SF-Symbol panel
buttons, German/English localization).

## No external dependencies

This plugin uses only Apple system frameworks (**Cocoa/AppKit, Foundation**)
plus CMake as the build system. It shells out to `pwsh`, `/usr/bin/open`,
and (only when the user explicitly clicks "Install via Homebrew") `brew` —
none of these are build-time dependencies, just runtime executables the
plugin looks for and, in the `pwsh` case, offers to install.

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
├── CMakeLists.txt              Build configuration (produces RunPwsh.dylib)
├── resources/
│   ├── toolbar.png              Main toolbar/menu-band icon (light mode)
│   └── toolbar_dark.png         Main toolbar/menu-band icon (dark mode)
├── vendor/
│   ├── NppPluginInterfaceMac.h  Unmodified copy of the plugin ABI from the host repo
│   └── README.md                Provenance/sync note for the vendored file
└── src/
    ├── RunPwshPlugin.mm         Mandatory exports (setInfo/getName/getFuncsArray/
    │                            beNotified/messageProc), panel registration,
    │                            menu commands, auto-save-before-run, selection
    │                            text retrieval via Scintilla SCI_GETSELTEXT
    ├── RunPwshPanelView.h/.mm   Toolbar (Run Script / Run Selection / Stop /
    │                            Open in Terminal), install-via-Homebrew banner,
    │                            read-only monospaced output console
    ├── RunPwshEngine.h/.mm      pwsh/brew discovery, NSTask execution with
    │                            live output streaming, stop, Terminal launch,
    │                            Homebrew install
    └── RunPwshLocalization.h/.mm  DE/EN localization (same pattern as the
                                    Finder plugin's FinderLocalization)
```

## Building (on a Mac)

Prerequisite: Nextpad++ has already been built from
`nextpad-plus-plus-macos` (or installed) — this plugin builds
independently of that, but has to be loaded by a running Nextpad++ instance
at runtime.

```sh
cd /Volumes/S-Drive/Privat/Repository/Nextpad-plusplus/plugins/Plugins/RunPwsh
cmake -S . -B build
cmake --build build
cmake --build build --target install_plugin
```

Result: `build/RunPwsh.dylib` (universal binary, arm64 + x86_64), copied by
`install_plugin` to
`~/Library/Application Support/Nextpad++/plugins/RunPwsh/RunPwsh.dylib`
alongside its `resources/`. Restart Nextpad++ to load it.

## Using it

- **Script ausführen / Run Script** (green play button): saves the current
  file (matching the PowerShell ISE's F5 behavior — if the buffer is
  untitled, the host's Save dialog appears first) and runs it with
  `pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File <path>`, streaming
  combined stdout/stderr into the console below.
- **Auswahl ausführen / Run Selection**: runs just the selected text (written
  to a private temp `.ps1` first, so error messages keep real line numbers).
- **Vorgang beenden / Stop** (gray/red square): terminates the running
  `pwsh` process.
- **Pwsh in Terminal starten / Start Pwsh in Terminal** (terminal icon):
  opens a new Terminal.app window with an interactive `pwsh` session, `cd`'d
  into the current file's folder.
- If no `pwsh` binary can be found, a banner appears above the console with
  an **"Installieren via Homebrew" / "Install via Homebrew"** button (runs
  `brew install --cask powershell`). If Homebrew itself isn't installed
  either, the banner instead points to <https://brew.sh>.
- **Input field** below the console: while a script/selection is running,
  type a line and press Enter to send it to `pwsh`'s stdin — e.g. to answer
  `Connect-AzAccount`'s tenant/subscription picker, a `Read-Host` prompt, or
  a `[Y/n]` confirmation. Disabled while nothing is running.
- The console always uses a **fixed dark background with light text**
  (regardless of the host's light/dark appearance setting), matching the
  PowerShell ISE and most terminal apps.

## Known limitations

See [CHANGELOG.md](CHANGELOG.md) — most notably: the panel currently docks
via the same side-panel API as the Finder plugin (not confirmed to support
docking *below* the editor like the real ISE), and each run starts a fresh
`pwsh` process (no persistent session/shared variables across runs).

## License

MIT — see [LICENSE](LICENSE).

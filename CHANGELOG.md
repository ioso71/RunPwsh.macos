# Changelog

All notable changes to the RunPwsh plugin are documented here.

Version scheme: `XX.Y.ZZ` (Major.Minor.Patch)
- **ZZ** (Patch): Bugfixes / small changes
- **Y** (Minor): medium updates / new features
- **XX** (Major): large breaking changes

## [1.1.0] — 2026-08-10

### Added
- **Interactive stdin input**: a text field below the output console —
  enabled only while a script/selection is running — lets the user type a
  line and press Enter to send it to the running `pwsh` process's stdin.
  Needed because scripts that call e.g. `Connect-AzAccount` can raise an
  interactive tenant/subscription picker (or a plain `Read-Host` / `[Y/n]`
  confirm) mid-run; without a way to answer it the run just hangs forever
  with no visible way to respond. Implemented by giving each `NSTask` its
  own stdin `NSPipe` (`RunPwshEngine`'s `-launchTaskAtPath:...`) and adding
  `-sendInputLine:` to write a line (newline-terminated) to its write end;
  the panel echoes what was typed into the console itself since stdin here
  isn't a tty, so `pwsh` won't echo it back on its own. The pipe's write
  handle is closed and cleared in the task's `terminationHandler` /
  launch-failure path so a stale handle can't be written to after exit.
- **Fixed dark console theme**: the output console now always uses a dark
  background with light text (`RunPwshConsoleBackgroundColor()` /
  `RunPwshConsoleTextColor()` in `RunPwshPanelView.mm`), regardless of the
  host's light/dark appearance setting. Previously it used
  `NSColor.textColor`/`textBackgroundColor`, which tracked system
  appearance — reported as hard to read; the PowerShell ISE and most
  terminal apps default to a dark console independent of system theme, so
  this plugin now does the same.

### Known limitations
- The stdin field answers prompts one line at a time; it does not give
  visibility into *whether* a prompt is currently waiting (no separate
  "waiting for input" indicator) — the user has to recognize a prompt from
  the console text itself, same as reading a real terminal.

## [1.0.1] — 2026-08-10

### Fixed
- Build failed with `error: dereferencing a __weak pointer is not allowed
  due to possible null value caused by race condition` at three
  `output:^(NSString *text) { [weakSelf->_panelView ...] }` call sites in
  `RunPwshPlugin.mm` (`runScriptAction`, `runSelectionAction`,
  `installPwshAction`). Cause: dereferencing a `__weak` ivar access
  (`weakSelf->_panelView`) directly inside a block isn't just unsafe under
  ARC, AppleClang now hard-errors on it — the pointer can turn nil between
  the implicit load and the use. Fixed by assigning `weakSelf` to a strong
  local (`RunPwshPluginController *strongSelf = weakSelf; if (!strongSelf)
  return;`) at the top of each `output:` block first, matching the pattern
  already used in the corresponding `completion:` blocks.

## [1.0.0] — 2026-08-10

First working version.

### Added
- Vendored header `NppPluginInterfaceMac.h` for the macOS plugin ABI (same
  copy/SHA-256 as the Finder plugin's vendor/ — no host-side change since).
- CMake build (`CMakeLists.txt`) including an `install_plugin` target,
  mirroring the Finder plugin's layout.
- `RunPwshEngine`: finds a `pwsh` binary (well-known Homebrew/Microsoft-
  installer paths, then a login-shell `command -v pwsh` fallback for custom
  PATH setups), likewise for `brew`; runs a script file or an ad-hoc
  selection (via a private temp `.ps1`) as an `NSTask` with live combined
  stdout/stderr streaming; stops a running task; opens an interactive `pwsh`
  session in Terminal.app via a throwaway `.command` file (no AppleScript,
  matching the Finder plugin's "Open in Terminal" approach); installs
  PowerShell with `brew install --cask powershell`.
- `RunPwshPanelView`: a docked panel (registered via the same
  `NPPM_DMM_REGISTERPANEL` API as the Finder plugin's sidebar) with a
  4-button toolbar (Run Script / Run Selection / Stop / Open Pwsh in
  Terminal, SF Symbols per the Finder plugin's own panel-icon convention —
  see its CHANGELOG 1.3.0/1.3.1 for why custom PNGs were tried and reverted
  for panel-internal buttons), a status line showing the resolved `pwsh`
  path, an install-via-Homebrew banner when `pwsh` is missing, and a
  read-only monospaced output console.
- `RunPwshPlugin.mm`: 5 mandatory ABI exports, panel lifecycle, menu
  commands (Toggle Panel / Run Script / Run Selection / Stop / Start Pwsh in
  Terminal), German/English localization (`RunPwshLocalization`, same
  pattern as the Finder plugin's `FinderLocalization` — reads the host's own
  `"language"` NSUserDefaults key + `"NPPLocalizationChanged"` notification;
  see project memory "Plugin localization pattern").
- "Run Script" auto-saves the current file first (`NPPM_SAVECURRENTFILE`),
  matching the PowerShell ISE's F5 behavior, so the executed `.ps1` always
  reflects the editor's current contents.
- Main toolbar/menu-band icon (`resources/toolbar.png` / `toolbar_dark.png`,
  a terminal-prompt glyph) registered via `NPPM_ADDTOOLBARICON_FORDARKMODE`
  for the "Toggle RunPwsh Panel" command — the only plugin-wide icon; the
  4 panel-internal buttons use SF Symbols instead (see above).

### Known limitations
- **Panel placement**: the plugin ABI's docking API
  (`NPPM_DMM_REGISTERPANEL`) only documents registering into the shared
  side-panel host (same one used by Document List / Function List / the
  Finder plugin's own sidebar) — there is no confirmed way to dock a panel
  *below* the editor the way the PowerShell ISE's console pane sits. This
  plugin uses the side-panel API as-is; if it turns out the host's
  SidePanelHost can't be bottom-docked, revisit with a custom floating
  `NSPanel` manually positioned under the editor instead (more code, more
  fragile, but visually closer to the ISE — see the design discussion this
  version shipped with).
- **No persistent session for "Run Selection"**: unlike the real ISE, each
  "Run Script" or "Run Selection" starts a brand-new `pwsh` process, so
  variables/functions defined by one run aren't visible to the next one.
  A persistent background `pwsh` session (feeding commands over stdin)
  would fix this but is a materially bigger change.
- Same shortcut-key limitation as every other plugin in this repo:
  `FuncItem._pShKey` is ignored by the host (see project memory) — use the
  Shortcut Mapper UI to assign keys to RunPwsh's menu commands instead.
- Toolbar icon tooltip (like the Finder plugin's) won't refresh live on a
  runtime language change — same confirmed host-side caching behavior at
  `NPPM_ADDTOOLBARICON_FORDARKMODE`, not fixable plugin-side.

# Changelog

All notable changes to the RunPwsh plugin are documented here.

Version scheme: `XX.Y.ZZ` (Major.Minor.Patch)
- **ZZ** (Patch): Bugfixes / small changes
- **Y** (Minor): medium updates / new features
- **XX** (Major): large breaking changes

## [4.0.0] — 2026-10-02

Session rewrite, modelled on the PowerShell terminal of VS Code's PowerShell
extension.

### Added
- `pwsh` now **starts as soon as the panel is shown**: the banner and the
  `PS <path>>` prompt appear without clicking Run, and the terminal takes
  keyboard focus.
- `RunPwshSession` (`src/RunPwshSession.*`): an explicit session state machine
  (`Idle → Starting → Ready ⇄ Running → Ended`) with unit tests
  (`cmake --build build --target run_session_tests`).
- The session starts `pwsh` with a `prompt` override that emits OSC 7 before
  every prompt; the Swift bridge forwards it as `onPrompt`. "Ready" now means
  "pwsh printed a prompt".
- A Run requested while `pwsh` is still starting, or while another command is
  running, is queued in one slot (a newer request replaces an older one) and
  sent at the next prompt.
- Clicking the terminal gives it keyboard focus (`focus()` in the bridge).

### Fixed
- Keyboard input (Backspace, Enter, …) did nothing in the terminal: SwiftTerm
  1.2.0 never made its view first responder on click.
- The first Run against a fresh session typed its text twice (before and after
  the prompt) and could stay un-submitted. Caused by the 0.6 s / 1.5 s
  timers of 3.1.2 – 3.1.4, which are gone.
- The Swift bridge's Obj-C header was no longer regenerated with Swift 6.4's
  default build system, hiding new `@objc` members from the `.mm` files. The
  CMake target now builds the bridge with `--build-system native`.

- `pwsh` could not find external programs (`ping`, `git`, …): SwiftTerm 1.2.0
  leaves `PATH` out of the child environment. The bridge now passes the
  host's environment on top of SwiftTerm's defaults.
- PSReadLine's inline prediction (the grey suggestion after what you typed)
  looked like real text that Backspace could not delete: SwiftTerm's macOS
  view does not draw the "dim" attribute PSReadLine uses by default. The
  session now sets an explicit grey (`InlinePrediction` = `ESC[38;5;244m`).
- Restart Session now works: the new process is started on the next run-loop
  turn, because SwiftTerm only clears its `running` flag after the exit
  callback returns (starting from inside it was silently ignored). A Run
  requested between Restart and the old process's exit is kept for the new
  session instead of being typed into the dying one.
- Restart Session on an ended session starts exactly one process.
- Stop stays available while a Run is waiting for a prompt, so a stalled
  queue always has a way out.
- Tabs in a Run Selection are sent as spaces so PSReadLine does not treat
  them as tab completion.
- The terminal no longer takes keyboard focus from the editor at app launch
  or whenever a command finishes; it gets focus when the panel is shown or
  clicked.

### Removed (breaking)
- **"Start Pwsh in Terminal"** (menu command and toolbar button). The menu now
  has 5 commands instead of 6; command IDs after "Stop" shifted, so custom
  shortcuts assigned to the later commands may need to be set again under
  Edit → Shortcut Mapper… → Plugins. A shortcut that was on the old 5th
  entry ("Start Pwsh in Terminal") now triggers **Restart Session**, which
  discards the session's variables.
- The startup grace period, the extra follow-up Enter and
  `ensureSessionStarted…completion:`.

### Changed
- "New Session" is now **Restart Session**: it ends the process and starts a
  new one in one step.
- After `exit` or a crash the terminal shows "Session ended" and Restart
  Session starts a new session.

## [3.1.5] — 2026-08-31

### Fixed
- On macOS keyboard layouts that compose characters with Option (including
  German `Option+N`, then Space, for `~`), the embedded terminal now uses
  native text input instead of treating Option as a terminal Meta key. This
  makes `~` type correctly and prevents that key sequence from leaking into
  Nextpad++ shortcuts.
- A newly started persistent `pwsh` session now always begins in the current
  user's home directory (`~` / `/Users/<user>`). Running a saved script still
  changes to that script's directory explicitly before dot-sourcing it.

## [3.1.4] — 2026-08-28

### Fixed
- **The very first "Run" against a freshly-started session still didn't
  execute**, even after the v3.1.3 `\r`-vs-`\n` fix — confirmed by the user:
  every Run *after* the first one worked correctly, but the very first
  command against a brand-new session was still just typed in without
  running. The v3.1.2 grace period (a flat 0.6s delay before the first
  `-runText:` call) reduced how often this race was lost, but couldn't
  reliably win it every time — real `pwsh` startup time varies with disk
  cache state and machine speed, and evidently sometimes exceeds 0.6s. Added
  a belt-and-suspenders fix: `-runText:` now also arms a single follow-up
  bare `"\r"` keystroke ~1.5s after the *first* command sent to a
  freshly-started session (tracked via a new internal
  `_needsStartupSafetyNet` flag, cleared after arming so only that first
  command gets it). If the initial send actually landed fine, this extra
  `"\r"` is a harmless no-op Enter press on an empty prompt line; if it
  didn't, this submits whatever's still sitting, typed-but-unexecuted, in
  PSReadLine's now-attached raw-mode input buffer — i.e. the original
  command.

## [3.1.3] — 2026-08-28

### Fixed
- **The actual root cause of "Auswahl ausführen"/Run Selection typing the
  command in but never executing it.** The v3.1.2 fix above (session-start
  grace period) turned out to only paper over part of the symptom — a
  follow-up user report (with screenshot) showed the same command typed
  correctly at a fully-ready, real `PS ...>` prompt, just sitting there with
  the cursor after it: no output, no new prompt line, no error. `-runText:`
  was appending `"\n"` (LF, 0x0A) as the line terminator if `text` didn't
  already end in one. That works fine in a shell's canonical/cooked tty
  mode, but once PSReadLine attaches and switches the pty to *raw* mode
  (which it does almost immediately after starting), only `"\r"` (CR,
  0x0D) — what a real Enter keypress actually sends over a pty — is bound
  to "submit the current line"; a bare `"\n"` is just inserted as a literal
  character and never triggers execution. Fixed `-runText:` to normalize
  *every* line ending in the typed text (not just the trailing one — matters
  for multi-line selections too, where each embedded newline needs to behave
  like its own Enter press) to `"\r"` before sending it to the pty.

## [3.1.2] — 2026-08-28

### Fixed
- **"Auswahl ausführen"/Run Selection against a freshly-started session typed
  the command but never actually executed it.** User report (verbatim,
  translated, with screenshot): selecting a line and clicking "Auswahl
  ausführen" showed the command typed into the terminal once (before any
  prompt was visible — "die [PowerShell] ist vorher anscheinend nicht
  aktiv"), then the real `PS ...>` prompt appeared, and then the *same*
  command appeared again sitting at that prompt — un-executed, no output, no
  error. Root cause: `-ensureSessionStartedWithExecutable:...` returned
  (and the caller immediately called `-runText:`) the instant the `pwsh`
  process was *spawned*, not once it was actually *ready to read input* —
  module loading and PSReadLine attaching to the pty (switching it from
  cooked to raw mode) takes a moment after that. Typing into the pty during
  that window gets echoed once by the kernel's own cooked-mode echo (visible
  before any prompt), and then effectively "lost" once PSReadLine takes over
  and starts fresh with its own raw-mode line buffer — matching exactly what
  was reported. Fixed by giving
  `-ensureSessionStartedWithExecutable:arguments:currentDirectory:` a
  `completion` block (called immediately if a session was already running,
  or after a short ~0.6s startup grace period if this call just spawned a
  new one) and moving every `-runText:` call (`Run Script`'s dot-source,
  `Run Selection`'s typed text) inside that block instead of right after
  `-ensureSessionReadyWithCwd:` returns.

## [3.1.1] — 2026-08-28

### Fixed
- `swift build` (invoked by `CMakeLists.txt` for the Swift terminal bridge)
  only ever built for the host machine's own architecture — no explicit
  `--arch` flag was passed. A real build showed this as a linker warning
  rather than a hard failure:
  ```
  ld: warning: ignoring file '.../libRunPwshTerminalBridge.dylib': found
  architecture 'arm64', required architecture 'x86_64'
  ```
  `-Wl,-undefined,dynamic_lookup` (needed for the plugin's other host-provided
  symbols) let the link "succeed" anyway, silently producing an x86_64 slice
  of `RunPwsh.dylib` inside the universal binary that could never load its
  own Swift bridge on an Intel Mac (or under Rosetta) — a real, if latent,
  correctness bug in the universal build, not a cosmetic warning. Fixed
  `CMakeLists.txt`'s `RunPwshTerminalBridge_swiftbuild` custom target to run
  `swift build -c release --arch arm64` and `--arch x86_64` explicitly
  (SwiftPM lands each in its own `.build/<arch>-apple-macosx/release/`
  directory), then combines the two `.dylib`s with `lipo -create` into a new
  `.build/universal/libRunPwshTerminalBridge.dylib`, which is what gets
  linked into and later installed alongside `RunPwsh.dylib` now.

## [3.1.0] — 2026-08-28

### Added
- **"Auswahl ausführen"/Run Selection now falls back to the current line
  when nothing is selected**, instead of printing "Keine Auswahl vorhanden."
  / "No selection." and doing nothing. User report (verbatim, with
  screenshot): clicking the cursor into a line of a `.ps1` script and
  pressing "Auswahl ausführen" produced "Keine Auswahl vorhanden." — matches
  the real PowerShell ISE's F8 behavior (run current line if nothing's
  selected), so `-runSelectionAction` in `RunPwshPlugin.mm` now tries
  `-currentSelectionText` first and falls back to a new `-currentLineText`
  helper before giving up. The "nothing to run" message only appears now if
  the line itself is also empty/whitespace-only.
  - First attempt at `-currentLineText` used Scintilla's `SCI_GETCURLINE` and
    still failed ("Keine Auswahl und keine aktuelle Zeile vorhanden." on a
    non-empty line, per the user's second screenshot). Root cause:
    `SCI_GETCURLINE`'s return value is documented to be *the caret's column
    position within the line*, not the number of characters copied/needed —
    a well-known Scintilla API gotcha unrelated to whether the line has
    text. Our `len <= 1` check was actually asking "is the caret within the
    first byte of this line", which is often true. Fixed by switching to
    `SCI_GETCURRENTPOS` + `SCI_LINEFROMPOSITION` + `SCI_LINELENGTH` +
    `SCI_GETLINE`, none of which have this quirk.
- Right-click → **"Plugin-Befehle" / "Plugin Commands" → RunPwsh** in the
  editor's native context menu already lists all of this plugin's commands
  (Run Script, Run Selection, Stop, New Session, Open in Terminal, Toggle
  Panel) automatically — this is the host's generic per-plugin `FuncItem`
  listing, the same one every other Nextpad++ plugin gets for free, not
  something RunPwsh has to register separately. Selecting text first and
  then choosing "Auswahl ausführen" there runs exactly that selection, same
  as clicking the toolbar button.

### Changed
- **"Auswahl ausführen"/Run Selection button is now green**, matching
  "Script ausführen"/Run Script, per user request (previously the default
  gray/black system tint on its `play.rectangle` icon).

## [3.0.0] — 2026-08-26

### Changed (breaking)
- **Persistent `pwsh` session instead of a fresh process per run.** User
  report (verbatim): after building `$passwd`/`$cred` in one "Run Selection"
  and then running `Enter-PSSession -ComputerName ... -Credential $cred` in a
  second one, both variables were gone — because each "Run" spawned and then
  discarded its own throwaway `pwsh -File`/`pwsh` process, exactly as
  documented under "Known limitations" since v2.0.0. Asked the user how to
  fix it (AskUserQuestion): confirmed **"Ja, dauerhafte Sitzung (empfohlen)"**
  (persistent session) and **"Nur aktuellen Befehl abbrechen (Strg+C)"**
  (Stop should only interrupt, not kill the session). Implemented exactly
  that:
  - The embedded terminal now starts **one** long-lived interactive
    `pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass` session, lazily, on the
    first "Run Script"/"Run Selection" click (`RunPwshPanelView.
    -ensureSessionStartedWithExecutable:arguments:currentDirectory:`).
  - **Run Script** now dot-sources the saved file into that session
    (`Set-Location -LiteralPath '<cwd>'; . '<path>'`) instead of running it
    as a standalone `-File` process — dot-sourcing (not `&`) so top-level
    variables/functions leak into the session's scope instead of a
    disposable child scope.
  - **Run Selection** now types the raw selected text directly into the
    session (`RunPwshPanelView.-runText:` → `RunPwshTerminalBridge.
    typeText(_:)`, which writes straight to the pty via SwiftTerm's
    `send(source:data:)`) — the temp-`.ps1`-file mechanism from v1.x/2.x is
    gone entirely.
  - **Stop** (`RunPwshPanelView.-interruptSession`) now only sends Ctrl+C
    (0x03) through the pty — the session and everything defined in it
    survive, matching the user's explicit choice.
  - New, separate, destructive **"New Session"** toolbar button/menu command
    (orange circular-arrow icon) — `RunPwshPanelView.-killSession` →
    `RunPwshTerminalBridge.killSession()` — actually ends the `pwsh` process
    (SIGTERM → SIGKILL) for when a genuinely clean slate is wanted. Also
    called on plugin shutdown (`handleBeforeShutdown`), replacing the old
    `stopProcess`/`isRunning` calls there.
- `RunPwshPanelView`: `.isRunning` → `.hasSession`; `-startProcessWithExecutable:
  arguments:currentDirectory:` → `-ensureSessionStartedWithExecutable:
  arguments:currentDirectory:` (now idempotent/no-op if a session is already
  running); `-setRunningState:` → `-setSessionActive:` (now only toggles the
  Stop button — Run Script/Run Selection/New Session stay enabled regardless,
  since clicking them just starts a session first if needed); added
  `-runText:`, `-interruptSession`, `-killSession`; removed `-stopProcess`.
  New required delegate method `-runPwshPanelViewDidRequestNewSession:`.
- `RunPwshTerminalBridge.swift`: added `typeText(_:)` (writes arbitrary text
  to the pty as if the user had typed it — the mechanism behind both Run
  actions now) and `interrupt()` (Ctrl+C only); renamed `stopProcess()` →
  `killSession()` (unchanged SIGTERM/SIGKILL/Mirror-reflection internals from
  v2.0.1).
- `RunPwshPlugin.mm`: removed all temp-`.ps1`-file bookkeeping for Run
  Selection (`_pendingSelectionTempPath` and its cleanup in
  `-runPwshPanelViewProcessDidExit:exitCode:`, now a no-op); `-stopAction` →
  interrupt-only; new `-newSessionAction`; new menu command "Neue Sitzung
  starten" / "Start New Session" (`Cmd_NewSession`, 6th `FuncItem`).
- The "[Beendet mit Exit-Code N]" / "[Finished with exit code N]" banner is
  now "[Sitzung beendet, Exit-Code N]" / "[Session ended, exit code N]",
  since it only fires when the whole persistent session ends (user typed
  `exit`, it crashed, or New Session was clicked) — not after every
  individual run anymore.

### Known limitations (unchanged)
- Panel still docks left/right only (bottom-docking planned for host 1.1.1).

## [2.0.1] — 2026-08-26

### Fixed
- `cmake --build build` failed compiling the new Swift bridge:
  ```
  RunPwshTerminalBridge.swift:87:32: error: 'process' is inaccessible due to
  'internal' protection level
  ```
  Confirmed against the real, now-locally-vendored SwiftTerm 1.2.0 source
  (`swift/RunPwshTerminalBridge/.build/checkouts/SwiftTerm/Sources/SwiftTerm/
  Mac/MacLocalTerminalView.swift`, fetched by that same build attempt):
  `LocalProcessTerminalView.process` (the `LocalProcess` instance holding the
  child's pid) is declared with no access modifier, i.e. `internal`, so it
  can't be read directly from our separate SwiftPM package/module — even
  though `LocalProcess` itself has fully `public` `shellPid`/`terminate()`.
  There is no other public API on `LocalProcessTerminalView` that exposes
  the pid. Fixed `stopProcess()` in `RunPwshTerminalBridge.swift` by using
  `Mirror(reflecting:)` to read that internal stored property directly (a
  standard, safe Swift reflection technique — not a memory-safety hack) and
  calling the pid's `SIGTERM`→`SIGKILL` escalation exactly as before; falls
  back to sending Ctrl+C (0x03) through the pty via the also-public
  `send(source:data:)` if that property is ever renamed/removed in a future
  SwiftTerm release.
- While in there, cross-checked `startProcess(executable:args:environment:
  execName:)`, `feed(text:)`, and the `LocalProcessTerminalViewDelegate`
  method signatures (`sizeChanged`/`setTerminalTitle`/
  `hostCurrentDirectoryUpdate`/`processTerminated`) already used elsewhere in
  the file against the real source — all matched exactly what was written
  from memory in 2.0.0, no further changes needed there.

## [2.0.0] — 2026-08-26

### Changed (breaking)
- **The console is now a real, typeable terminal.** v1.2.0's pty fix
  (below) made masked prompts *work* in principle, but a plain read-only
  `NSTextView` couldn't render the ANSI/VT100 escape sequences PSReadLine
  now emits once it detects a real tty (e.g. `\e[?1h` — cursor-key
  application mode — showed up literally as garbled text `[?1h=`), and the
  separate narrow input field below it could only submit whole lines,
  incompatible with PSReadLine's actual interactive model (live
  keystroke-by-keystroke arrow-key history, tab-completion, in-place line
  redraws). Reported directly: *"Ich möchte die Eingaben auch direkt im
  Terminal-Fenster machen und nicht unten in einer schmalen Textbox."*
  Fixed properly this time by embedding a real terminal widget —
  [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm)'s
  `LocalProcessTerminalView` — instead of building a partial VT100
  interpreter from scratch. New `swift/RunPwshTerminalBridge/` SwiftPM
  package wraps it in a small `@objc` class (`RunPwshTerminalBridge.swift`)
  that `RunPwshPanelView.mm` embeds directly as the panel's console; typing
  now goes straight into that view, which SwiftTerm forwards live to the
  child's pty itself.
- **RunPwshEngine no longer runs scripts/selections.** Since the embedded
  terminal spawns and owns that process itself (its own pty, not one this
  plugin manages), `-launchTaskAtPath:...` (the openpty()-based version from
  1.2.0), `-runScriptAtPath:...`, `-runSelectionText:...`, `-sendInputLine:`,
  `-stop`, and `.isRunning` were all removed from `RunPwshEngine`. It's back
  to being just pwsh/brew discovery + Terminal.app launch +
  `installPwshViaHomebrew:...` (still a plain, non-interactive `NSPipe`
  NSTask, since brew's install output doesn't need a pty). `RunPwshPlugin.mm`
  now calls `RunPwshPanelView`'s new `-startProcessWithExecutable:
  arguments:currentDirectory:` / `-stopProcess` / `.isRunning` directly, and
  does its own temp-.ps1 bookkeeping for "Run Selection" (cleaned up via the
  panel delegate's new optional `-runPwshPanelViewProcessDidExit:exitCode:`).
- `RunPwshPanelView`'s old `-appendOutputText:`/`-clearOutput` are gone;
  replaced by `-feedText:` (feeds text into the embedded terminal exactly as
  if the process had printed it — used for the "[Finished with exit code N]"
  banner and Homebrew-install output) plus the terminal's own live
  rendering. The `RunPwshPanelViewDelegate` protocol's `-runPwshPanelView:
  didSendInputLine:` is gone too — there's no separate input field to submit
  from anymore.

### Build
- New build-time dependency: the Swift toolchain (`swift build` on PATH) and
  network access on first build, for the new
  `swift/RunPwshTerminalBridge/` SwiftPM package (depends on SwiftTerm).
  `CMakeLists.txt` shells out to `swift build -c release` for it rather than
  using CMake's native (Xcode-only-reliable) Swift language support, then
  links the resulting `libRunPwshTerminalBridge.dylib` into `RunPwsh.dylib`
  via an `@loader_path` rpath; `install_plugin` now copies both dylibs.
- `RunPwshTerminalBridge.swift`'s calls into SwiftTerm's
  `LocalProcessTerminalView`/`LocalProcessTerminalViewDelegate` API were
  written from memory (this project's sandbox has no network access to
  check the pinned SwiftTerm version's actual source) — flagged explicitly
  in that file's and the README's doc comments as needing verification
  against the first real `swift build` on a Mac.

## [1.2.0] — 2026-08-24

### Fixed
- Interactive input was unreliable and scripts with prompts would just
  finish immediately (exit code 0) without actually pausing — reported
  specifically with a masked credential prompt ("PowerShell credential
  request… Password for user …:") raised by `Enter-PSSession`. Root cause:
  `RunPwshEngine`'s stdin was a plain `NSPipe`. Plain `Read-Host`/numbered
  prompts worked over that (`Console.ReadLine()` doesn't care), but
  PowerShell/.NET's *masked* SecureString prompts check `isatty()` and then
  manipulate termios (turn `ECHO` off) directly on stdin — that only works
  against a real pseudo-terminal. Over a plain pipe, `isatty()` is false,
  the secure-read path misbehaves, and the surrounding cmdlet
  (`Enter-PSSession`, `Get-Credential`, etc.) errors out or falls through
  almost immediately instead of actually waiting.

### Changed
- `RunPwshEngine`'s `-launchTaskAtPath:arguments:workingDirectory:output:
  cleanup:completion:` now runs the child attached to a real pty
  (`openpty()`, `<util.h>`) instead of plain `NSPipe`s for stdin/stdout/
  stderr. One master `NSFileHandle` now serves both reading output and
  writing input (`-sendInputLine:`) — the pty is inherently bidirectional.
  Falls back to the old plain-pipe behavior if `openpty()` ever fails
  (logged; masked prompts wouldn't work in that fallback path, but plain
  prompts still would).
- `RunPwshPanelView`'s `-inputFieldSubmitted:` no longer manually echoes
  typed input into the console. With a real pty, the kernel's line
  discipline echoes back whatever is written to the master side on its own
  — correctly, based on whatever termios state pwsh has set at that
  moment. That means masked prompts now stay hidden exactly like in a real
  terminal, and plain prompts still show what was typed, without the panel
  needing to know which kind of prompt is currently active.

## [1.1.1] — 2026-08-24

### Changed
- **Docs only** — updated the "Panel placement" known limitation below
  with confirmed info from Andrew (Nextpad++ maintainer), asked 2026-08-24:
  bottom-docked panels are **planned for Nextpad++ 1.1.1** (host version,
  unrelated to this plugin's own version number). The mechanism partly
  exists already (used by the Search Results panel) but needs to be
  generalized + exposed via new top-bar dock-to-bottom icons before
  plugins can use it; details will be in that release's notes. His
  recommendation: don't wait — keep shipping with the side-panel (L/R)
  API as-is, then apply a small follow-up change once host 1.1.1 is out.
  No code changed in this release, hence no functional entry above.
- Also asked about code signing/notarization: Andrew notarizes the host
  app itself; for plugin zips manually copied into the plugins folder
  (our current dev workflow via `install_plugin`), notarization on our
  side doesn't matter. It only matters if we ship a zip meant to be
  installed via the host's own **Settings → Import** feature — that path
  triggers a Gatekeeper "unauthorized exec" warning for unsigned/
  un-notarized zips. Not relevant yet since RunPwsh isn't distributed
  that way.

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
  (`NPPM_DMM_REGISTERPANEL`) currently only registers into the shared
  side-panel host (same one used by Document List / Function List / the
  Finder plugin's own sidebar) — docking a panel *below* the editor, like
  the PowerShell ISE's console pane, isn't possible yet. **Update
  2026-08-24**: confirmed by Andrew (Nextpad++ maintainer) that
  bottom-docking is planned for host release 1.1.1, extending the
  mechanism the Search Results panel already partly uses. Until then this
  plugin keeps using the side-panel (L/R) API as-is, per his own
  recommendation, with a small follow-up change planned once 1.1.1 ships
  (see its release notes) — no need for the custom floating-`NSPanel`
  fallback that was being considered before this answer.
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

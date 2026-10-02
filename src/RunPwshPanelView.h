#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@class RunPwshPanelView;

/// The view deliberately has no reference to nppData/Scintilla/RunPwshEngine
/// by design (same separation of concerns as FinderPanelView) — it only
/// knows how to draw buttons + host an embedded terminal, and asks the
/// delegate (RunPwshPluginController) to actually do things, which is the
/// piece that knows about the active buffer, the current selection, and
/// where to find a `pwsh`/`brew` binary.
@protocol RunPwshPanelViewDelegate <NSObject>
- (void)runPwshPanelViewDidRequestRunScript:(RunPwshPanelView *)view;
- (void)runPwshPanelViewDidRequestRunSelection:(RunPwshPanelView *)view;
- (void)runPwshPanelViewDidRequestStop:(RunPwshPanelView *)view;
- (void)runPwshPanelViewDidRequestNewSession:(RunPwshPanelView *)view;
- (void)runPwshPanelViewDidRequestOpenTerminal:(RunPwshPanelView *)view;
- (void)runPwshPanelViewDidRequestInstallPwsh:(RunPwshPanelView *)view;

/// The embedded terminal's persistent session just ended (the `pwsh`
/// process behind it exited — e.g. the user typed `exit`, it crashed, or
/// -killSession was called), with `exitCode`. Fired right after the panel
/// has already fed its own "[Session ended]" banner and reset button
/// states. Optional: nothing needs to observe this beyond what the panel
/// already does on its own.
@optional
- (void)runPwshPanelViewProcessDidExit:(RunPwshPanelView *)view exitCode:(int32_t)exitCode;
@end

/// ISE-style panel: a small toolbar (Run Script / Run Selection / Stop /
/// New Session / Open in Terminal) above an embedded *real terminal*
/// (RunPwshTerminalBridge, backed by SwiftTerm's LocalProcessTerminalView —
/// see swift/RunPwshTerminalBridge/) — since v2.0.0 this is a genuine
/// terminal widget, not a read-only NSTextView + separate input field: the
/// user types directly into it, and full VT100/ANSI rendering plus live
/// keystroke forwarding (arrow keys, tab-completion, line history) all work
/// exactly like a real terminal, because PSReadLine really is talking to one
/// now. When no `pwsh` binary can be found, shows a banner with an "Install
/// via Homebrew" button instead of silently failing on first use.
///
/// Since v3.0.0 the terminal hosts one *persistent* interactive `pwsh`
/// session rather than a fresh throwaway process per run: "Run Script"/"Run
/// Selection" type their code into whichever session is already running
/// (starting one first if needed), so `$variables`/functions defined by one
/// run are still there for the next — matching real PowerShell ISE
/// behavior, and what the user actually expects when e.g. building a
/// `$cred` in one selection and using it in the next. "Stop" only interrupts
/// the current foreground command (Ctrl+C) and leaves the session (and its
/// variables) alive; "New Session" is the destructive action that actually
/// ends the `pwsh` process, for when a clean slate is wanted.
@interface RunPwshPanelView : NSView

@property (nonatomic, weak, nullable) id<RunPwshPanelViewDelegate> delegate;

/// YES while the embedded terminal has a live, persistent `pwsh` session (or
/// the Homebrew install process). Callers (RunPwshPluginController) check
/// this to decide whether -runText: needs -ensureSessionStartedWithExecutable:...
/// first, and to enable/disable the Stop button.
@property (nonatomic, readonly) BOOL hasSession;

/// Starts the persistent interactive session with `executable` (already-
/// resolved absolute path, e.g. the pwsh binary) and `arguments` (typically
/// empty — no `-File`, since this is meant to stay interactive) if one isn't
/// already running; a no-op (beyond calling `completion` right away) if
/// -hasSession is already YES. `currentDirectory` is applied via a
/// best-effort chdir immediately before spawning (see
/// RunPwshTerminalBridge.swift's -start:args:currentDirectory: doc comment)
/// and only matters for this initial spawn — later -runText: calls that
/// need a different working directory should prepend their own
/// `Set-Location` command.
///
/// `completion` is called on the main queue once it's actually safe to
/// -runText: into the session: immediately, if a session was already
/// running; after a short startup grace period, if this call just spawned a
/// brand-new one (v3.1.2 — see -runText:'s doc comment for why callers must
/// not just call -runText: right after this returns).
- (void)ensureSessionStartedWithExecutable:(NSString *)executable
                                  arguments:(NSArray<NSString *> *)arguments
                           currentDirectory:(nullable NSString *)currentDirectory
                                 completion:(void (^_Nullable)(void))completion;

/// Types `text` into the already-running session exactly as if the user had
/// typed it themselves (see RunPwshTerminalBridge.swift's -typeText: doc
/// comment) — the mechanism behind both "Run Script" (dot-sources the
/// current file) and "Run Selection" (types the selected text verbatim,
/// same as a manual copy/paste) as of v3.0.0. Every line ending in `text`
/// (embedded or trailing) is normalized to "\r" before being sent — a real
/// Enter keypress sends "\r" (CR) over a pty, and once PSReadLine has
/// attached and put the pty into raw mode, only "\r" is recognized as
/// "submit this line"; a bare "\n" (LF) is just inserted as a literal
/// character and never executes (v3.1.3 fix — see -runText:'s own doc
/// comment in the .mm for the exact user-reported symptom this addressed:
/// text got typed into the terminal but the command just sat there,
/// un-invoked).
///
/// Callers must only call this once the session is actually ready to read
/// input — i.e. either -hasSession was already YES, or from inside the
/// `completion` block passed to -ensureSessionStartedWithExecutable:...
/// (v3.1.2). Calling it right after that method merely *returns* (instead
/// of waiting for `completion`) races pwsh's own startup.
- (void)runText:(NSString *)text;

/// Sends Ctrl+C to interrupt whatever is currently running in the session,
/// without ending the session itself — wired to the toolbar's Stop button
/// and the "Stop" menu command.
- (void)interruptSession;

/// Ends the persistent session outright (SIGTERM, escalating to SIGKILL
/// after a short grace period if it's still alive) — wired to the toolbar's
/// "New Session" button and menu command, and called on plugin shutdown. A
/// later -runText: call lazily starts a brand-new session.
- (void)killSession;

/// Feeds `text` into the terminal exactly as if the running (or a
/// just-finished) process had printed it — used for this plugin's own
/// annotations (the "[Session ended]" banner, and the Homebrew-install
/// output, which still goes through a plain RunPwshEngine pipe since it's
/// non-interactive). `\n` is normalized to `\r\n` first, since a real
/// terminal needs the carriage return to actually return to column 0
/// instead of just moving down a line "staircase"-style.
- (void)feedText:(NSString *)text;

/// Toggles button enabled state: while YES, Stop is enabled (there's a live
/// session/process to interrupt or whose output is streaming); while NO, the
/// reverse. Run Script/Run Selection/New Session stay enabled regardless
/// (clicking them starts a session first if needed), matching the
/// persistent-session model — only Open in Terminal and the install banner
/// track this to avoid overlapping with the Homebrew install's own pipe.
/// Called automatically by -ensureSessionStartedWithExecutable:... and once
/// the session exits — exposed publicly only because the Homebrew-install
/// flow (still driven by RunPwshPluginController/RunPwshEngine directly)
/// also needs to drive it.
- (void)setSessionActive:(BOOL)active;

/// Shows/hides the "pwsh not found — install via Homebrew" banner. Pass a
/// human-readable reason (e.g. "Homebrew nicht gefunden" if that's *also*
/// missing) to replace the button with a plain message when installation
/// can't be offered directly.
- (void)showInstallBanner:(BOOL)show reason:(nullable NSString *)reason canInstall:(BOOL)canInstall;

/// Small status text under the toolbar, e.g. the resolved pwsh path or
/// "pwsh nicht gefunden".
- (void)setStatusText:(NSString *)text;

@end

NS_ASSUME_NONNULL_END

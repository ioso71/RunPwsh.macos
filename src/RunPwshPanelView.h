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
- (void)runPwshPanelViewDidRequestRestart:(RunPwshPanelView *)view;
- (void)runPwshPanelViewDidRequestInstallPwsh:(RunPwshPanelView *)view;

/// The host is hiding the panel — by the panel's own X button, the Toggle
/// command or NPPM_DMM_HIDEPANEL alike. The host calls -panelWillClose on the
/// panel view for every hide (informal selector, see MainWindowController.mm
/// -_setPanelVisible:title:show:), which is the only hook for the X button.
- (void)runPwshPanelViewWillClose:(RunPwshPanelView *)view;

@end

/// Panel with a small toolbar (Run Script / Run Selection / Stop / Restart
/// Session) above an embedded real terminal (RunPwshTerminalBridge, backed by
/// SwiftTerm's LocalProcessTerminalView — see swift/RunPwshTerminalBridge/).
/// The terminal hosts one persistent interactive `pwsh` session managed by
/// RunPwshSession: it starts when the panel is shown, and "Run" requests are
/// sent once pwsh has printed a prompt (never on a timer). When no `pwsh`
/// binary can be found, a banner offers an "Install via Homebrew" button.
@interface RunPwshPanelView : NSView

@property (nonatomic, weak, nullable) id<RunPwshPanelViewDelegate> delegate;

/// YES while the session is Starting, Ready or Running.
@property (nonatomic, readonly) BOOL sessionAlive;

/// Starts the persistent session with `executable` (absolute path to pwsh).
/// Creates the session object on first use; does nothing while a session is
/// already alive.
- (void)startSessionWithExecutable:(NSString *)executable;

/// Sends `text` to the session (queued if pwsh is still starting or busy).
/// Returns NO if the text is empty or no session can be started.
- (BOOL)runText:(NSString *)text;

/// Ctrl+C: interrupts the running command and drops any queued text. The
/// session stays alive.
- (void)interruptSession;

/// Ends the pwsh process and starts a fresh one.
- (void)restartSession;

/// Ends the pwsh process without restarting (plugin shutdown).
- (void)terminateSession;

/// Gives the embedded terminal keyboard focus.
- (void)focusTerminal;

/// Feeds `text` into the terminal exactly as if the running (or a
/// just-finished) process had printed it — used for this plugin's own
/// annotations (the "[Session ended]" banner, and the Homebrew-install
/// output, which still goes through a plain RunPwshEngine pipe since it's
/// non-interactive). `\n` is normalized to `\r\n` first, since a real
/// terminal needs the carriage return to actually return to column 0
/// instead of just moving down a line "staircase"-style.
- (void)feedText:(NSString *)text;

/// Enables the Stop button while a command is running (or the Homebrew
/// install is streaming output). Driven by the session state; the Homebrew
/// install flow in RunPwshPluginController also calls it directly.
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

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@class RunPwshPanelView;

/// The view deliberately has no reference to nppData/Scintilla/NSTask by
/// design (same separation of concerns as FinderPanelView) — it only knows
/// how to draw buttons and an output console and asks the delegate
/// (RunPwshPluginController) to actually do things, which is the piece that
/// knows about the active buffer, the current selection and the
/// RunPwshEngine.
@protocol RunPwshPanelViewDelegate <NSObject>
- (void)runPwshPanelViewDidRequestRunScript:(RunPwshPanelView *)view;
- (void)runPwshPanelViewDidRequestRunSelection:(RunPwshPanelView *)view;
- (void)runPwshPanelViewDidRequestStop:(RunPwshPanelView *)view;
- (void)runPwshPanelViewDidRequestOpenTerminal:(RunPwshPanelView *)view;
- (void)runPwshPanelViewDidRequestInstallPwsh:(RunPwshPanelView *)view;

/// The user typed `text` into the input field and pressed Return — send it
/// to the running task's stdin (e.g. to answer a `Connect-AzAccount`
/// tenant/subscription prompt, a `Read-Host`, or a `[Y/n]` confirm).
- (void)runPwshPanelView:(RunPwshPanelView *)view didSendInputLine:(NSString *)text;
@end

/// ISE-style panel: a small toolbar (Run Script / Run Selection / Stop /
/// Open in Terminal) above a read-only, monospaced output console. When no
/// `pwsh` binary can be found, shows a banner with an "Install via Homebrew"
/// button instead of silently failing on first use.
@interface RunPwshPanelView : NSView

@property (nonatomic, weak, nullable) id<RunPwshPanelViewDelegate> delegate;

/// Appends `text` to the output console and scrolls to the bottom. Safe to
/// call from any thread (hops to main internally) — callers still shouldn't
/// rely on that and should already be on the main thread per RunPwshEngine's
/// contract, this is just defense in depth for a console widget.
- (void)appendOutputText:(NSString *)text;

/// Clears the output console (called right before a new run starts).
- (void)clearOutput;

/// Toggles button enabled state: while YES, Run Script/Run Selection/Open
/// in Terminal are disabled and Stop is enabled; while NO, the reverse.
- (void)setRunningState:(BOOL)running;

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

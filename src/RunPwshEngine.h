/*
 * RunPwshEngine.h — everything that talks to the outside world *except*
 * actually running a script/selection: finding a `pwsh` (PowerShell 7+)
 * binary, launching an interactive pwsh session in Terminal, and installing
 * PowerShell via Homebrew. Deliberately has no dependency on
 * NppPluginInterfaceMac.h or nppData — it only knows about files, paths and
 * processes, so it could be unit-tested or reused standalone.
 *
 * Since v2.0.0, "Run Script"/"Run Selection" no longer go through this class
 * (see CHANGELOG 2.0.0): the panel's embedded terminal (RunPwshTerminalBridge,
 * SwiftTerm's LocalProcessTerminalView) now spawns and owns that process
 * itself, attached to its own pty, so the user can type directly into the
 * terminal widget and PSReadLine-driven interactive prompts (Get-Credential,
 * Connect-AzAccount's picker, Enter-PSSession's credential fallback) work
 * correctly. This class's own +findPwshPath/+findBrewPath are still what
 * resolves the executable/arguments the panel then hands to the terminal
 * bridge; +installPwshViaHomebrew:... and +openInteractivePwshInTerminal:...
 * are unaffected (neither one is interactive in a way that needs a pty).
 */
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface RunPwshEngine : NSObject

/// Full path to a working `pwsh` binary, or nil if none could be found.
/// Checks the well-known Homebrew/Microsoft-installer locations first
/// (fast, no subprocess), then falls back to a login-shell `command -v
/// pwsh` lookup (covers custom PATH setups) — GUI apps on macOS don't
/// inherit the user's shell PATH, so the direct-path checks are the
/// primary path and the shell lookup is the safety net, not the other way
/// around.
+ (nullable NSString *)findPwshPath;

/// Full path to a working `brew` binary, or nil if Homebrew isn't installed.
/// Same two-stage strategy as +findPwshPath.
+ (nullable NSString *)findBrewPath;

/// Opens a new Terminal window with an interactive `pwsh` session already
/// running, `cd`'d into `workingDirectory` first. Implemented via a
/// throwaway `.command` file handed to `/usr/bin/open` (Terminal.app is the
/// default handler for `.command`) rather than AppleScript, matching the
/// Finder plugin's "no AppleScript, no private API" approach for its own
/// "Open in Terminal" action.
+ (void)openInteractivePwshInTerminal:(NSString *)pwshPath
                      workingDirectory:(nullable NSString *)workingDirectory;

/// Runs `brew install --cask powershell`, streaming combined stdout/stderr
/// to `output` (main thread, as text arrives) — plain NSPipe is fine here
/// since this isn't interactive. `completion` (main thread) is called
/// exactly once with YES iff the process exited 0.
+ (void)installPwshViaHomebrew:(NSString *)brewPath
                          output:(void (^)(NSString *text))output
                      completion:(void (^)(BOOL success))completion;

@end

NS_ASSUME_NONNULL_END

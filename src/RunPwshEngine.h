/*
 * RunPwshEngine.h — everything that talks to the outside world: finding a
 * `pwsh` (PowerShell 7+) binary, running scripts/selections as an NSTask
 * with live stdout/stderr streaming, stopping a run, launching an
 * interactive pwsh session in Terminal, and installing PowerShell via
 * Homebrew. Deliberately has no dependency on NppPluginInterfaceMac.h or
 * nppData — it only knows about files, paths and processes, so it could be
 * unit-tested or reused standalone.
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

/// YES while a script/selection/install NSTask launched by this instance is
/// still running.
@property (nonatomic, readonly) BOOL isRunning;

/// Runs `<pwsh> -NoLogo -NoProfile -ExecutionPolicy Bypass -File <scriptPath>`
/// with `workingDirectory` as the current directory. `output` is called on
/// the main thread with each decoded chunk of combined stdout/stderr as it
/// arrives (line-buffering is the caller's concern, not this method's).
/// `completion` is called on the main thread exactly once, with the
/// process's exit code (or -1 if it couldn't be launched at all, in which
/// case `output` also receives a human-readable error first).
- (void)runScriptAtPath:(NSString *)scriptPath
             pwshPath:(NSString *)pwshPath
      workingDirectory:(nullable NSString *)workingDirectory
                output:(void (^)(NSString *text))output
            completion:(void (^)(int exitCode))completion;

/// Convenience for "Run Selection": writes `scriptText` to a private temp
/// .ps1 file (so error messages keep real line numbers, unlike piping
/// through -Command) and runs it exactly like -runScriptAtPath:..., deleting
/// the temp file again once the process exits.
///
/// Known limitation (v1.0.0): unlike the real PowerShell ISE, each call
/// starts a brand-new pwsh process, so variables/functions defined by one
/// "Run Selection" are NOT visible to the next one. A persistent background
/// pwsh session (feeding commands over stdin) would fix this but is a much
/// bigger change — noted in CHANGELOG "Known limitations" for now.
- (void)runSelectionText:(NSString *)scriptText
                 pwshPath:(NSString *)pwshPath
         workingDirectory:(nullable NSString *)workingDirectory
                   output:(void (^)(NSString *text))output
               completion:(void (^)(int exitCode))completion;

/// Terminates the currently-running task, if any. Safe to call when nothing
/// is running (no-op).
- (void)stop;

/// Writes `text` (with a trailing newline appended if not already present)
/// to the running task's stdin, so interactive prompts (e.g. `Connect-
/// AzAccount`'s tenant/subscription picker, `Read-Host`, a `[Y/n]` confirm)
/// can be answered from the panel. No-op if nothing is running.
- (void)sendInputLine:(NSString *)text;

/// Opens a new Terminal window with an interactive `pwsh` session already
/// running, `cd`'d into `workingDirectory` first. Implemented via a
/// throwaway `.command` file handed to `/usr/bin/open` (Terminal.app is the
/// default handler for `.command`) rather than AppleScript, matching the
/// Finder plugin's "no AppleScript, no private API" approach for its own
/// "Open in Terminal" action.
+ (void)openInteractivePwshInTerminal:(NSString *)pwshPath
                      workingDirectory:(nullable NSString *)workingDirectory;

/// Runs `brew install --cask powershell`. `output`/`completion` behave like
/// -runScriptAtPath:...; `completion`'s BOOL is YES iff the process exited 0.
+ (void)installPwshViaHomebrew:(NSString *)brewPath
                          output:(void (^)(NSString *text))output
                      completion:(void (^)(BOOL success))completion;

@end

NS_ASSUME_NONNULL_END

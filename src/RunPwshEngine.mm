#import "RunPwshEngine.h"

/// Runs `/bin/zsh -lc "<shellCommand>"` synchronously (login shell, so it
/// picks up the user's real PATH — including custom Homebrew prefixes,
/// asdf/nvm-style shims, etc. — which GUI apps launched from Finder/Dock
/// don't inherit otherwise) and returns trimmed stdout, or nil on any
/// failure/non-zero exit/empty output. Kept private to this file; both
/// +findPwshPath and +findBrewPath use it as their fallback stage.
static NSString *_Nullable RunPwshShellLookup(NSString *shellCommand) {
    NSTask *task = [[NSTask alloc] init];
    task.launchPath = @"/bin/zsh";
    task.arguments = @[@"-l", @"-c", shellCommand];
    NSPipe *pipe = [NSPipe pipe];
    task.standardOutput = pipe;
    task.standardError = [NSPipe pipe]; // discarded
    @try {
        [task launch];
    } @catch (NSException *ex) {
        NSLog(@"[RunPwsh plugin] shell lookup failed to launch: %@", ex);
        return nil;
    }
    NSData *data = [pipe.fileHandleForReading readDataToEndOfFile];
    [task waitUntilExit];
    if (task.terminationStatus != 0) return nil;
    NSString *out = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    out = [out stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return out.length > 0 ? out : nil;
}

/// First existing regular file among `candidates`, or nil.
static NSString *_Nullable RunPwshFirstExisting(NSArray<NSString *> *candidates) {
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *path in candidates) {
        BOOL isDir = NO;
        if ([fm fileExistsAtPath:path isDirectory:&isDir] && !isDir) {
            return path;
        }
    }
    return nil;
}

@implementation RunPwshEngine {
    NSTask *_currentTask;
    NSString *_pendingTempFileToDelete;
    NSFileHandle *_stdinHandle; // write end of the current task's stdin pipe; nil when nothing is running
}

+ (nullable NSString *)findPwshPath {
    NSString *known = RunPwshFirstExisting(@[
        @"/opt/homebrew/bin/pwsh",                          // Apple Silicon Homebrew
        @"/usr/local/bin/pwsh",                              // Intel Homebrew
        @"/usr/local/microsoft/powershell/7/pwsh",           // Official Microsoft .pkg installer
        @"/usr/local/microsoft/powershell/7-preview/pwsh",
    ]);
    if (known) return known;
    return RunPwshShellLookup(@"command -v pwsh");
}

+ (nullable NSString *)findBrewPath {
    NSString *known = RunPwshFirstExisting(@[
        @"/opt/homebrew/bin/brew",
        @"/usr/local/bin/brew",
    ]);
    if (known) return known;
    return RunPwshShellLookup(@"command -v brew");
}

- (BOOL)isRunning {
    return _currentTask != nil && _currentTask.isRunning;
}

/// Shared plumbing for -runScriptAtPath:... and +installPwshViaHomebrew:...:
/// launches `launchPath` with `arguments`, streams combined stdout+stderr to
/// `output` (main thread, as text arrives), and calls `completion` (main
/// thread) once with the exit code. `cleanup` (if non-nil) runs right before
/// `completion`, still off the main thread, e.g. to delete a temp file.
- (void)launchTaskAtPath:(NSString *)launchPath
                arguments:(NSArray<NSString *> *)arguments
        workingDirectory:(nullable NSString *)workingDirectory
                   output:(void (^)(NSString *text))output
                  cleanup:(nullable void (^)(void))cleanup
               completion:(void (^)(int exitCode))completion {
    NSTask *task = [[NSTask alloc] init];
    task.launchPath = launchPath;
    task.arguments = arguments;
    if (workingDirectory.length > 0) {
        task.currentDirectoryPath = workingDirectory;
    }

    NSPipe *pipe = [NSPipe pipe];
    task.standardOutput = pipe;
    task.standardError = pipe; // combined stream, like a real terminal — order between stdout/stderr is best-effort
    NSFileHandle *readHandle = pipe.fileHandleForReading;

    // stdin pipe: lets -sendInputLine: answer interactive prompts (tenant/
    // subscription pickers, Read-Host, [Y/n] confirms) while the task runs.
    // Without this, pwsh's stdin is NUL/closed and any prompt just hangs
    // forever with no way to respond from the panel.
    NSPipe *inputPipe = [NSPipe pipe];
    task.standardInput = inputPipe;
    NSFileHandle *stdinHandle = inputPipe.fileHandleForWriting;
    _stdinHandle = stdinHandle;

    readHandle.readabilityHandler = ^(NSFileHandle *handle) {
        NSData *data = [handle availableData];
        if (data.length == 0) return; // EOF
        NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        if (!text) return; // mid-multibyte-sequence chunk boundary; rare, next chunk will still decode fine overall
        dispatch_async(dispatch_get_main_queue(), ^{
            output(text);
        });
    };

    __weak RunPwshEngine *weakSelf = self;
    task.terminationHandler = ^(NSTask *finishedTask) {
        readHandle.readabilityHandler = nil; // stop the handler before draining anything further
        [stdinHandle closeFile];
        if (cleanup) cleanup();
        dispatch_async(dispatch_get_main_queue(), ^{
            RunPwshEngine *strongSelf = weakSelf;
            if (strongSelf && strongSelf->_currentTask == finishedTask) {
                strongSelf->_currentTask = nil;
                if (strongSelf->_stdinHandle == stdinHandle) {
                    strongSelf->_stdinHandle = nil;
                }
            }
            completion((int)finishedTask.terminationStatus);
        });
    };

    _currentTask = task;
    @try {
        [task launch];
    } @catch (NSException *ex) {
        readHandle.readabilityHandler = nil;
        [stdinHandle closeFile];
        _currentTask = nil;
        _stdinHandle = nil;
        if (cleanup) cleanup();
        output([NSString stringWithFormat:@"Fehler / Error: %@\n", ex.reason ?: ex.description]);
        completion(-1);
    }
}

- (void)sendInputLine:(NSString *)text {
    if (!_stdinHandle || text.length == 0) return;
    NSString *line = [text hasSuffix:@"\n"] ? text : [text stringByAppendingString:@"\n"];
    NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
    if (!data) return;
    @try {
        [_stdinHandle writeData:data];
    } @catch (NSException *ex) {
        NSLog(@"[RunPwsh plugin] Failed to write to stdin: %@", ex);
    }
}

- (void)runScriptAtPath:(NSString *)scriptPath
             pwshPath:(NSString *)pwshPath
      workingDirectory:(nullable NSString *)workingDirectory
                output:(void (^)(NSString *text))output
            completion:(void (^)(int exitCode))completion {
    [self launchTaskAtPath:pwshPath
                  arguments:@[@"-NoLogo", @"-NoProfile", @"-ExecutionPolicy", @"Bypass", @"-File", scriptPath]
          workingDirectory:workingDirectory
                     output:output
                    cleanup:nil
                 completion:completion];
}

- (void)runSelectionText:(NSString *)scriptText
                 pwshPath:(NSString *)pwshPath
         workingDirectory:(nullable NSString *)workingDirectory
                   output:(void (^)(NSString *text))output
               completion:(void (^)(int exitCode))completion {
    NSString *tempPath = [NSTemporaryDirectory() stringByAppendingPathComponent:
        [NSString stringWithFormat:@"RunPwsh-selection-%@.ps1", [NSUUID UUID].UUIDString]];
    NSError *writeError = nil;
    BOOL wrote = [scriptText writeToFile:tempPath atomically:YES encoding:NSUTF8StringEncoding error:&writeError];
    if (!wrote) {
        output([NSString stringWithFormat:@"Konnte temporäre Datei nicht schreiben / Could not write temp file: %@\n",
                 writeError.localizedDescription ?: @"?"]);
        completion(-1);
        return;
    }

    [self launchTaskAtPath:pwshPath
                  arguments:@[@"-NoLogo", @"-NoProfile", @"-ExecutionPolicy", @"Bypass", @"-File", tempPath]
          workingDirectory:workingDirectory
                     output:output
                    cleanup:^{
                        [[NSFileManager defaultManager] removeItemAtPath:tempPath error:nil];
                    }
                 completion:completion];
}

- (void)stop {
    if (_currentTask && _currentTask.isRunning) {
        [_currentTask terminate];
    }
}

+ (void)openInteractivePwshInTerminal:(NSString *)pwshPath
                      workingDirectory:(nullable NSString *)workingDirectory {
    NSString *dir = workingDirectory.length > 0 ? workingDirectory : NSHomeDirectory();
    // Single-quote-escape both paths for safe embedding in the shell script
    // below (replace each ' with '\'' , the standard POSIX-sh idiom).
    NSString *(^shQuote)(NSString *) = ^NSString *(NSString *s) {
        return [s stringByReplacingOccurrencesOfString:@"'" withString:@"'\\''"];
    };
    NSString *script = [NSString stringWithFormat:
        @"#!/bin/zsh\ncd '%@' 2>/dev/null\nexec '%@'\n",
        shQuote(dir), shQuote(pwshPath)];

    NSString *scriptPath = [NSTemporaryDirectory() stringByAppendingPathComponent:
        [NSString stringWithFormat:@"RunPwsh-launch-%@.command", [NSUUID UUID].UUIDString]];
    NSError *error = nil;
    if (![script writeToFile:scriptPath atomically:YES encoding:NSUTF8StringEncoding error:&error]) {
        NSLog(@"[RunPwsh plugin] Could not write launch script: %@", error);
        return;
    }
    [[NSFileManager defaultManager] setAttributes:@{NSFilePosixPermissions: @(0755)}
                                      ofItemAtPath:scriptPath error:nil];

    NSTask *task = [[NSTask alloc] init];
    task.launchPath = @"/usr/bin/open";
    task.arguments = @[scriptPath];
    @try {
        [task launch];
    } @catch (NSException *ex) {
        NSLog(@"[RunPwsh plugin] Failed to open Terminal: %@", ex);
    }
    // Best-effort cleanup of the throwaway .command file a few seconds
    // later, once Terminal.app has had time to read+exec it.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [[NSFileManager defaultManager] removeItemAtPath:scriptPath error:nil];
    });
}

+ (void)installPwshViaHomebrew:(NSString *)brewPath
                          output:(void (^)(NSString *text))output
                      completion:(void (^)(BOOL success))completion {
    RunPwshEngine *engine = [[RunPwshEngine alloc] init];
    // Keep the engine instance alive for the duration of the install by
    // capturing it strongly in the completion block below (it would
    // otherwise be deallocated immediately after this method returns).
    [engine launchTaskAtPath:brewPath
                    arguments:@[@"install", @"--cask", @"powershell"]
            workingDirectory:nil
                       output:output
                      cleanup:nil
                   completion:^(int exitCode) {
        (void)engine; // retained by this block until it runs
        completion(exitCode == 0);
    }];
}

@end

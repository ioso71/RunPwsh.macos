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

@implementation RunPwshEngine

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

/// Shared plumbing for +installPwshViaHomebrew:...: launches `launchPath`
/// with `arguments` over a plain NSPipe (fine here — brew's install output
/// isn't interactive, unlike a pwsh script/selection run, which since
/// v2.0.0 goes through the panel's embedded terminal instead of this class;
/// see RunPwshEngine.h's doc comment), streams combined stdout+stderr to
/// `output` (main thread, as text arrives), and calls `completion` (main
/// thread) once with the exit code.
- (void)launchTaskAtPath:(NSString *)launchPath
                arguments:(NSArray<NSString *> *)arguments
                   output:(void (^)(NSString *text))output
               completion:(void (^)(int exitCode))completion {
    NSTask *task = [[NSTask alloc] init];
    task.launchPath = launchPath;
    task.arguments = arguments;

    NSPipe *pipe = [NSPipe pipe];
    task.standardOutput = pipe;
    task.standardError = pipe;
    NSFileHandle *readHandle = pipe.fileHandleForReading;

    readHandle.readabilityHandler = ^(NSFileHandle *handle) {
        NSData *data = [handle availableData];
        if (data.length == 0) return; // EOF
        NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        if (!text) return; // mid-multibyte-sequence chunk boundary; rare, next chunk will still decode fine overall
        dispatch_async(dispatch_get_main_queue(), ^{
            output(text);
        });
    };

    task.terminationHandler = ^(NSTask *finishedTask) {
        readHandle.readabilityHandler = nil; // stop the handler before draining anything further
        dispatch_async(dispatch_get_main_queue(), ^{
            completion((int)finishedTask.terminationStatus);
        });
    };

    @try {
        [task launch];
    } @catch (NSException *ex) {
        readHandle.readabilityHandler = nil;
        output([NSString stringWithFormat:@"Fehler / Error: %@\n", ex.reason ?: ex.description]);
        completion(-1);
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
                       output:output
                   completion:^(int exitCode) {
        (void)engine; // retained by this block until it runs
        completion(exitCode == 0);
    }];
}

@end

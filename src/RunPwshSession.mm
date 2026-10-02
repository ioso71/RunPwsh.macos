#import "RunPwshSession.h"

@implementation RunPwshSession {
    id<RunPwshSessionTransport> _transport;
    RunPwshSessionState _state;
    NSString *_executable;
    NSString *_pending;        // single pending slot
    BOOL _restartAfterExit;
    BOOL _terminating;
}

+ (NSString *)initCommand {
    // Overrides `prompt`: emit OSC 7 first (SwiftTerm reports it through
    // hostCurrentDirectoryUpdate), then the normal "PS <path>> " text.
    // Second statement: SwiftTerm's macOS view does not draw the "dim"
    // attribute, so PSReadLine's default inline prediction colour
    // (ESC[97;2;3m = bright white, dim, italic) renders as solid white text
    // that looks real but cannot be deleted. Give it an explicit dark grey
    // (xterm-256 colour 238, #444444: barely visible on the black console).
    return @"function global:prompt { $e=[char]27; $b=[char]7; "
           @"$p=(Get-Location).ProviderPath; "
           @"[Console]::Write(\"$e]7;file://localhost$p$b\"); \"PS $p> \" }; "
           @"Set-PSReadLineOption -Colors @{ InlinePrediction = \"$([char]27)[38;5;238m\" }";
}

- (instancetype)initWithTransport:(id<RunPwshSessionTransport>)transport {
    if ((self = [super init])) {
        _transport = transport;
        _state = RunPwshSessionStateIdle;
        __weak RunPwshSession *weakSelf = self;
        _transport.onPrompt = ^{ [weakSelf handlePrompt]; };
        _transport.onExit = ^(int32_t code) { [weakSelf handleExit:code]; };
    }
    return self;
}

- (RunPwshSessionState)state { return _state; }
- (BOOL)hasPending { return _pending != nil; }

- (void)setState:(RunPwshSessionState)state {
    _state = state;
    if (_onStateChange) _onStateChange(state);
}

- (void)startWithExecutable:(NSString *)executable {
    if (_state != RunPwshSessionStateIdle && _state != RunPwshSessionStateEnded) return;
    _executable = [executable copy];
    _pending = nil;
    [self spawn];
}

- (void)spawn {
    _terminating = NO;
    [self setState:RunPwshSessionStateStarting];
    [_transport startWithExecutable:_executable
                               args:@[@"-NoLogo", @"-NoProfile", @"-ExecutionPolicy", @"Bypass",
                                      @"-NoExit", @"-Command", [RunPwshSession initCommand]]
                   currentDirectory:NSHomeDirectory()];
}

- (void)sendNow:(NSString *)text {
    [self setState:RunPwshSessionStateRunning];
    [_transport typeText:text];
}

- (BOOL)runText:(NSString *)text {
    // Tabs would trigger PSReadLine tab completion while typing; indentation
    // is cosmetic for PowerShell, so send spaces instead.
    NSString *t = [text stringByReplacingOccurrencesOfString:@"\t" withString:@"    "];
    t = [t stringByReplacingOccurrencesOfString:@"\r\n" withString:@"\r"];
    t = [t stringByReplacingOccurrencesOfString:@"\n" withString:@"\r"];
    if ([t stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].length == 0) {
        return NO;
    }
    if (![t hasSuffix:@"\r"]) t = [t stringByAppendingString:@"\r"];

    switch (_state) {
        case RunPwshSessionStateReady:
            [self sendNow:t];
            return YES;
        case RunPwshSessionStateStarting:
        case RunPwshSessionStateRunning:
            _pending = t;
            return YES;
        case RunPwshSessionStateIdle:
        case RunPwshSessionStateEnded:
            if (!_executable) return NO;
            _pending = nil;
            [self spawn];
            _pending = t;
            return YES;
    }
}

- (void)handlePrompt {
    if (_restartAfterExit) return;   // late prompt from the process being replaced
    if (_state != RunPwshSessionStateStarting && _state != RunPwshSessionStateRunning) return;
    [self setState:RunPwshSessionStateReady];
    if (_pending) {
        NSString *t = _pending;
        _pending = nil;
        [self sendNow:t];
    }
}

- (void)handleExit:(int32_t)code {
    if (!_restartAfterExit) _pending = nil;   // a restart keeps the Run queued for the new session
    if (_restartAfterExit && !_terminating) {
        // SwiftTerm's LocalProcess clears `running` only AFTER this callback
        // returns, and startProcess() is a no-op while `running` is set — so
        // the new process must be started on the next run-loop turn.
        _restartAfterExit = NO;
        __weak RunPwshSession *weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            RunPwshSession *strongSelf = weakSelf;
            if (!strongSelf || strongSelf->_terminating) return;
            [strongSelf spawn];
        });
        return;
    }
    [self setState:RunPwshSessionStateEnded];
}

- (void)interrupt {
    _pending = nil;
    [_transport interrupt];
}

- (void)restart {
    if (_state == RunPwshSessionStateIdle || _state == RunPwshSessionStateEnded) {
        if (_executable) { _pending = nil; [self spawn]; }
        return;
    }
    // New Runs queue for the NEW session from now on, never into the dying one.
    _restartAfterExit = YES;
    _pending = nil;
    [self setState:RunPwshSessionStateStarting];
    [_transport kill];
}

- (void)terminate {
    _terminating = YES;
    _restartAfterExit = NO;
    _pending = nil;
    [_transport kill];
}

@end

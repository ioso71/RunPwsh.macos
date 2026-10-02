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
    return @"function global:prompt { $e=[char]27; $b=[char]7; "
           @"$p=(Get-Location).ProviderPath; "
           @"[Console]::Write(\"$e]7;file://localhost$p$b\"); \"PS $p> \" }";
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

- (void)setState:(RunPwshSessionState)state {
    _state = state;
    if (_onStateChange) _onStateChange(state);
}

- (void)startWithExecutable:(NSString *)executable {
    if (_state != RunPwshSessionStateIdle && _state != RunPwshSessionStateEnded) return;
    _executable = [executable copy];
    [self spawn];
}

- (void)spawn {
    _pending = nil;
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
    NSString *t = [text stringByReplacingOccurrencesOfString:@"\r\n" withString:@"\r"];
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
            [self spawn];
            _pending = t;
            return YES;
    }
}

- (void)handlePrompt {
    if (_state != RunPwshSessionStateStarting && _state != RunPwshSessionStateRunning) return;
    [self setState:RunPwshSessionStateReady];
    if (_pending) {
        NSString *t = _pending;
        _pending = nil;
        [self sendNow:t];
    }
}

- (void)handleExit:(int32_t)code {
    _pending = nil;
    if (_restartAfterExit && !_terminating) {
        _restartAfterExit = NO;
        [self spawn];
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
        if (_executable) [self spawn];
        return;
    }
    _restartAfterExit = YES;
    _pending = nil;
    [_transport kill];
}

- (void)terminate {
    _terminating = YES;
    _restartAfterExit = NO;
    _pending = nil;
    [_transport kill];
}

@end

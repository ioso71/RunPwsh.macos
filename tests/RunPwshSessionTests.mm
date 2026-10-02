// Plain assert-style tests (no XCTest in this repo). Build and run with:
//   cmake --build build --target run_session_tests
#import <Foundation/Foundation.h>
#import "RunPwshSession.h"

@interface FakeTransport : NSObject <RunPwshSessionTransport>
@property (nonatomic, copy, nullable) void (^onPrompt)(void);
@property (nonatomic, copy, nullable) void (^onExit)(int32_t exitCode);
@property (nonatomic, strong) NSMutableArray<NSString *> *typed;
@property (nonatomic) int startCount, interruptCount, killCount;
@property (nonatomic, copy) NSArray<NSString *> *lastArgs;
@property (nonatomic, copy) NSString *lastCwd;
@property (nonatomic) BOOL insideExit;     // SwiftTerm sets running=false only AFTER the exit callback returns
@property (nonatomic) int refusedStarts;
@end
@implementation FakeTransport
- (instancetype)init { if ((self = [super init])) _typed = [NSMutableArray array]; return self; }
- (void)startWithExecutable:(NSString *)e args:(NSArray<NSString *> *)a currentDirectory:(NSString *)c {
    if (_insideExit) { _refusedStarts++; return; }   // LocalProcess.startProcess: `if running { return }`
    _startCount++; _lastArgs = a; _lastCwd = c;
}
- (void)typeText:(NSString *)t { [_typed addObject:t]; }
- (void)interrupt { _interruptCount++; }
- (void)kill { _killCount++; }
- (void)prompt { if (_onPrompt) _onPrompt(); }
- (void)exitWith:(int32_t)code {
    _insideExit = YES;
    if (_onExit) _onExit(code);
    _insideExit = NO;
}
// Runs work that the session deferred past the exit callback (dispatch_async to main).
- (void)drain {
    for (int i = 0; i < 5; i++) [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
}
@end

static int gFailures = 0;
#define CHECK(cond) do { if (!(cond)) { gFailures++; fprintf(stderr, "FAIL %s:%d  %s\n", __FILE__, __LINE__, #cond); } } while (0)

static RunPwshSession *Make(FakeTransport **out) {
    FakeTransport *t = [FakeTransport new];
    RunPwshSession *s = [[RunPwshSession alloc] initWithTransport:t];
    *out = t;
    return s;
}

static void testStartPassesInitCommandAndHome(void) {
    FakeTransport *t; RunPwshSession *s = Make(&t);
    [s startWithExecutable:@"/bin/pwsh"];
    CHECK(s.state == RunPwshSessionStateStarting);
    CHECK(t.startCount == 1);
    CHECK([t.lastArgs containsObject:@"-NoExit"]);
    CHECK([t.lastArgs containsObject:[RunPwshSession initCommand]]);
    CHECK([t.lastCwd isEqualToString:NSHomeDirectory()]);
}

static void testFirstPromptMakesReadyAndNothingTypedBefore(void) {
    FakeTransport *t; RunPwshSession *s = Make(&t);
    [s startWithExecutable:@"/bin/pwsh"];
    CHECK(t.typed.count == 0);
    [t prompt];
    CHECK(s.state == RunPwshSessionStateReady);
}

// Review focus 1
static void testRunWhileStartingIsQueuedAndSentOnceAfterFirstPrompt(void) {
    FakeTransport *t; RunPwshSession *s = Make(&t);
    [s startWithExecutable:@"/bin/pwsh"];
    CHECK([s runText:@"Get-Date"]);
    CHECK(t.typed.count == 0);
    [t prompt];
    CHECK(t.typed.count == 1);
    CHECK([t.typed[0] isEqualToString:@"Get-Date\r"]);
    CHECK(s.state == RunPwshSessionStateRunning);
    [t prompt];
    CHECK(t.typed.count == 1);
    CHECK(s.state == RunPwshSessionStateReady);
}

static void testRunWhenReadySendsImmediately(void) {
    FakeTransport *t; RunPwshSession *s = Make(&t);
    [s startWithExecutable:@"/bin/pwsh"]; [t prompt];
    CHECK([s runText:@"1+1"]);
    CHECK(t.typed.count == 1 && [t.typed[0] isEqualToString:@"1+1\r"]);
    CHECK(s.state == RunPwshSessionStateRunning);
}

// Review focus 2
static void testRunWhileRunningReplacesPendingAndWaitsForPrompt(void) {
    FakeTransport *t; RunPwshSession *s = Make(&t);
    [s startWithExecutable:@"/bin/pwsh"]; [t prompt];
    [s runText:@"Start-Sleep 5"];
    [s runText:@"first"];
    [s runText:@"second"];
    CHECK(t.typed.count == 1);
    [t prompt];
    CHECK(t.typed.count == 2 && [t.typed[1] isEqualToString:@"second\r"]);
}

// Review focus 3
static void testInterruptDropsPendingAndSendsCtrlC(void) {
    FakeTransport *t; RunPwshSession *s = Make(&t);
    [s startWithExecutable:@"/bin/pwsh"]; [t prompt];
    [s runText:@"Start-Sleep 5"];
    [s runText:@"queued"];
    [s interrupt];
    CHECK(t.interruptCount == 1);
    [t prompt];
    CHECK(t.typed.count == 1);
    CHECK(s.state == RunPwshSessionStateReady);
}

// Review focus 4
static void testExitDropsPendingAndEnds(void) {
    FakeTransport *t; RunPwshSession *s = Make(&t);
    [s startWithExecutable:@"/bin/pwsh"]; [t prompt];
    [s runText:@"Start-Sleep 5"];
    [s runText:@"queued"];
    [t exitWith:0];
    CHECK(s.state == RunPwshSessionStateEnded);
    CHECK(t.typed.count == 1);
}

static void testRunOnEndedSessionStartsANewOne(void) {
    FakeTransport *t; RunPwshSession *s = Make(&t);
    [s startWithExecutable:@"/bin/pwsh"]; [t prompt]; [t exitWith:0];
    CHECK([s runText:@"Get-Date"]);
    CHECK(t.startCount == 2);
    CHECK(s.state == RunPwshSessionStateStarting);
    [t prompt];
    CHECK(t.typed.count == 1 && [t.typed[0] isEqualToString:@"Get-Date\r"]);
}

static void testRunOnIdleWithoutExecutableIsRejected(void) {
    FakeTransport *t; RunPwshSession *s = Make(&t);
    CHECK(![s runText:@"Get-Date"]);
    CHECK(t.startCount == 0);
}

// Review focus 5
static void testRestartWhileRunningStartsExactlyOneNewSession(void) {
    FakeTransport *t; RunPwshSession *s = Make(&t);
    [s startWithExecutable:@"/bin/pwsh"]; [t prompt];
    [s runText:@"Start-Sleep 30"];
    [s restart];
    CHECK(t.killCount == 1);
    CHECK(t.startCount == 1);
    [t exitWith:143]; [t drain];
    CHECK(t.startCount == 2);
    CHECK(s.state == RunPwshSessionStateStarting);
    [t prompt];
    CHECK(s.state == RunPwshSessionStateReady);
}

static void testRestartWhileStartingDoesNotEndNewSession(void) {
    FakeTransport *t; RunPwshSession *s = Make(&t);
    [s startWithExecutable:@"/bin/pwsh"];
    [s restart];
    [t exitWith:143]; [t drain];
    CHECK(t.startCount == 2);
    CHECK(s.state == RunPwshSessionStateStarting);
}

static void testRestartOnEndedStartsDirectly(void) {
    FakeTransport *t; RunPwshSession *s = Make(&t);
    [s startWithExecutable:@"/bin/pwsh"]; [t prompt]; [t exitWith:0];
    [s restart];
    CHECK(t.killCount == 0);
    CHECK(t.startCount == 2);
}

// Review focus 6
static void testNormalisation(void) {
    FakeTransport *t; RunPwshSession *s = Make(&t);
    [s startWithExecutable:@"/bin/pwsh"]; [t prompt];
    [s runText:@"a\r\nb\nc\n"];
    CHECK([t.typed[0] isEqualToString:@"a\rb\rc\r"]);
    [t prompt];
    CHECK(![s runText:@"  \n\t "]);
    CHECK(t.typed.count == 1);
}

static void testTerminateDoesNotRestart(void) {
    FakeTransport *t; RunPwshSession *s = Make(&t);
    [s startWithExecutable:@"/bin/pwsh"]; [t prompt];
    [s terminate];
    CHECK(t.killCount == 1);
    [t exitWith:143];
    CHECK(t.startCount == 1);
    CHECK(s.state == RunPwshSessionStateEnded);
}

static void testStateChangeIsReported(void) {
    FakeTransport *t; RunPwshSession *s = Make(&t);
    NSMutableArray<NSNumber *> *seen = [NSMutableArray array];
    s.onStateChange = ^(RunPwshSessionState st) { [seen addObject:@(st)]; };
    [s startWithExecutable:@"/bin/pwsh"]; [t prompt]; [s runText:@"x"]; [t prompt];
    NSArray *expect = @[@(RunPwshSessionStateStarting), @(RunPwshSessionStateReady),
                        @(RunPwshSessionStateRunning), @(RunPwshSessionStateReady)];
    CHECK([seen isEqualToArray:expect]);
}

// ---- Fix pass: findings from the final review ----

// Critical 1: a restart must not start pwsh from inside the exit callback.
static void testRestartSpawnsAfterExitCallbackReturns(void) {
    FakeTransport *t; RunPwshSession *s = Make(&t);
    [s startWithExecutable:@"/bin/pwsh"]; [t prompt];
    [s restart];
    [t exitWith:143];
    [t drain];
    CHECK(t.refusedStarts == 0);
    CHECK(t.startCount == 2);
    CHECK(s.state == RunPwshSessionStateStarting);
    [t prompt];
    CHECK(s.state == RunPwshSessionStateReady);
}

// Important 2: a Run between Restart and the old exit is queued for the NEW session,
// not typed into the dying process and not dropped.
static void testRunBetweenRestartAndExitGoesToNewSession(void) {
    FakeTransport *t; RunPwshSession *s = Make(&t);
    [s startWithExecutable:@"/bin/pwsh"]; [t prompt];
    [s restart];
    CHECK([s runText:@"Get-Date"]);
    CHECK(t.typed.count == 0);
    [t prompt];                       // late prompt from the dying process must not release it
    CHECK(t.typed.count == 0);
    [t exitWith:143]; [t drain];
    [t prompt];
    CHECK(t.typed.count == 1 && [t.typed[0] isEqualToString:@"Get-Date\r"]);
}

static void testRunWhileRunningThenRestartKeepsNewRun(void) {
    FakeTransport *t; RunPwshSession *s = Make(&t);
    [s startWithExecutable:@"/bin/pwsh"]; [t prompt];
    [s runText:@"Start-Sleep 30"];
    [s restart];
    [s runText:@"after-restart"];
    [t exitWith:143]; [t drain]; [t prompt];
    CHECK(t.typed.count == 2 && [t.typed[1] isEqualToString:@"after-restart\r"]);
}

// Important 1 (session part): Restart on an Ended session starts exactly one process.
static void testRestartOnEndedStartsExactlyOnce(void) {
    FakeTransport *t; RunPwshSession *s = Make(&t);
    [s startWithExecutable:@"/bin/pwsh"]; [t prompt]; [t exitWith:0];
    [s restart]; [t drain];
    CHECK(t.startCount == 2);
    CHECK(t.killCount == 0);
    CHECK(s.state == RunPwshSessionStateStarting);
}

// Important 3: Stop must get a queued Run out of Starting/Running; state is observable.
static void testInterruptWhileStartingDropsQueue(void) {
    FakeTransport *t; RunPwshSession *s = Make(&t);
    [s startWithExecutable:@"/bin/pwsh"];
    [s runText:@"queued"];
    CHECK(s.hasPending);
    [s interrupt];
    CHECK(!s.hasPending);
    [t prompt];
    CHECK(t.typed.count == 0);
}

// Important 6: tabs in typed code must not trigger PSReadLine completion.
static void testTabsBecomeSpaces(void) {
    FakeTransport *t; RunPwshSession *s = Make(&t);
    [s startWithExecutable:@"/bin/pwsh"]; [t prompt];
    [s runText:@"foreach ($i in 1..2) {\n\tWrite-Output $i\n}"];
    CHECK([t.typed[0] rangeOfString:@"\t"].location == NSNotFound);
    CHECK([t.typed[0] rangeOfString:@"    Write-Output"].location != NSNotFound);
}

// Terminate must not respawn even if the exit callback arrives later.
static void testTerminateThenDrainDoesNotRespawn(void) {
    FakeTransport *t; RunPwshSession *s = Make(&t);
    [s startWithExecutable:@"/bin/pwsh"]; [t prompt];
    [s terminate]; [t exitWith:143]; [t drain];
    CHECK(t.startCount == 1);
    CHECK(s.state == RunPwshSessionStateEnded);
}

int main(void) {
    @autoreleasepool {
        testStartPassesInitCommandAndHome();
        testFirstPromptMakesReadyAndNothingTypedBefore();
        testRunWhileStartingIsQueuedAndSentOnceAfterFirstPrompt();
        testRunWhenReadySendsImmediately();
        testRunWhileRunningReplacesPendingAndWaitsForPrompt();
        testInterruptDropsPendingAndSendsCtrlC();
        testExitDropsPendingAndEnds();
        testRunOnEndedSessionStartsANewOne();
        testRunOnIdleWithoutExecutableIsRejected();
        testRestartWhileRunningStartsExactlyOneNewSession();
        testRestartWhileStartingDoesNotEndNewSession();
        testRestartOnEndedStartsDirectly();
        testNormalisation();
        testTerminateDoesNotRestart();
        testStateChangeIsReported();
        testRestartSpawnsAfterExitCallbackReturns();
        testRunBetweenRestartAndExitGoesToNewSession();
        testRunWhileRunningThenRestartKeepsNewRun();
        testRestartOnEndedStartsExactlyOnce();
        testInterruptWhileStartingDropsQueue();
        testTabsBecomeSpaces();
        testTerminateThenDrainDoesNotRespawn();
    }
    if (gFailures) { fprintf(stderr, "%d check(s) failed\n", gFailures); return 1; }
    printf("All session tests passed\n");
    return 0;
}

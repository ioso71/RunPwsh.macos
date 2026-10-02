#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, RunPwshSessionState) {
    RunPwshSessionStateIdle,      // nothing started yet
    RunPwshSessionStateStarting,  // process spawned, no prompt seen yet
    RunPwshSessionStateReady,     // at a prompt, safe to type
    RunPwshSessionStateRunning,   // a command was sent, waiting for the next prompt
    RunPwshSessionStateEnded,     // process exited
};

/// What the session needs from the terminal. The panel adapts
/// RunPwshTerminalBridge to this; the tests use a fake.
@protocol RunPwshSessionTransport <NSObject>
/// Fired (main thread) each time pwsh prints a prompt.
@property (nonatomic, copy, nullable) void (^onPrompt)(void);
/// Fired (main thread) when the process exits.
@property (nonatomic, copy, nullable) void (^onExit)(int32_t exitCode);
- (void)startWithExecutable:(NSString *)executable
                       args:(NSArray<NSString *> *)args
           currentDirectory:(nullable NSString *)currentDirectory;
- (void)typeText:(NSString *)text;
- (void)interrupt;
- (void)kill;
@end

/// One persistent interactive pwsh session. Replaces the timer-based startup
/// of 3.x: "ready" means pwsh printed a prompt, not "some time has passed".
/// Main thread only.
@interface RunPwshSession : NSObject

@property (nonatomic, readonly) RunPwshSessionState state;
/// YES while a Run request is waiting for the next prompt (the panel shows a
/// hint and keeps Stop enabled so the user can always get out of a stall).
@property (nonatomic, readonly) BOOL hasPending;
/// Called on every state change (main thread).
@property (nonatomic, copy, nullable) void (^onStateChange)(RunPwshSessionState state);

- (instancetype)initWithTransport:(id<RunPwshSessionTransport>)transport NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

/// The -Command argument that overrides `prompt` so that every prompt first
/// emits OSC 7 (`ESC ] 7 ; file://localhost<cwd> BEL`).
+ (NSString *)initCommand;

/// Starts pwsh in the user's home directory. No-op unless Idle or Ended.
/// Remembers `executable` so a later -runText: on an Ended session can restart.
- (void)startWithExecutable:(NSString *)executable;

/// Types `text` (line endings normalised to \r, one trailing \r). Sent now if
/// Ready; queued in a single pending slot if Starting or Running (a newer
/// request replaces an older one); starts a new session first if Idle/Ended
/// and an executable is known. Returns NO if the text is empty/whitespace or
/// nothing can be started.
- (BOOL)runText:(NSString *)text;

/// Ctrl+C. Drops any queued text. The session stays alive.
- (void)interrupt;

/// Ends the process and starts a fresh one. Exactly one new session results.
- (void)restart;

/// Ends the process without restarting (plugin shutdown).
- (void)terminate;

@end

NS_ASSUME_NONNULL_END

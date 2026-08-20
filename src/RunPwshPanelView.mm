#import "RunPwshPanelView.h"
#import "RunPwshLocalization.h"
#include <cfloat>

/// Fixed dark console colors (background + text), used regardless of the
/// host's light/dark appearance — matches the PowerShell ISE / most
/// terminal apps, which default to a dark console rather than following
/// system appearance, and reads better against ANSI-colored pwsh output.
static NSColor *RunPwshConsoleBackgroundColor(void) {
    return [NSColor colorWithCalibratedWhite:0.11 alpha:1.0];
}
static NSColor *RunPwshConsoleTextColor(void) {
    return [NSColor colorWithCalibratedWhite:0.92 alpha:1.0];
}

@interface RunPwshPanelView ()
@end

@implementation RunPwshPanelView {
    NSButton *_runScriptButton;
    NSButton *_runSelectionButton;
    NSButton *_stopButton;
    NSButton *_openTerminalButton;
    NSTextField *_statusLabel;

    NSView *_banner;
    NSTextField *_bannerLabel;
    NSButton *_bannerInstallButton;
    NSLayoutConstraint *_bannerHeightConstraint;

    NSScrollView *_outputScroll;
    NSTextView *_outputView;

    NSTextField *_inputField;
}

#pragma mark - Init / layout

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (self) {
        [self buildUI];

        __weak RunPwshPanelView *weakSelf = self;
        [RunPwshLocalization observeLanguageChangesWithBlock:^{
            [weakSelf relocalizeUI];
        }];
    }
    return self;
}

- (void)buildUI {
    self.translatesAutoresizingMaskIntoConstraints = NO;

    // ── Toolbar ──────────────────────────────────────────────────────────
    NSView *toolbar = [[NSView alloc] init];
    toolbar.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:toolbar];

    _runScriptButton = [self toolbarButtonWithSymbol:@"play.fill"
                                              tooltip:RPLoc(@"Script ausführen", @"Run Script")
                                               action:@selector(runScriptClicked:)];
    _runScriptButton.contentTintColor = [NSColor systemGreenColor];

    _runSelectionButton = [self toolbarButtonWithSymbol:@"play.rectangle"
                                                 tooltip:RPLoc(@"Auswahl ausführen", @"Run Selection")
                                                  action:@selector(runSelectionClicked:)];

    _stopButton = [self toolbarButtonWithSymbol:@"stop.fill"
                                         tooltip:RPLoc(@"Vorgang beenden", @"Stop")
                                          action:@selector(stopClicked:)];
    _stopButton.contentTintColor = [NSColor systemGrayColor];
    _stopButton.enabled = NO;

    _openTerminalButton = [self toolbarButtonWithSymbol:@"terminal"
                                                 tooltip:RPLoc(@"Pwsh in Terminal starten", @"Start Pwsh in Terminal")
                                                  action:@selector(openTerminalClicked:)];
    _openTerminalButton.contentTintColor = [NSColor systemBlueColor];

    for (NSButton *b in @[_runScriptButton, _runSelectionButton, _stopButton, _openTerminalButton]) {
        [toolbar addSubview:b];
    }

    _statusLabel = [NSTextField labelWithString:@""];
    _statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _statusLabel.font = [NSFont systemFontOfSize:11];
    _statusLabel.textColor = [NSColor secondaryLabelColor];
    _statusLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
    [toolbar addSubview:_statusLabel];

    NSDictionary *toolbarViews = NSDictionaryOfVariableBindings(
        _runScriptButton, _runSelectionButton, _stopButton, _openTerminalButton, _statusLabel);
    [toolbar addConstraints:[NSLayoutConstraint constraintsWithVisualFormat:
        @"H:|-4-[_runScriptButton(26)]-4-[_runSelectionButton(26)]-4-[_stopButton(26)]-10-[_openTerminalButton(26)]-10-[_statusLabel(>=60)]-4-|"
        options:NSLayoutFormatAlignAllCenterY metrics:nil views:toolbarViews]];
    [toolbar addConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"V:|-3-[_runScriptButton(26)]-3-|"
        options:0 metrics:nil views:toolbarViews]];

    // ── Install banner (hidden by default) ─────────────────────────────
    _banner = [[NSView alloc] init];
    _banner.translatesAutoresizingMaskIntoConstraints = NO;
    _banner.wantsLayer = YES;
    _banner.layer.backgroundColor = [NSColor colorWithCalibratedRed:0.98 green:0.85 blue:0.35 alpha:0.25].CGColor;
    [self addSubview:_banner];

    _bannerLabel = [NSTextField wrappingLabelWithString:@""];
    _bannerLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _bannerLabel.font = [NSFont systemFontOfSize:11];
    [_banner addSubview:_bannerLabel];

    _bannerInstallButton = [[NSButton alloc] init];
    _bannerInstallButton.translatesAutoresizingMaskIntoConstraints = NO;
    _bannerInstallButton.bezelStyle = NSBezelStyleRounded;
    _bannerInstallButton.title = RPLoc(@"Installieren via Homebrew", @"Install via Homebrew");
    _bannerInstallButton.target = self;
    _bannerInstallButton.action = @selector(installClicked:);
    [_banner addSubview:_bannerInstallButton];

    NSDictionary *bannerViews = NSDictionaryOfVariableBindings(_bannerLabel, _bannerInstallButton);
    [_banner addConstraints:[NSLayoutConstraint constraintsWithVisualFormat:
        @"H:|-8-[_bannerLabel]-8-[_bannerInstallButton]-8-|"
        options:NSLayoutFormatAlignAllCenterY metrics:nil views:bannerViews]];
    [_banner addConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"V:|-6-[_bannerLabel]-6-|"
        options:0 metrics:nil views:bannerViews]];

    _bannerHeightConstraint = [NSLayoutConstraint constraintWithItem:_banner
        attribute:NSLayoutAttributeHeight relatedBy:NSLayoutRelationEqual
        toItem:nil attribute:NSLayoutAttributeNotAnAttribute multiplier:1 constant:0];
    _bannerHeightConstraint.active = YES;
    [_banner addConstraint:_bannerHeightConstraint];

    // ── Output console ──────────────────────────────────────────────────
    _outputView = [[NSTextView alloc] init];
    _outputView.editable = NO;
    _outputView.selectable = YES;
    _outputView.richText = NO;
    _outputView.font = [NSFont fontWithName:@"Menlo" size:12] ?: [NSFont monospacedSystemFontOfSize:12 weight:NSFontWeightRegular];
    // Fixed dark console theme (not tied to system light/dark mode) — see
    // RunPwshConsoleBackgroundColor()/RunPwshConsoleTextColor() above.
    _outputView.textColor = RunPwshConsoleTextColor();
    _outputView.backgroundColor = RunPwshConsoleBackgroundColor();
    _outputView.drawsBackground = YES;
    _outputView.insertionPointColor = RunPwshConsoleTextColor();
    _outputView.textContainerInset = NSMakeSize(4, 4);
    _outputView.minSize = NSMakeSize(0, 0);
    _outputView.maxSize = NSMakeSize(FLT_MAX, FLT_MAX);
    _outputView.verticallyResizable = YES;
    _outputView.horizontallyResizable = NO;
    _outputView.autoresizingMask = NSViewWidthSizable;
    _outputView.textContainer.widthTracksTextView = YES;

    _outputScroll = [[NSScrollView alloc] init];
    _outputScroll.translatesAutoresizingMaskIntoConstraints = NO;
    _outputScroll.documentView = _outputView;
    _outputScroll.hasVerticalScroller = YES;
    _outputScroll.autohidesScrollers = YES;
    _outputScroll.borderType = NSNoBorder;
    _outputScroll.drawsBackground = YES;
    _outputScroll.backgroundColor = RunPwshConsoleBackgroundColor();
    [self addSubview:_outputScroll];

    // ── Input row (send a line to the running task's stdin) ────────────
    // Needed for interactive prompts a script may raise mid-run (e.g.
    // Connect-AzAccount's tenant/subscription picker, Read-Host, a
    // [Y/n] confirm) — the console itself is read-only, this is the only
    // way to answer them. Only enabled while a task is actually running
    // (see -setRunningState:).
    NSView *inputRow = [[NSView alloc] init];
    inputRow.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:inputRow];

    _inputField = [[NSTextField alloc] init];
    _inputField.translatesAutoresizingMaskIntoConstraints = NO;
    _inputField.placeholderString = RPLoc(@"Eingabe an pwsh senden und Enter drücken…",
                                           @"Type input for pwsh and press Enter…");
    _inputField.font = [NSFont fontWithName:@"Menlo" size:12] ?: [NSFont monospacedSystemFontOfSize:12 weight:NSFontWeightRegular];
    _inputField.target = self;
    _inputField.action = @selector(inputFieldSubmitted:);
    _inputField.enabled = NO; // enabled only while a task is running
    [inputRow addSubview:_inputField];

    NSDictionary *inputRowViews = NSDictionaryOfVariableBindings(_inputField);
    [inputRow addConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"H:|-4-[_inputField]-4-|"
        options:0 metrics:nil views:inputRowViews]];
    [inputRow addConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"V:|-2-[_inputField]-2-|"
        options:0 metrics:nil views:inputRowViews]];

    NSDictionary *rootViews = NSDictionaryOfVariableBindings(toolbar, _banner, _outputScroll, inputRow);
    [self addConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"H:|[toolbar]|" options:0 metrics:nil views:rootViews]];
    [self addConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"H:|[_banner]|" options:0 metrics:nil views:rootViews]];
    [self addConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"H:|[_outputScroll]|" options:0 metrics:nil views:rootViews]];
    [self addConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"H:|[inputRow]|" options:0 metrics:nil views:rootViews]];
    [self addConstraints:[NSLayoutConstraint constraintsWithVisualFormat:
        @"V:|[toolbar(32)][_banner][_outputScroll][inputRow(28)]|" options:0 metrics:nil views:rootViews]];
}

/// Same technique as FinderPanelView's -toolbarButtonWithSymbol:tooltip:action:
/// (SF Symbol as a template image, tinted automatically for light/dark mode)
/// — deliberately not custom PNG assets; see the Finder plugin's CHANGELOG
/// 1.3.0/1.3.1 for why that was tried and reverted for panel-internal
/// buttons. Custom PNGs are only used for RunPwsh's single main
/// toolbar/menu-band icon (resources/toolbar.png, registered via
/// NPPM_ADDTOOLBARICON_FORDARKMODE in RunPwshPlugin.mm), matching how the
/// Finder plugin draws that one distinction.
- (NSButton *)toolbarButtonWithSymbol:(NSString *)symbolName tooltip:(NSString *)tooltip action:(SEL)action {
    NSButton *b = [[NSButton alloc] init];
    b.translatesAutoresizingMaskIntoConstraints = NO;
    NSImage *img = [NSImage imageWithSystemSymbolName:symbolName accessibilityDescription:tooltip];
    if (img) {
        NSImageSymbolConfiguration *cfg = [NSImageSymbolConfiguration configurationWithPointSize:14
                                                                                          weight:NSFontWeightRegular];
        img = [img imageWithSymbolConfiguration:cfg];
    }
    b.image = img;
    b.imagePosition = NSImageOnly;
    b.imageScaling = NSImageScaleProportionallyDown;
    b.bezelStyle = NSBezelStyleTexturedRounded;
    b.bordered = NO;
    b.toolTip = tooltip;
    b.target = self;
    b.action = action;
    return b;
}

#pragma mark - Localization

- (void)relocalizeUI {
    _runScriptButton.toolTip = RPLoc(@"Script ausführen", @"Run Script");
    _runSelectionButton.toolTip = RPLoc(@"Auswahl ausführen", @"Run Selection");
    _stopButton.toolTip = RPLoc(@"Vorgang beenden", @"Stop");
    _openTerminalButton.toolTip = RPLoc(@"Pwsh in Terminal starten", @"Start Pwsh in Terminal");
    _bannerInstallButton.title = RPLoc(@"Installieren via Homebrew", @"Install via Homebrew");
}

#pragma mark - Public API

- (void)appendOutputText:(NSString *)text {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self appendOutputText:text]; });
        return;
    }
    NSDictionary *attrs = @{
        NSFontAttributeName: _outputView.font,
        NSForegroundColorAttributeName: RunPwshConsoleTextColor(),
    };
    NSAttributedString *chunk = [[NSAttributedString alloc] initWithString:text attributes:attrs];
    [_outputView.textStorage appendAttributedString:chunk];
    [_outputView scrollRangeToVisible:NSMakeRange(_outputView.textStorage.length, 0)];
}

- (void)clearOutput {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self clearOutput]; });
        return;
    }
    [_outputView.textStorage setAttributedString:[[NSAttributedString alloc] initWithString:@""]];
}

- (void)setRunningState:(BOOL)running {
    _runScriptButton.enabled = !running;
    _runSelectionButton.enabled = !running;
    _openTerminalButton.enabled = !running;
    _stopButton.enabled = running;
    _stopButton.contentTintColor = running ? [NSColor systemRedColor] : [NSColor systemGrayColor];
    _inputField.enabled = running;
    if (!running) _inputField.stringValue = @"";
}

- (void)showInstallBanner:(BOOL)show reason:(nullable NSString *)reason canInstall:(BOOL)canInstall {
    if (show) {
        _bannerLabel.stringValue = reason ?: RPLoc(@"PowerShell (pwsh) wurde nicht gefunden.", @"PowerShell (pwsh) was not found.");
        _bannerInstallButton.hidden = !canInstall;
    }
    _bannerHeightConstraint.constant = show ? 40 : 0;
    _banner.hidden = !show;
    [self setNeedsLayout:YES];
}

- (void)setStatusText:(NSString *)text {
    _statusLabel.stringValue = text ?: @"";
}

#pragma mark - Actions

- (void)runScriptClicked:(id)sender {
    if ([self.delegate respondsToSelector:@selector(runPwshPanelViewDidRequestRunScript:)]) {
        [self.delegate runPwshPanelViewDidRequestRunScript:self];
    }
}

- (void)runSelectionClicked:(id)sender {
    if ([self.delegate respondsToSelector:@selector(runPwshPanelViewDidRequestRunSelection:)]) {
        [self.delegate runPwshPanelViewDidRequestRunSelection:self];
    }
}

- (void)stopClicked:(id)sender {
    if ([self.delegate respondsToSelector:@selector(runPwshPanelViewDidRequestStop:)]) {
        [self.delegate runPwshPanelViewDidRequestStop:self];
    }
}

- (void)openTerminalClicked:(id)sender {
    if ([self.delegate respondsToSelector:@selector(runPwshPanelViewDidRequestOpenTerminal:)]) {
        [self.delegate runPwshPanelViewDidRequestOpenTerminal:self];
    }
}

- (void)installClicked:(id)sender {
    if ([self.delegate respondsToSelector:@selector(runPwshPanelViewDidRequestInstallPwsh:)]) {
        [self.delegate runPwshPanelViewDidRequestInstallPwsh:self];
    }
}

- (void)inputFieldSubmitted:(id)sender {
    (void)sender;
    NSString *text = _inputField.stringValue;
    if (text.length == 0) return;
    // Echo what was typed into the console — stdin isn't a tty here, so
    // pwsh itself won't echo it back, and without this the input would
    // just silently vanish from the user's perspective.
    [self appendOutputText:[NSString stringWithFormat:@"%@\n", text]];
    if ([self.delegate respondsToSelector:@selector(runPwshPanelView:didSendInputLine:)]) {
        [self.delegate runPwshPanelView:self didSendInputLine:text];
    }
    _inputField.stringValue = @"";
}

@end

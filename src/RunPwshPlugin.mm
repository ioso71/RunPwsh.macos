/*
 * RunPwshPlugin.mm — plugin entry point for the Nextpad++ macOS "RunPwsh"
 * plugin: a PowerShell terminal panel modelled on VS Code's PowerShell
 * extension (Run Script / Run Selection / Stop / Restart Session, plus an
 * install-via-Homebrew banner when `pwsh` isn't found) built on the RunPwshEngine (process execution) and RunPwshPanelView
 * (UI) helpers in this same directory.
 *
 * This file owns the 5 mandatory C exports (setInfo, getName,
 * getFuncsArray, beNotified, messageProc) and a small ObjC controller
 * singleton that bridges the plugin ABI to RunPwshPanelView, mirroring the
 * structure of the Finder plugin (FinderPlugin.mm) in this same repo.
 *
 * ─────────────────────────────────────────────────────────────────────────
 * VERSION — single source of truth for this plugin's version number.
 * On every change, bump this, `project(RunPwsh VERSION …)` in
 * CMakeLists.txt AND the version line in README.md, and add an entry to
 * CHANGELOG.md:
 *   - Bugfix / small change   → patch (ZZ):  1.1.0 → 1.1.1
 *   - Feature / medium change → minor (Y):   1.0.10 → 1.1.0
 *   - Breaking change         → major (XX):  1.9.0 → 2.0.0
 * ───────────────────────────────────────────────────────────────────────── */
#define RUNPWSH_PLUGIN_VERSION "4.0.0"

#import <Cocoa/Cocoa.h>
#include <string.h>
#include <vector>

#include "NppPluginInterfaceMac.h"
#import "RunPwshPanelView.h"
#import "RunPwshEngine.h"
#import "RunPwshLocalization.h"
#import "RunPwshPreferences.h"

/* ─────────────────────────────────────────────────────────────────────────
 * SCNotification — minimal local mirror (same rationale as FinderPlugin.mm:
 * we only ever read notifyCode->nmhdr.code, so a full Scintilla.h dependency
 * isn't worth pulling in for this plugin).
 * ───────────────────────────────────────────────────────────────────────── */
extern "C" {
struct SCNotification {
    struct {
        void         *hwndFrom;
        uintptr_t     idFrom;
        unsigned int  code;
    } nmhdr;
};
}

/* ─────────────────────────────────────────────────────────────────────────
 * Scintilla SCI_* message numbers used to read the active selection.
 * NppPluginInterfaceMac.h deliberately doesn't vendor Scintilla.h (see
 * above), but these specific message numbers are part of Scintilla's
 * long-stable public wire protocol (unchanged since Scintilla 1.x) — safe
 * to hardcode rather than vendor the full header for four constants.
 * ───────────────────────────────────────────────────────────────────────── */
#define SCI_GETSELTEXT 2161
#define SCI_GETCURRENTPOS 2008
#define SCI_LINEFROMPOSITION 2166
#define SCI_LINELENGTH 2350
#define SCI_GETLINE 2153

NppData nppData;

/* ─────────────────────────────────────────────────────────────────────────
 * Menu command table.
 * ───────────────────────────────────────────────────────────────────────── */
#define RUNPWSH_FUNC_COUNT 5
static FuncItem gFuncItems[RUNPWSH_FUNC_COUNT];

static NSString *LocalizedFuncItemName(int idx) {
    switch (idx) {
        case 0: return RPLoc(@"RunPwsh-Panel ein-/ausblenden", @"Toggle RunPwsh Panel");
        case 1: return RPLoc(@"Script ausführen", @"Run Script");
        case 2: return RPLoc(@"Auswahl ausführen", @"Run Selection");
        case 3: return RPLoc(@"Aktuellen Befehl abbrechen", @"Interrupt current command");
        case 4: return RPLoc(@"Sitzung neu starten", @"Restart Session");
        default: return @"";
    }
}

/// Recursively searches `menu` for an NSMenuItem with the given tag (same
/// helper as FinderPlugin.mm — the host builds its Plugins menu, and
/// Tahoe's flattened variants, as nested NSMenus).
static NSMenuItem *FindMenuItemWithTag(NSMenu *menu, NSInteger tag) {
    for (NSMenuItem *item in menu.itemArray) {
        if (item.tag == tag) return item;
        if (item.submenu) {
            NSMenuItem *found = FindMenuItemWithTag(item.submenu, tag);
            if (found) return found;
        }
    }
    return nil;
}

/* ─────────────────────────────────────────────────────────────────────────
 * Controller
 * ───────────────────────────────────────────────────────────────────────── */
@interface RunPwshPluginController : NSObject <RunPwshPanelViewDelegate>
+ (instancetype)shared;
- (void)handleReady;
- (void)handleBeforeShutdown;
- (void)togglePanel;
- (void)startSessionIfNeeded;
- (void)rememberPanelVisible:(BOOL)visible;
- (void)runScriptAction;
- (void)runSelectionAction;
- (void)stopAction;
- (void)restartAction;
- (void)relocalizeMenuItems;
@end

@implementation RunPwshPluginController {
    RunPwshPanelView *_panelView;
    uintptr_t _panelHandle;
    BOOL _panelVisible;
    RunPwshPreferences *_prefs;     // remembers whether the panel was open
    BOOL _shuttingDown;             // the host hides panels on quit; that must not be saved as "closed"
    NSString *_cachedPwshPath;   // nil means "checked and not found"; re-probed each time the panel becomes visible/before a run
    BOOL _pwshChecked;
}

+ (instancetype)shared {
    static RunPwshPluginController *sInstance = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ sInstance = [[RunPwshPluginController alloc] init]; });
    return sInstance;
}

#pragma mark - nppData helpers

/// Reads the active buffer's full path via NPPM_GETFULLCURRENTPATH. Returns
/// nil if there is no active/unsaved-untitled buffer.
- (nullable NSString *)currentFilePath {
    char buf[4096] = {0};
    nppData._sendMessage(nppData._nppHandle, NPPM_GETFULLCURRENTPATH, 0, (intptr_t)buf);
    if (buf[0] == '\0') return nil;
    return [NSString stringWithUTF8String:buf];
}

/// The Scintilla handle backing whichever editor view (main/second) is
/// currently active — mirrors the standard Notepad++ plugin idiom for
/// NPPM_GETCURRENTSCINTILLA (wParam unused, lParam is an int* that receives
/// 0 for the main view or 1 for the second view).
- (NppHandle)currentScintillaHandle {
    int which = 0;
    nppData._sendMessage(nppData._nppHandle, NPPM_GETCURRENTSCINTILLA, 0, (intptr_t)&which);
    return which == 1 ? nppData._scintillaSecondHandle : nppData._scintillaMainHandle;
}

/// Current selection text in the active editor, or nil if there is none.
- (nullable NSString *)currentSelectionText {
    NppHandle sci = [self currentScintillaHandle];
    intptr_t len = nppData._sendMessage(sci, SCI_GETSELTEXT, 0, 0);
    if (len <= 1) return nil; // Scintilla includes the NUL terminator in the reported length
    std::vector<char> buf((size_t)len);
    nppData._sendMessage(sci, SCI_GETSELTEXT, 0, (intptr_t)buf.data());
    NSString *text = [NSString stringWithUTF8String:buf.data()];
    return text.length > 0 ? text : nil;
}

/// The current line's text (trimmed of its trailing newline and any leading/
/// trailing whitespace), or nil if the line is empty/whitespace-only.
/// "Auswahl ausführen"/Run Selection falls back to this when there's no
/// selection — just clicking the cursor into a line and pressing the button
/// should run that line, matching the real PowerShell ISE's F8 behavior,
/// rather than printing "no selection" and doing nothing.
///
/// Deliberately NOT using SCI_GETCURLINE here (v3.1.0's first attempt did,
/// and it didn't work): that message's return value is documented to be the
/// *caret's column position within the line*, not the number of bytes
/// copied/needed — a well-known Scintilla API gotcha. That meant our
/// `len <= 1` "is there any text" check was actually checking "is the caret
/// within the first byte of the line", which is true (and so wrongly
/// bailed out) almost any time the caret sits near the start of a line.
/// SCI_GETLINE (given an explicit line number from SCI_LINEFROMPOSITION)
/// does not have this quirk and returns the actual copied length.
- (nullable NSString *)currentLineText {
    NppHandle sci = [self currentScintillaHandle];
    intptr_t pos = nppData._sendMessage(sci, SCI_GETCURRENTPOS, 0, 0);
    intptr_t line = nppData._sendMessage(sci, SCI_LINEFROMPOSITION, (uintptr_t)pos, 0);
    intptr_t lineLen = nppData._sendMessage(sci, SCI_LINELENGTH, (uintptr_t)line, 0);
    if (lineLen <= 0) return nil;
    std::vector<char> buf((size_t)lineLen + 1, 0);
    nppData._sendMessage(sci, SCI_GETLINE, (uintptr_t)line, (intptr_t)buf.data());
    NSString *text = [NSString stringWithUTF8String:buf.data()];
    NSString *trimmed = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return trimmed.length > 0 ? trimmed : nil;
}

#pragma mark - Panel lifecycle

- (void)ensurePanelCreated {
    if (_panelView) return;

    if (!_prefs) {
        char configBuf[1024] = {0};
        nppData._sendMessage(nppData._nppHandle, NPPM_GETPLUGINSCONFIGDIR, 1024, (intptr_t)configBuf);
        _prefs = [[RunPwshPreferences alloc] initWithConfigDirectory:
            configBuf[0] ? [NSString stringWithUTF8String:configBuf] : @""];
    }

    _panelView = [[RunPwshPanelView alloc] initWithFrame:NSMakeRect(0, 0, 320, 260)];
    _panelView.delegate = self;

    uintptr_t handle = (uintptr_t)nppData._sendMessage(
        nppData._nppHandle, NPPM_DMM_REGISTERPANEL,
        (uintptr_t)(__bridge void *)_panelView, (intptr_t)"RunPwsh");
    _panelHandle = handle;

    if (_panelHandle == 0) {
        NSLog(@"[RunPwsh plugin] NPPM_DMM_REGISTERPANEL failed — host may predate panel docking support (< 1.0.3). Panel will not be available.");
    }

    [self refreshPwshStatus];
}

- (void)handleReady {
    [self ensurePanelCreated];

    [RunPwshLocalization observeLanguageChangesWithBlock:^{
        [[RunPwshPluginController shared] relocalizeMenuItems];
    }];

    if (!_panelHandle) return;

    // The panel is only reopened if it was open when the user last changed
    // it; a closed panel stays closed, and no pwsh is started for it.
    if (!_prefs.panelWasVisible) return;

    // Deferred by one runloop tick: see FinderPlugin.mm's -handleReady for
    // the exact race this avoids (NPPN_READY firing before the main
    // window's split-view geometry has settled on first launch).
    dispatch_async(dispatch_get_main_queue(), ^{
        intptr_t result = nppData._sendMessage(nppData._nppHandle, NPPM_DMM_SHOWPANEL, self->_panelHandle, 0);
        self->_panelVisible = (result != 0);
        if (self->_panelVisible) {
            // No focusTerminal here: at app launch the editor keeps the focus.
            [self startSessionIfNeeded];
        }
    });
}

- (void)relocalizeMenuItems {
    for (int i = 0; i < RUNPWSH_FUNC_COUNT; i++) {
        NSString *title = LocalizedFuncItemName(i);
        strlcpy(gFuncItems[i]._itemName, title.UTF8String, NPP_MENU_ITEM_SIZE);
        NSMenuItem *item = FindMenuItemWithTag(NSApp.mainMenu, (NSInteger)gFuncItems[i]._cmdID);
        if (item) item.title = title;
    }
}

- (void)handleBeforeShutdown {
    _shuttingDown = YES;   // the host may hide the panel while quitting; keep the saved state
    [_panelView terminateSession];
    if (_panelHandle) {
        nppData._sendMessage(nppData._nppHandle, NPPM_DMM_UNREGISTERPANEL, _panelHandle, 0);
        _panelHandle = 0;
    }
}

- (void)togglePanel {
    [self ensurePanelCreated];
    if (!_panelHandle) return;

    if (_panelVisible) {
        nppData._sendMessage(nppData._nppHandle, NPPM_DMM_HIDEPANEL, _panelHandle, 0);
    } else {
        nppData._sendMessage(nppData._nppHandle, NPPM_DMM_SHOWPANEL, _panelHandle, 0);
        [self startSessionIfNeeded];
        [_panelView focusTerminal];
    }
    _panelVisible = !_panelVisible;
    [self rememberPanelVisible:_panelVisible];
}

/// Persists the panel state right away (not only at quit), so a crash or a
/// forced quit cannot lose it.
- (void)rememberPanelVisible:(BOOL)visible {
    if (_shuttingDown) return;
    [_prefs setPanelWasVisible:visible];
}

/// The host hides the panel (X button, Toggle, NPPM_DMM_HIDEPANEL).
- (void)runPwshPanelViewWillClose:(RunPwshPanelView *)view {
    (void)view;
    _panelVisible = NO;           // also fixes the drift after the X button
    [self rememberPanelVisible:NO];
}

/// Ensures the panel is created + visible, e.g. before showing run output —
/// matches the ISE's own behavior of surfacing its console pane the moment
/// something is run.
- (void)ensurePanelShown {
    [self ensurePanelCreated];
    if (_panelHandle && !_panelVisible) {
        nppData._sendMessage(nppData._nppHandle, NPPM_DMM_SHOWPANEL, _panelHandle, 0);
        _panelVisible = YES;
        [self rememberPanelVisible:YES];
        [_panelView focusTerminal];
    }
    [self startSessionIfNeeded];
}

/// Starts pwsh as soon as the panel is visible (unless it is already alive
/// or pwsh is missing — then the install banner is shown instead).
- (void)startSessionIfNeeded {
    [self refreshPwshStatus];
    if (!_cachedPwshPath) return;
    if (_panelView.sessionAlive) return;
    [_panelView startSessionWithExecutable:_cachedPwshPath];
}

#pragma mark - pwsh / brew detection

- (void)refreshPwshStatus {
    NSString *path = [RunPwshEngine findPwshPath];
    _cachedPwshPath = path;
    _pwshChecked = YES;

    if (path) {
        [_panelView showInstallBanner:NO reason:nil canInstall:NO];
        [_panelView setStatusText:[NSString stringWithFormat:@"pwsh: %@", path]];
    } else {
        NSString *brew = [RunPwshEngine findBrewPath];
        if (brew) {
            [_panelView showInstallBanner:YES
                                    reason:RPLoc(@"PowerShell (pwsh) wurde nicht gefunden.", @"PowerShell (pwsh) was not found.")
                                canInstall:YES];
        } else {
            [_panelView showInstallBanner:YES
                                    reason:RPLoc(@"PowerShell (pwsh) und Homebrew wurden nicht gefunden. Bitte Homebrew von brew.sh installieren.",
                                                 @"Neither PowerShell (pwsh) nor Homebrew was found. Please install Homebrew from brew.sh first.")
                                canInstall:NO];
        }
        [_panelView setStatusText:RPLoc(@"pwsh nicht gefunden", @"pwsh not found")];
    }
}

#pragma mark - Run actions

/// Doubles single quotes so `path` can be dropped safely into a PowerShell
/// single-quoted string literal (`'...'`) — single-quoted strings don't
/// support backtick escapes, only `''` for a literal `'`.
static NSString *RunPwshEscapeSingleQuoted(NSString *path) {
    return [path stringByReplacingOccurrencesOfString:@"'" withString:@"''"];
}

- (void)runScriptAction {
    [self ensurePanelShown];
    if (!_cachedPwshPath) { [self refreshPwshStatus]; return; }

    // Auto-save first (matches PowerShell ISE's F5 behavior): the executed
    // .ps1 should always reflect what's currently in the editor. On an
    // untitled buffer this triggers the host's Save As dialog; if the user
    // cancels it, the path below still comes back empty.
    nppData._sendMessage(nppData._nppHandle, NPPM_SAVECURRENTFILE, 0, 0);

    NSString *path = [self currentFilePath];
    if (!path) {
        [_panelView feedText:RPLoc(@"Bitte zuerst eine Datei speichern.\n", @"Please save a file first.\n")];
        return;
    }

    NSString *cwd = [path stringByDeletingLastPathComponent];

    // Dot-sourced (". 'path'"), not "& 'path'": a plain call would run the
    // script in its own child scope, so variables/functions it defines
    // would not survive in the session. `Set-Location` first so relative
    // paths inside the script resolve against the script's own folder.
    NSString *command = [NSString stringWithFormat:@"Set-Location -LiteralPath '%@'; . '%@'",
        RunPwshEscapeSingleQuoted(cwd), RunPwshEscapeSingleQuoted(path)];
    [_panelView runText:command];
}

- (void)runSelectionAction {
    [self ensurePanelShown];
    if (!_cachedPwshPath) { [self refreshPwshStatus]; return; }

    // Falls back to the current line if there is no selection (VS Code F8 /
    // PowerShell ISE behavior).
    NSString *toRun = [self currentSelectionText] ?: [self currentLineText];
    if (!toRun) {
        [_panelView feedText:RPLoc(@"Keine Auswahl und keine aktuelle Zeile vorhanden.\n", @"No selection and no current line.\n")];
        return;
    }
    [_panelView runText:toRun];
}

- (void)stopAction {
    [_panelView interruptSession];
}

- (void)restartAction {
    [self ensurePanelCreated];
    [self refreshPwshStatus];
    if (!_cachedPwshPath) return;
    // Show the panel without auto-starting: restarting an Ended session must
    // start exactly one process, and restarting a live one must not spawn a
    // second process that is killed again right away.
    if (_panelHandle && !_panelVisible) {
        nppData._sendMessage(nppData._nppHandle, NPPM_DMM_SHOWPANEL, _panelHandle, 0);
        _panelVisible = YES;
        [self rememberPanelVisible:YES];
    }
    if (_panelView.sessionAlive) {
        [_panelView restartSession];
    } else {
        [_panelView startSessionWithExecutable:_cachedPwshPath];
    }
    [_panelView focusTerminal];
}

- (void)installPwshAction {
    NSString *brew = [RunPwshEngine findBrewPath];
    if (!brew) return; // banner already reflects "install Homebrew manually" in this case
    if (_panelView.sessionAlive) return;
    [_panelView feedText:RPLoc(@"Installiere PowerShell via Homebrew…\n", @"Installing PowerShell via Homebrew…\n")];
    [_panelView setSessionActive:YES];
    __weak RunPwshPluginController *weakSelf = self;
    [RunPwshEngine installPwshViaHomebrew:brew
                                     output:^(NSString *text) {
        RunPwshPluginController *strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf->_panelView feedText:text];
    } completion:^(BOOL success) {
        RunPwshPluginController *strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf->_panelView setSessionActive:NO];
        [strongSelf->_panelView feedText:success
            ? RPLoc(@"\nInstallation abgeschlossen.\n", @"\nInstallation finished.\n")
            : RPLoc(@"\nInstallation fehlgeschlagen.\n", @"\nInstallation failed.\n")];
        [strongSelf refreshPwshStatus];
        if (success) [strongSelf startSessionIfNeeded];
    }];
}

#pragma mark - RunPwshPanelViewDelegate

- (void)runPwshPanelViewDidRequestRunScript:(RunPwshPanelView *)view { (void)view; [self runScriptAction]; }
- (void)runPwshPanelViewDidRequestRunSelection:(RunPwshPanelView *)view { (void)view; [self runSelectionAction]; }
- (void)runPwshPanelViewDidRequestStop:(RunPwshPanelView *)view { (void)view; [self stopAction]; }
- (void)runPwshPanelViewDidRequestRestart:(RunPwshPanelView *)view { (void)view; [self restartAction]; }
- (void)runPwshPanelViewDidRequestInstallPwsh:(RunPwshPanelView *)view { (void)view; [self installPwshAction]; }


@end

/* ─────────────────────────────────────────────────────────────────────────
 * Plugin command callbacks (plain C function pointers, no captured context).
 * ───────────────────────────────────────────────────────────────────────── */

static void Cmd_TogglePanel(void)    { [[RunPwshPluginController shared] togglePanel]; }
static void Cmd_RunScript(void)      { [[RunPwshPluginController shared] runScriptAction]; }
static void Cmd_RunSelection(void)   { [[RunPwshPluginController shared] runSelectionAction]; }
static void Cmd_Stop(void)           { [[RunPwshPluginController shared] stopAction]; }
static void Cmd_Restart(void)        { [[RunPwshPluginController shared] restartAction]; }

extern "C" {

NPP_EXPORT void setInfo(struct NppData data) {
    nppData = data;

    memset(gFuncItems, 0, sizeof(gFuncItems));

    strlcpy(gFuncItems[0]._itemName, LocalizedFuncItemName(0).UTF8String, NPP_MENU_ITEM_SIZE);
    gFuncItems[0]._pFunc = Cmd_TogglePanel;

    strlcpy(gFuncItems[1]._itemName, LocalizedFuncItemName(1).UTF8String, NPP_MENU_ITEM_SIZE);
    gFuncItems[1]._pFunc = Cmd_RunScript;

    strlcpy(gFuncItems[2]._itemName, LocalizedFuncItemName(2).UTF8String, NPP_MENU_ITEM_SIZE);
    gFuncItems[2]._pFunc = Cmd_RunSelection;

    strlcpy(gFuncItems[3]._itemName, LocalizedFuncItemName(3).UTF8String, NPP_MENU_ITEM_SIZE);
    gFuncItems[3]._pFunc = Cmd_Stop;

    strlcpy(gFuncItems[4]._itemName, LocalizedFuncItemName(4).UTF8String, NPP_MENU_ITEM_SIZE);
    gFuncItems[4]._pFunc = Cmd_Restart;
}

NPP_EXPORT const char *getName(void) {
    return "RunPwsh";
}

NPP_EXPORT struct FuncItem *getFuncsArray(int *nbF) {
    *nbF = RUNPWSH_FUNC_COUNT;
    return gFuncItems;
}

NPP_EXPORT void beNotified(struct SCNotification *notifyCode) {
    if (!notifyCode) return;
    switch (notifyCode->nmhdr.code) {
        case NPPN_READY:
            [[RunPwshPluginController shared] handleReady];
            // Registers the single main toolbar/menu-band icon for the
            // "toggle panel" command. lParam=NULL → host falls back to its
            // default lookup convention (toolbar.png / toolbar_dark.png in
            // the plugin's resources/ directory) — same convention as the
            // Finder plugin's one main icon.
            nppData._sendMessage(nppData._nppHandle, NPPM_ADDTOOLBARICON_FORDARKMODE,
                                  (uintptr_t)gFuncItems[0]._cmdID, (intptr_t)NULL);
            break;
        case NPPN_BEFORESHUTDOWN:
            [[RunPwshPluginController shared] handleBeforeShutdown];
            break;
        default:
            break;
    }
}

NPP_EXPORT intptr_t messageProc(uint32_t Message, uintptr_t wParam, intptr_t lParam) {
    (void)Message;
    (void)wParam;
    (void)lParam;
    return 0;
}

} /* extern "C" */

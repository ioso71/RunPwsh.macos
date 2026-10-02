// RunPwshTerminalBridge.swift
//
// Thin @objc wrapper around SwiftTerm's LocalProcessTerminalView so
// RunPwshPanelView.mm (Objective-C++) can embed a *real* terminal widget:
// full VT100/ANSI escape-sequence rendering, and — the actual point of this
// whole rewrite — the user types directly into the terminal's own NSView
// (arrow keys, tab-completion, line history all forwarded live to the pty by
// SwiftTerm itself), instead of a separate read-only console + narrow input
// field below it.
//
// v2.0.1 confirmed the public API used here against the real SwiftTerm 1.2.0
// source (swift/RunPwshTerminalBridge/.build/checkouts/SwiftTerm/Sources/
// SwiftTerm/Mac/MacLocalTerminalView.swift): `startProcess(executable:args:
// environment:execName:)`, `feed(text:)`, and the
// `LocalProcessTerminalViewDelegate` signatures below all matched exactly;
// only `killSession()` (then named `stopProcess()`) needed a fix, since
// `LocalProcessTerminalView.process` turned out to be `internal`, not
// `public` — see its doc comment for the `Mirror`-based workaround.
//
// v3.0.0 added `typeText(_:)` and `interrupt()` to support a *persistent*
// session model: instead of one `pwsh -File script.ps1` process spawned per
// "Run Script"/"Run Selection" click (and thrown away on exit), the panel
// now starts a single long-lived interactive `pwsh` once and keeps typing
// commands into it — so `$variables` and functions survive across runs, the
// way the real PowerShell ISE behaves. `typeText` reuses the same
// `send(source:data:)` plumbing `killSession()`'s Ctrl+C fallback already
// used, generalized to arbitrary text; `interrupt()` is that same Ctrl+C
// path exposed as the (non-destructive) "Stop" action, while `killSession()`
// remains the destructive SIGTERM/SIGKILL path for actually ending the
// session. The public @objc surface at the bottom of this file (start/
// typeText/interrupt/killSession/feed/onProcessExited) is the contract
// RunPwshPanelView.mm relies on and stays stable regardless of internal
// SwiftTerm-facing adjustments.
import AppKit
import Foundation
import SwiftTerm

@objc(RunPwshTerminalBridge)
public class RunPwshTerminalBridge: NSObject {

    /// The actual NSView to embed in RunPwshPanelView — an AppKit
    /// LocalProcessTerminalView, which is-a NSView subclass that already
    /// handles its own keyDown/scrolling/selection.
    @objc public let view: NSView

    private let terminalView: LocalProcessTerminalView
    private let delegateBridge: DelegateBridge

    /// Called once the child process exits, with its exit code. Always on
    /// the main thread (SwiftTerm's own delegate callbacks already are, but
    /// this is stated explicitly since RunPwshPanelView.mm updates UI from
    /// it directly without re-dispatching).
    @objc public var onProcessExited: ((Int32) -> Void)?

    /// Called (main thread) each time pwsh prints a prompt (OSC 7).
    @objc public var onPrompt: (() -> Void)?

    private var clickMonitor: Any?

    /// Gives the terminal keyboard focus.
    @objc public func focus() {
        terminalView.window?.makeFirstResponder(terminalView)
    }

    @objc public override init() {
        let tv = LocalProcessTerminalView(frame: .zero)
        // On German and many other macOS keyboard layouts, Option is needed
        // to compose ordinary characters such as `~` (Option+N, then Space).
        // SwiftTerm defaults this to a terminal Meta key, which sends ESC+n
        // instead and can let the following key combination interfere with
        // the host application's shortcuts. Prefer native text input here.
        tv.optionAsMetaKey = false
        terminalView = tv
        view = tv
        let bridge = DelegateBridge()
        delegateBridge = bridge
        super.init()
        bridge.owner = self
        tv.processDelegate = bridge
        // SwiftTerm 1.2.0 never makes the view first responder on click, and
        // LocalProcessTerminalView is not `open`, so it cannot be subclassed.
        // A local monitor gives it focus when the click lands on it.
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak tv] event in
            if let tv = tv, let win = tv.window, event.window === win {
                let p = tv.convert(event.locationInWindow, from: nil)
                if tv.bounds.contains(p), win.firstResponder !== tv { win.makeFirstResponder(tv) }
            }
            return event
        }
    }

    deinit {
        if let m = clickMonitor { NSEvent.removeMonitor(m) }
    }

    /// Starts `executable` with `args` attached to the terminal's own pty.
    /// `currentDirectory`, if given, is applied by briefly chdir'ing this
    /// process to it immediately before spawning and restoring the previous
    /// cwd right after — LocalProcessTerminalView.startProcess doesn't take
    /// an explicit working-directory parameter in every SwiftTerm version,
    /// but a freshly-fork()'d child always inherits the parent's cwd at fork
    /// time, so this narrow synchronous window is a safe, version-independent
    /// way to get the same effect without depending on that parameter
    /// existing.
    @objc public func start(executable: String, args: [String], currentDirectory: String?) {
        let fm = FileManager.default
        let previousCwd = fm.currentDirectoryPath
        if let cwd = currentDirectory, !cwd.isEmpty {
            _ = fm.changeCurrentDirectoryPath(cwd)
        }
        terminalView.startProcess(executable: executable, args: args, environment: nil, execName: nil)
        if currentDirectory != nil {
            _ = fm.changeCurrentDirectoryPath(previousCwd)
        }
    }

    /// Feeds `text` into the terminal as if it had been read from the child
    /// process (used for the "[Finished with exit code N]" banner this
    /// plugin prints after a run — SwiftTerm has no separate "your own
    /// annotation" channel, so this goes through the same rendering path as
    /// real process output, `\r\n` for a fresh line).
    @objc public func feed(text: String) {
        terminalView.feed(text: text)
    }

    /// Types `text` into the terminal exactly as if the user had typed it
    /// themselves — unlike `feed(text:)` (which only *renders* text, as if
    /// the child process had printed it), this actually writes the bytes to
    /// the pty's master fd via SwiftTerm's own `send(source:data:)`, the same
    /// path `TerminalView` calls on every real keystroke. The pty's line
    /// discipline echoes it back for display on its own (so it shows up in
    /// the terminal without a separate `feed` call), and the child process
    /// receives it on its stdin. This is what lets "Run Script"/"Run
    /// Selection" (v3.0.0) reuse one persistent interactive session instead
    /// of spawning a fresh throwaway process per run: the code is typed into
    /// the already-running `pwsh`, so `$variables`/functions it defines stay
    /// alive for the next run, same as typing them by hand. Does not append
    /// a trailing newline — pass `"\n"`/`"\r"` explicitly if the text should
    /// execute immediately (RunPwshPanelView's `-runText:` does this).
    @objc public func typeText(_ text: String) {
        let bytes = Array(text.utf8)
        terminalView.send(source: terminalView, data: bytes[...])
    }

    /// Sends Ctrl+C (0x03) through the pty, interrupting whatever is
    /// currently running in the session without ending the session itself —
    /// the persistent-session-model "Stop" action (v3.0.0): unlike
    /// `killSession()` below, the interactive `pwsh` process (and everything
    /// defined in it so far) survives, exactly like pressing Ctrl+C in any
    /// real terminal only cancels the foreground command.
    @objc public func interrupt() {
        let ctrlC: [UInt8] = [0x03]
        terminalView.send(source: terminalView, data: ctrlC[...])
    }

    /// Sends SIGTERM (then, after a short grace period, SIGKILL) to the
    /// session's `pwsh` process, ending it outright — used by the "New
    /// Session" action (v3.0.0) and on plugin shutdown. A later "Run
    /// Script"/"Run Selection" call will lazily start a brand-new session
    /// via `start(executable:args:currentDirectory:)`.
    ///
    /// Confirmed against the real SwiftTerm 1.2.0 source (Mac/
    /// MacLocalTerminalView.swift): `LocalProcessTerminalView.process` (a
    /// `LocalProcess`, which itself has a fully `public` `shellPid`/
    /// `terminate()`/`running`) is declared `internal` with no access
    /// modifier, so it can't be reached directly from this separate SwiftPM
    /// module — that's the exact compile error `swift build` produced. There
    /// is no other public API on LocalProcessTerminalView that exposes the
    /// child's pid or a terminate/kill call.
    ///
    /// `Mirror(reflecting:)` can still read a stored property's value
    /// regardless of its access level (this is standard, documented Swift
    /// reflection behavior, not a hack around memory safety) — used here to
    /// pull out the underlying `LocalProcess` and call its public
    /// `shellPid`/`terminate()` normally. If a future SwiftTerm version ever
    /// renames or removes that stored property, this silently falls back to
    /// sending Ctrl+C (0x03) — a softer stop, but still works without
    /// needing the pid at all.
    @objc public func killSession() {
        if let process = underlyingLocalProcess() {
            let pid = process.shellPid
            if pid > 0 {
                kill(pid, SIGTERM)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    // Only escalate if it's still around — kill(pid, 0)
                    // succeeds iff the pid still exists (and we're allowed
                    // to signal it).
                    if kill(pid, 0) == 0 {
                        kill(pid, SIGKILL)
                    }
                }
                return
            }
        }
        interrupt()
    }

    /// Reaches into `terminalView`'s internal `process: LocalProcess!`
    /// stored property via reflection (see doc comment on `stopProcess()`
    /// above for why this is necessary and safe).
    private func underlyingLocalProcess() -> LocalProcess? {
        for child in Mirror(reflecting: terminalView).children {
            if child.label == "process", let process = child.value as? LocalProcess {
                return process
            }
        }
        return nil
    }

    /// Forwards a resize (e.g. the panel view's own frame changing) to the
    /// pty so full-screen/curses-style redraws stay correctly sized. Not
    /// currently wired up from RunPwshPanelView.mm (the terminal view's own
    /// Auto Layout resize already triggers SwiftTerm's internal handling via
    /// -[NSView setFrameSize:]), kept as an explicit escape hatch.
    @objc public func resize() {
        // Intentionally empty: LocalProcessTerminalView already reacts to
        // -setFrameSize: itself. See doc comment above.
    }

    // MARK: - SwiftTerm delegate plumbing

    /// Separate NSObject rather than making RunPwshTerminalBridge itself
    /// conform to LocalProcessTerminalViewDelegate: keeps the delegate
    /// protocol's (SwiftTerm-typed) methods out of this class's @objc
    /// surface, since Obj-C++ callers never need to see them directly.
    private class DelegateBridge: NSObject, LocalProcessTerminalViewDelegate {
        weak var owner: RunPwshTerminalBridge?

        func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
            owner?.onPrompt?()
        }

        func processTerminated(source: TerminalView, exitCode: Int32?) {
            owner?.onProcessExited?(exitCode ?? 0)
        }
    }
}

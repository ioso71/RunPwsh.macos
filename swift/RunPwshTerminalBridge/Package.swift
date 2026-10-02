// swift-tools-version:5.7
//
// RunPwshTerminalBridge — thin Swift/Obj-C bridge around SwiftTerm's
// LocalProcessTerminalView, so the (Objective-C++) RunPwsh plugin can embed a
// real terminal widget instead of a read-only NSTextView + separate input
// field. Built as its own SwiftPM package (not folded into the main CMake
// ObjC++ target) because CMake's native Swift language support is flaky
// outside Xcode's own toolchain; the main CMakeLists.txt instead shells out
// to `swift build` for this package as a custom pre-build step and links the
// resulting dynamic library — see the "Swift terminal bridge" section in
// ../../CMakeLists.txt.
//
// IMPORTANT (see README.md "Building" + CHANGELOG 2.0.0): this file pins an
// exact SwiftTerm version/commit. If SwiftTerm's LocalProcessTerminalView API
// has shifted since (method/parameter names in RunPwshTerminalBridge.swift
// were written from memory of the library, not against a checked-out copy —
// this sandbox has no network access to verify against the real source), the
// first `swift build` on a real Mac is where that will surface as a compile
// error; fix the call sites in RunPwshTerminalBridge.swift to match whatever
// the pinned version actually exposes.
import PackageDescription

let package = Package(
    name: "RunPwshTerminalBridge",
    platforms: [.macOS(.v11)],
    products: [
        // Dynamic library so the ObjC++ plugin dylib can link/dlopen it at
        // runtime rather than needing to statically re-link Swift's runtime
        // into a MODULE library (which -Wl,-undefined,dynamic_lookup makes
        // awkward). See CMakeLists.txt's "install_plugin" target: this
        // library is copied next to RunPwsh.dylib and found via @loader_path.
        .library(name: "RunPwshTerminalBridge", type: .dynamic, targets: ["RunPwshTerminalBridge"]),
    ],
    dependencies: [
        // Pinned to a specific tag rather than a branch/range so a future
        // SwiftTerm release can't silently change the API surface this
        // bridge depends on. Bump deliberately (and re-check
        // RunPwshTerminalBridge.swift against the new source) if ever
        // updated — do not just widen this to `from:`.
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.2.0"),
    ],
    targets: [
        .target(
            name: "RunPwshTerminalBridge",
            dependencies: [.product(name: "SwiftTerm", package: "SwiftTerm")],
            swiftSettings: [
                // Generates an Obj-C compatibility header
                // (.build/.../RunPwshTerminalBridge-Swift.h) that
                // RunPwshPanelView.mm imports directly — the whole point of
                // this package. Requires every @objc-exposed symbol in
                // RunPwshTerminalBridge.swift to be reachable from Obj-C
                // (NSObject subclass, @objc members only using
                // Obj-C-representable types).
                .unsafeFlags([
                    "-emit-objc-header-path",
                    "\(URL(fileURLWithPath: #filePath).deletingLastPathComponent().path)/include/RunPwshTerminalBridge-Swift.h",
                ])
            ]
        ),
    ]
)

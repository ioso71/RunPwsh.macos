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
// IMPORTANT: this file pins an exact SwiftTerm version. The call sites in
// RunPwshTerminalBridge.swift were checked against the real 1.2.0 source
// (v2.0.1); if the pin is ever bumped, re-check them against the new source.
import PackageDescription

let package = Package(
    name: "RunPwshTerminalBridge",
    platforms: [.macOS(.v12)],
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

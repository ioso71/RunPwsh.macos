cmake_minimum_required(VERSION 3.20)
project(RunPwsh VERSION 4.0.0 LANGUAGES OBJCXX CXX)

# -----------------------------------------------------------------------------
# Nextpad++ "RunPwsh" plugin
#
# A PowerShell-ISE-like panel: run the current script or the current
# selection through pwsh, see live output, stop a running script, jump to an
# interactive pwsh session in Terminal, and (if pwsh isn't installed yet)
# install it via Homebrew with one click. Uses the same
# NppPluginInterfaceMac.h ABI as the Finder plugin (vendored under vendor/,
# see vendor/README.md).
#
# No third-party dependencies: only Apple system frameworks (Cocoa,
# Foundation) plus the C++/Foundation standard library. Same toolchain
# conventions as the host app and the Finder plugin (CMake, ObjC++, ARC on
# .mm files).
# -----------------------------------------------------------------------------

if(NOT APPLE)
    message(FATAL_ERROR "The RunPwsh plugin only builds on macOS (uses Cocoa/AppKit).")
endif()

set(CMAKE_AR /usr/bin/ar)
set(CMAKE_RANLIB /usr/bin/ranlib)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_OBJCXX_STANDARD 17)
# 12.0, not 11.0: the Swift bridge (SwiftPM, Swift 6.x toolchain) is built with a
# minimum of macOS 12.0, and linking a 11.0 plugin against it only produced an
# "built for newer version 12.0" linker warning while promising macOS 11.
set(CMAKE_OSX_DEPLOYMENT_TARGET "12.0")
if(NOT CMAKE_OSX_ARCHITECTURES)
    set(CMAKE_OSX_ARCHITECTURES "arm64;x86_64")
endif()

set(RUNPWSH_SRCS
    src/RunPwshPlugin.mm
    src/RunPwshPanelView.mm
    src/RunPwshEngine.mm
    src/RunPwshLocalization.mm
    src/RunPwshSession.mm
    src/RunPwshPreferences.mm
)

set(RUNPWSH_HDRS
    vendor/NppPluginInterfaceMac.h
    src/RunPwshPanelView.h
    src/RunPwshEngine.h
    src/RunPwshLocalization.h
    src/RunPwshSession.h
    src/RunPwshPreferences.h
)

# -----------------------------------------------------------------------------
# Swift terminal bridge (SwiftTerm) — see swift/RunPwshTerminalBridge/.
#
# Since v2.0.0 the panel embeds a real terminal widget (SwiftTerm's
# LocalProcessTerminalView) instead of a read-only NSTextView + separate
# input field, so typing happens directly in the console — this was the
# whole point of that version. SwiftTerm is Swift, and CMake's built-in
# `enable_language(Swift)` support is unreliable outside Xcode's own
# generator, so instead of teaching this ObjC++ CMake project to compile
# Swift itself, the bridge is its own tiny SwiftPM package that we just shell
# out to `swift build` for, then link the resulting dylib into RunPwsh.dylib
# like any other pre-built library.
#
# Requires the Swift toolchain (ships with Xcode/Command Line Tools) and
# network access the first time (SwiftPM fetches the SwiftTerm dependency).
find_program(SWIFT_EXECUTABLE swift REQUIRED)
find_program(LIPO_EXECUTABLE lipo REQUIRED)

set(RUNPWSH_SWIFT_PKG_DIR "${CMAKE_SOURCE_DIR}/swift/RunPwshTerminalBridge")
set(RUNPWSH_SWIFT_HEADER_DIR "${RUNPWSH_SWIFT_PKG_DIR}/include")

# `swift build` with no --arch flag only ever builds for the *host*
# architecture (arm64 on Apple Silicon) — plain single-arch output at
# .build/release/. That silently mismatched RunPwsh.dylib itself, which
# CMAKE_OSX_ARCHITECTURES above builds universal (arm64;x86_64): the linker
# only warned ("ignoring file ... found architecture 'arm64', required
# architecture 'x86_64'") rather than failing outright, because
# -undefined,dynamic_lookup (see LINK_FLAGS below) defers symbol resolution
# — so it built "successfully" while quietly producing an x86_64 slice of
# RunPwsh.dylib that can never actually find/load its Swift bridge at
# runtime. Fixed by building each architecture explicitly
# (`--arch arm64`/`--arch x86_64`, each landing in SwiftPM's own
# per-triple `.build/<arch>-apple-macosx/release/` directory) and combining
# them with `lipo` into a genuinely universal dylib ourselves, mirroring
# what CMAKE_OSX_ARCHITECTURES already does for RunPwsh.dylib.
set(RUNPWSH_SWIFT_ARM64_DYLIB "${RUNPWSH_SWIFT_PKG_DIR}/.build/arm64-apple-macosx/release/libRunPwshTerminalBridge.dylib")
set(RUNPWSH_SWIFT_X86_64_DYLIB "${RUNPWSH_SWIFT_PKG_DIR}/.build/x86_64-apple-macosx/release/libRunPwshTerminalBridge.dylib")
set(RUNPWSH_SWIFT_UNIVERSAL_DIR "${RUNPWSH_SWIFT_PKG_DIR}/.build/universal")
set(RUNPWSH_SWIFT_DYLIB "${RUNPWSH_SWIFT_UNIVERSAL_DIR}/libRunPwshTerminalBridge.dylib")

# `--build-system native`: since Swift 6.4 the default build system
# (`swiftbuild`) no longer writes the Obj-C compatibility header to the
# `-emit-objc-header-path` given in Package.swift, so include/
# RunPwshTerminalBridge-Swift.h silently stayed at its old contents and new
# @objc members were invisible to the .mm files. `native` still honours the
# flag. It is marked deprecated by SwiftPM; revisit when it is removed.
# Always invoked (no explicit output-timestamp tracking against the Swift
# sources) — `swift build` already does its own incremental-build caching,
# so this just re-asks it every CMake build and it's a fast no-op when
# nothing changed. Simpler/more robust than trying to mirror SwiftPM's own
# dependency graph in CMake.
add_custom_target(RunPwshTerminalBridge_swiftbuild
    COMMAND "${SWIFT_EXECUTABLE}" build -c release --build-system native --arch arm64 --package-path "${RUNPWSH_SWIFT_PKG_DIR}"
    COMMAND "${SWIFT_EXECUTABLE}" build -c release --build-system native --arch x86_64 --package-path "${RUNPWSH_SWIFT_PKG_DIR}"
    COMMAND ${CMAKE_COMMAND} -E make_directory "${RUNPWSH_SWIFT_UNIVERSAL_DIR}"
    COMMAND "${LIPO_EXECUTABLE}" -create -output "${RUNPWSH_SWIFT_DYLIB}" "${RUNPWSH_SWIFT_ARM64_DYLIB}" "${RUNPWSH_SWIFT_X86_64_DYLIB}"
    BYPRODUCTS "${RUNPWSH_SWIFT_DYLIB}" "${RUNPWSH_SWIFT_HEADER_DIR}/RunPwshTerminalBridge-Swift.h"
    COMMENT "Building RunPwshTerminalBridge (Swift/SwiftTerm) via SwiftPM for arm64+x86_64, then lipo into a universal dylib"
    VERBATIM
)

# MODULE, not SHARED: this is a plugin bundle loaded via dlopen(), never
# linked against directly, and must not carry an install_name/versioned
# dylib path the way a real shared library would.
add_library(RunPwsh MODULE ${RUNPWSH_SRCS} ${RUNPWSH_HDRS})
add_dependencies(RunPwsh RunPwshTerminalBridge_swiftbuild)

set_target_properties(RunPwsh PROPERTIES
    OUTPUT_NAME "RunPwsh"
    PREFIX ""
    SUFFIX ".dylib"
    BUNDLE FALSE
)

target_include_directories(RunPwsh PRIVATE
    "${CMAKE_SOURCE_DIR}/vendor"
    "${CMAKE_SOURCE_DIR}/src"
    "${RUNPWSH_SWIFT_HEADER_DIR}"
)

target_compile_options(RunPwsh PRIVATE -fobjc-arc -Wall -Wextra)

target_link_libraries(RunPwsh PRIVATE
    "-framework Cocoa"
    "-framework Foundation"
    "${RUNPWSH_SWIFT_DYLIB}"
)

# Plugins are dlopen()'d, not linked against a fixed absolute path — but
# RunPwsh.dylib itself now links directly against libRunPwshTerminalBridge.dylib
# (a real dependency, unlike the host app itself, which is why
# -undefined,dynamic_lookup alone isn't enough here: that flag only defers
# *host-provided* symbols, it doesn't help RunPwsh.dylib find a sibling
# library at runtime). @loader_path makes it look next to itself, where
# install_plugin below copies libRunPwshTerminalBridge.dylib to.
set_target_properties(RunPwsh PROPERTIES
    LINK_FLAGS "-Wl,-undefined,dynamic_lookup -Wl,-rpath,@loader_path"
)

# -----------------------------------------------------------------------------
# Convenience "install" step: copies the built dylib into the same
# <PluginName>/<PluginName>.dylib layout the host's NppPluginManager expects
# under ~/Library/Application Support/Nextpad++/plugins/.
# Usage: cmake --build build --target install_plugin
# -----------------------------------------------------------------------------
set(NPP_PLUGINS_DIR "$ENV{HOME}/Library/Application Support/Nextpad++/plugins")

add_custom_target(install_plugin
    COMMAND ${CMAKE_COMMAND} -E make_directory "${NPP_PLUGINS_DIR}/RunPwsh"
    COMMAND ${CMAKE_COMMAND} -E copy "$<TARGET_FILE:RunPwsh>" "${NPP_PLUGINS_DIR}/RunPwsh/RunPwsh.dylib"
    # Sits next to RunPwsh.dylib so the @loader_path rpath set above finds it.
    COMMAND ${CMAKE_COMMAND} -E copy "${RUNPWSH_SWIFT_DYLIB}" "${NPP_PLUGINS_DIR}/RunPwsh/libRunPwshTerminalBridge.dylib"
    COMMAND ${CMAKE_COMMAND} -E copy_directory "${CMAKE_SOURCE_DIR}/resources" "${NPP_PLUGINS_DIR}/RunPwsh/resources"
    DEPENDS RunPwsh
    COMMENT "Installing RunPwsh.dylib, libRunPwshTerminalBridge.dylib and toolbar icons into ${NPP_PLUGINS_DIR}/RunPwsh/"
)

# -----------------------------------------------------------------------------
# Unit tests for the session state machine (no host, no Swift bridge needed).
# Usage: cmake --build build --target run_session_tests
# -----------------------------------------------------------------------------
add_executable(runpwsh_session_tests EXCLUDE_FROM_ALL
    tests/RunPwshSessionTests.mm
    src/RunPwshSession.mm
    src/RunPwshPreferences.mm
)
target_include_directories(runpwsh_session_tests PRIVATE "${CMAKE_SOURCE_DIR}/src")
target_compile_options(runpwsh_session_tests PRIVATE -fobjc-arc -Wall -Wextra)
target_link_libraries(runpwsh_session_tests PRIVATE "-framework Foundation")

add_custom_target(run_session_tests
    COMMAND runpwsh_session_tests
    DEPENDS runpwsh_session_tests
    COMMENT "Running RunPwshSession tests"
)

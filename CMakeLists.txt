cmake_minimum_required(VERSION 3.20)
project(RunPwsh OBJCXX CXX)

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
set(CMAKE_OSX_DEPLOYMENT_TARGET "11.0")
if(NOT CMAKE_OSX_ARCHITECTURES)
    set(CMAKE_OSX_ARCHITECTURES "arm64;x86_64")
endif()

set(RUNPWSH_SRCS
    src/RunPwshPlugin.mm
    src/RunPwshPanelView.mm
    src/RunPwshEngine.mm
    src/RunPwshLocalization.mm
)

set(RUNPWSH_HDRS
    vendor/NppPluginInterfaceMac.h
    src/RunPwshPanelView.h
    src/RunPwshEngine.h
    src/RunPwshLocalization.h
)

# MODULE, not SHARED: this is a plugin bundle loaded via dlopen(), never
# linked against directly, and must not carry an install_name/versioned
# dylib path the way a real shared library would.
add_library(RunPwsh MODULE ${RUNPWSH_SRCS} ${RUNPWSH_HDRS})

set_target_properties(RunPwsh PROPERTIES
    OUTPUT_NAME "RunPwsh"
    PREFIX ""
    SUFFIX ".dylib"
    BUNDLE FALSE
)

target_include_directories(RunPwsh PRIVATE
    "${CMAKE_SOURCE_DIR}/vendor"
    "${CMAKE_SOURCE_DIR}/src"
)

target_compile_options(RunPwsh PRIVATE -fobjc-arc -Wall -Wextra)

target_link_libraries(RunPwsh PRIVATE
    "-framework Cocoa"
    "-framework Foundation"
)

# Plugins are dlopen()'d, not linked against a fixed absolute path.
set_target_properties(RunPwsh PROPERTIES
    LINK_FLAGS "-Wl,-undefined,dynamic_lookup"
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
    COMMAND ${CMAKE_COMMAND} -E copy_directory "${CMAKE_SOURCE_DIR}/resources" "${NPP_PLUGINS_DIR}/RunPwsh/resources"
    DEPENDS RunPwsh
    COMMENT "Installing RunPwsh.dylib and toolbar icons into ${NPP_PLUGINS_DIR}/RunPwsh/"
)

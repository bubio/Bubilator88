cmake_minimum_required(VERSION 3.21)
project(Bubilator88LocalBuild LANGUAGES NONE)

if(NOT CMAKE_HOST_APPLE)
  message(FATAL_ERROR "This entry point builds the macOS app. See windows/README.md for Windows.")
endif()

# Xcode remains responsible for Swift, resources, signing and incremental builds.
set(B88_CONFIGURATION "Debug" CACHE STRING "Xcode configuration: Debug or Release")
set_property(CACHE B88_CONFIGURATION PROPERTY STRINGS Debug Release)
set(B88_EXCLUSIVITY "checked" CACHE STRING "Swift dynamic exclusivity: checked or unchecked")
set_property(CACHE B88_EXCLUSIVITY PROPERTY STRINGS checked unchecked)
set(B88_CORE "local" CACHE STRING "Core source: local sibling clone or pinned package")
set_property(CACHE B88_CORE PROPERTY STRINGS local pinned)

if(NOT B88_CONFIGURATION MATCHES "^(Debug|Release)$" OR
   NOT B88_EXCLUSIVITY MATCHES "^(checked|unchecked)$" OR
   NOT B88_CORE MATCHES "^(local|pinned)$")
  message(FATAL_ERROR "Invalid B88_CONFIGURATION, B88_EXCLUSIVITY or B88_CORE value")
endif()

add_custom_target(app ALL
  COMMAND /bin/bash "${CMAKE_CURRENT_SOURCE_DIR}/scripts/build_macos.sh"
    --configuration "${B88_CONFIGURATION}"
    --exclusivity "${B88_EXCLUSIVITY}"
    --core "${B88_CORE}"
    --build-root "${CMAKE_CURRENT_BINARY_DIR}/outputs"
  WORKING_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}"
  USES_TERMINAL
  VERBATIM
)

cmake_minimum_required(VERSION 3.22)
project(ech_http LANGUAGES C CXX)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)
set(CMAKE_C_VISIBILITY_PRESET hidden)
set(CMAKE_CXX_VISIBILITY_PRESET hidden)
set(CMAKE_VISIBILITY_INLINES_HIDDEN ON)
if(NOT DEFINED EH_DEPS_ROOT)
  message(FATAL_ERROR "Use the Dart build hook to supply the verified dependency SDK")
endif()
include("${EH_DEPS_ROOT}/cmake/EchHttpDeps.cmake")
if(NOT EXISTS "${EH_DART_INCLUDE}/dart_native_api.h")
  message(FATAL_ERROR "Use the Dart build hook to supply EH_DART_INCLUDE from the active Dart SDK")
endif()

# KAZUMI PATCH (0.2.3 -> 0.2.2 behaviour restored):
# MSVC rejects a single string literal longer than 16380 bytes (C2026), and the
# bundled CA store is far bigger than that, so it is split into chunks that are
# joined at runtime. cacert.pem itself stays untouched.
# Upstream 0.2.2 had exactly this implementation; 0.2.3 replaced it with
# configure_file() + ca_bundle.h.in, which emits one 200 KB raw string literal
# and therefore breaks every Windows/MSVC build. See PATCHES.md.
file(READ "${CMAKE_CURRENT_SOURCE_DIR}/cacert.pem" EH_CA_PEM)
string(LENGTH "${EH_CA_PEM}" EH_CA_LEN)
# Adjacent string literals are concatenated by the compiler before the size check
# runs, so an array of chunks is used instead of one concatenated literal.
set(EH_CA_CHUNK_SIZE 4000)
set(EH_CA_BODY "")
set(EH_CA_OFFSET 0)
while(EH_CA_OFFSET LESS EH_CA_LEN)
  string(SUBSTRING "${EH_CA_PEM}" ${EH_CA_OFFSET} ${EH_CA_CHUNK_SIZE} EH_CA_CHUNK)
  string(APPEND EH_CA_BODY "    R\"ECH_CA_BUNDLE(${EH_CA_CHUNK})ECH_CA_BUNDLE\",\n")
  math(EXPR EH_CA_OFFSET "${EH_CA_OFFSET} + ${EH_CA_CHUNK_SIZE}")
endwhile()
file(WRITE "${CMAKE_CURRENT_BINARY_DIR}/ca_bundle.h"
"#pragma once
#include <string>
inline const std::string &eh_ca_bundle() {
static const std::string roots = [] {
static const char *const chunks[] = {
${EH_CA_BODY}    };
std::string joined;
joined.reserve(${EH_CA_LEN});
for (const char *chunk : chunks) joined += chunk;
return joined;
}();
return roots;
}
")
add_library(ech_http SHARED ech_http.cpp)
# Imported includes default to -isystem, which can lose to a host OpenSSL
# installation in /usr/local/include. Always prefer this SDK's pinned headers.
set_target_properties(ech_http PROPERTIES NO_SYSTEM_FROM_IMPORTED ON)
target_include_directories(ech_http PRIVATE "${CMAKE_CURRENT_BINARY_DIR}" "${EH_DART_INCLUDE}")
target_link_libraries(ech_http PRIVATE EchHttp::curl)
find_package(Threads REQUIRED)
target_link_libraries(ech_http PRIVATE Threads::Threads)
if(ANDROID)
  target_link_options(ech_http PRIVATE "-Wl,-z,max-page-size=16384" "-Wl,--exclude-libs,ALL" "-Wl,--strip-debug")
elseif(UNIX AND NOT APPLE)
  target_link_options(ech_http PRIVATE "-Wl,--exclude-libs,ALL")
endif()
if(CMAKE_SYSTEM_NAME STREQUAL "OHOS")
  # The OHOS SDK adds -ggdb even to Release builds. Do not ship that debug data
  # or export the statically linked TLS/C++ runtime into other native plugins.
  target_link_options(ech_http PRIVATE "-Wl,--exclude-libs,ALL" "-Wl,--strip-debug")
endif()
if(APPLE)
  set_target_properties(ech_http PROPERTIES INSTALL_NAME_DIR "@rpath" BUILD_WITH_INSTALL_NAME_DIR ON)
endif()
set_target_properties(ech_http PROPERTIES RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/out" LIBRARY_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/out")

option(EH_BUILD_SMOKE "Build the standalone native request smoke test" OFF)
if(EH_BUILD_SMOKE)
  add_executable(ech_http_smoke ../tool/native_smoke.cpp)
  target_include_directories(ech_http_smoke PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}" "${EH_DART_INCLUDE}")
  target_link_libraries(ech_http_smoke PRIVATE ech_http Threads::Threads)
  set_target_properties(ech_http_smoke PROPERTIES RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/out")
endif()

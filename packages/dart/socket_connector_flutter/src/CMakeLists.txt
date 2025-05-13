# The Flutter tooling requires that developers have CMake 3.10 or later
# installed. You should not increase this version, as doing so will cause
# the plugin to fail to compile for some customers of the plugin.
cmake_minimum_required(VERSION 3.10)

project(socket_connector_flutter_library VERSION 0.0.1 LANGUAGES C)

add_library(socket_connector_flutter SHARED
  "socket_connector_flutter.c"
)

set_target_properties(socket_connector_flutter PROPERTIES
  PUBLIC_HEADER socket_connector_flutter.h
  OUTPUT_NAME "socket_connector_flutter"
)

target_compile_definitions(socket_connector_flutter PUBLIC DART_SHARED_LIB)

if (ANDROID)
  # Support Android 15 16k page size
  target_link_options(socket_connector_flutter PRIVATE "-Wl,-z,max-page-size=16384")
endif()

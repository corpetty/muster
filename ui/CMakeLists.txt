cmake_minimum_required(VERSION 3.14)
project(MusterUiPlugin LANGUAGES CXX)

if(DEFINED ENV{LOGOS_MODULE_BUILDER_ROOT})
    include($ENV{LOGOS_MODULE_BUILDER_ROOT}/cmake/LogosModule.cmake)
else()
    message(FATAL_ERROR "LogosModule.cmake not found. Set LOGOS_MODULE_BUILDER_ROOT.")
endif()

# Module name from metadata.json — single source of truth.
file(READ "${CMAKE_CURRENT_SOURCE_DIR}/metadata.json" METADATA_JSON)
string(JSON MODULE_NAME GET ${METADATA_JSON} name)

# Universal UI module: we write the .rep + the *Backend class. REP_FILE runs
# repc; the generated *Plugin glue in generated_code/ compiles automatically.
logos_module(
    NAME ${MODULE_NAME}
    REP_FILE src/muster_ui.rep
    SOURCES
        src/muster_ui_backend.h
        src/muster_ui_backend.cpp
    INCLUDE_DIRS
        src
)

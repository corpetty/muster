cmake_minimum_required(VERSION 3.14)
project(MusterModulePlugin LANGUAGES CXX)

if(DEFINED ENV{LOGOS_MODULE_BUILDER_ROOT})
    include($ENV{LOGOS_MODULE_BUILDER_ROOT}/cmake/LogosModule.cmake)
else()
    message(FATAL_ERROR "LOGOS_MODULE_BUILDER_ROOT is not set.")
endif()

configure_file(${CMAKE_CURRENT_SOURCE_DIR}/metadata.json
               ${CMAKE_CURRENT_BINARY_DIR}/metadata.json COPYONLY)

# cdylib module: the Nim staticlib (codegen.nim) providing the logos_module_*
# exports is staged into lib/ by mkLogosModule and linked via the cmake helper's
# LOGOS_MODULE_NIM_STATIC_LIBS block — the module needs no manual link here.
logos_module(NAME muster_module)

# common target definitions
# this file will also load platform specific macros

add_executable(sunshine ${SUNSHINE_TARGET_FILES})
foreach(dep ${SUNSHINE_TARGET_DEPENDENCIES})
    add_dependencies(sunshine ${dep})  # compile these before sunshine
endforeach()

# platform specific target definitions
if(WIN32)
    include(${CMAKE_MODULE_PATH}/targets/windows.cmake)
elseif(UNIX)
    include(${CMAKE_MODULE_PATH}/targets/unix.cmake)

    if(APPLE)
        include(${CMAKE_MODULE_PATH}/targets/macos.cmake)
    else()
        include(${CMAKE_MODULE_PATH}/targets/linux.cmake)
    endif()
endif()

# todo - is this necessary? ... for anything except linux?
if(NOT DEFINED CMAKE_CUDA_STANDARD)
    set(CMAKE_CUDA_STANDARD 17)
    set(CMAKE_CUDA_STANDARD_REQUIRED ON)
endif()

target_link_libraries(sunshine ${SUNSHINE_EXTERNAL_LIBRARIES} ${EXTRA_LIBS})
target_compile_definitions(sunshine PUBLIC ${SUNSHINE_DEFINITIONS})
set_target_properties(sunshine PROPERTIES CXX_STANDARD 23
        VERSION ${PROJECT_VERSION}
        SOVERSION ${PROJECT_VERSION_MAJOR})

# CLion complains about unknown flags after running cmake, and cannot add symbols to the index for cuda files
if(CUDA_INHERIT_COMPILE_OPTIONS)
    foreach(flag IN LISTS SUNSHINE_COMPILE_OPTIONS)
        list(APPEND SUNSHINE_COMPILE_OPTIONS_CUDA "$<$<COMPILE_LANGUAGE:CUDA>:--compiler-options=${flag}>")
    endforeach()
endif()

target_compile_options(sunshine PRIVATE $<$<COMPILE_LANGUAGE:CXX>:${SUNSHINE_COMPILE_OPTIONS}>;$<$<COMPILE_LANGUAGE:CUDA>:${SUNSHINE_COMPILE_OPTIONS_CUDA};-std=c++17>)  # cmake-lint: disable=C0301

# Homebrew build fails the vite build if we set these environment variables
if(${SUNSHINE_BUILD_HOMEBREW})
    set(NPM_SOURCE_ASSETS_DIR "")
    set(NPM_ASSETS_DIR "")
    set(NPM_BUILD_HOMEBREW "true")
else()
    set(NPM_SOURCE_ASSETS_DIR ${SUNSHINE_SOURCE_ASSETS_DIR})
    set(NPM_ASSETS_DIR ${CMAKE_BINARY_DIR})
    set(NPM_BUILD_HOMEBREW "")
endif()

#WebUI build
find_program(NPM npm REQUIRED)

set(NPM_INSTALL_FLAGS --ignore-scripts --no-audit --no-fund)
if (NPM_OFFLINE)
    list(APPEND NPM_INSTALL_FLAGS --offline)
endif()

add_custom_target(web-ui ALL
        WORKING_DIRECTORY "${CMAKE_SOURCE_DIR}"
        COMMENT "Installing NPM Dependencies and Building the Web UI"
        COMMAND "$<$<BOOL:${WIN32}>:cmd;/C>" "${NPM}" ci ${NPM_INSTALL_FLAGS}
        COMMAND "${CMAKE_COMMAND}" -E env "SUNSHINE_BUILD_HOMEBREW=${NPM_BUILD_HOMEBREW}" "SUNSHINE_SOURCE_ASSETS_DIR=${NPM_SOURCE_ASSETS_DIR}" "SUNSHINE_ASSETS_DIR=${NPM_ASSETS_DIR}" "$<$<BOOL:${WIN32}>:cmd;/C>" "${NPM}" run build-clean  # cmake-lint: disable=C0301
        # config_schema.json is served verbatim from WEB_DIR by confighttp's /api/configSchema
        # AND read by the XPC control service (src/platform/macos/xpc_control.mm). Vite does not
        # emit it (not JS-imported, not in publicDir), so copy it into the built web dir AFTER the
        # vite build (which may empty its outDir). Without this the schema is absent from every
        # deployed install and schema-driven config is non-functional.
        COMMAND "${CMAKE_COMMAND}" -E copy_if_different
                "${CMAKE_SOURCE_DIR}/src_assets/common/assets/web/config_schema.json"
                "${CMAKE_BINARY_DIR}/assets/web/config_schema.json"
        COMMAND_EXPAND_LISTS
        VERBATIM)

# docs
if(BUILD_DOCS)
    add_subdirectory(third-party/doxyconfig docs)
endif()

# tests
if(BUILD_TESTS)
    add_subdirectory(tests)
endif()

# custom compile flags, must be after adding tests

if (NOT BUILD_TESTS)
    set(TEST_DIR "")
else()
    set(TEST_DIR "${CMAKE_SOURCE_DIR}/tests")
endif()

# src/upnp
set_source_files_properties("${CMAKE_SOURCE_DIR}/src/upnp.cpp"
        DIRECTORY "${CMAKE_SOURCE_DIR}" "${TEST_DIR}"
        PROPERTIES COMPILE_FLAGS -Wno-pedantic)

# third-party/nanors
set_source_files_properties("${CMAKE_SOURCE_DIR}/src/rswrapper.c"
        DIRECTORY "${CMAKE_SOURCE_DIR}" "${TEST_DIR}"
        PROPERTIES COMPILE_FLAGS "-ftree-vectorize -funroll-loops")

# third-party/ViGEmClient (Windows-only virtual gamepad emulation; submodule isn't even checked
# out on macOS, so this whole block would be a harmless no-op there anyway - skip it outright
# on APPLE to keep the cmake tree honest about what's actually reachable on this platform).
if(NOT APPLE)
    set(VIGEM_COMPILE_FLAGS "")
    string(APPEND VIGEM_COMPILE_FLAGS "-Wno-unknown-pragmas ")
    string(APPEND VIGEM_COMPILE_FLAGS "-Wno-misleading-indentation ")
    string(APPEND VIGEM_COMPILE_FLAGS "-Wno-class-memaccess ")
    string(APPEND VIGEM_COMPILE_FLAGS "-Wno-unused-function ")
    string(APPEND VIGEM_COMPILE_FLAGS "-Wno-unused-variable ")
    set_source_files_properties("${CMAKE_SOURCE_DIR}/third-party/ViGEmClient/src/ViGEmClient.cpp"
            DIRECTORY "${CMAKE_SOURCE_DIR}" "${TEST_DIR}"
            PROPERTIES
            COMPILE_DEFINITIONS "UNICODE=1;ERROR_INVALID_DEVICE_OBJECT_PARAMETER=650"
            COMPILE_FLAGS ${VIGEM_COMPILE_FLAGS})
endif()

# src/nvhttp
string(TOUPPER "x${CMAKE_BUILD_TYPE}" BUILD_TYPE)
if("${BUILD_TYPE}" STREQUAL "XDEBUG")
    if(WIN32)
        if (NOT BUILD_TESTS)
            set_source_files_properties("${CMAKE_SOURCE_DIR}/src/nvhttp.cpp"
                    DIRECTORY "${CMAKE_SOURCE_DIR}"
                    PROPERTIES COMPILE_FLAGS -O2)
        else()
            set_source_files_properties("${CMAKE_SOURCE_DIR}/src/nvhttp.cpp"
                    DIRECTORY "${CMAKE_SOURCE_DIR}" "${CMAKE_SOURCE_DIR}/tests"
                    PROPERTIES COMPILE_FLAGS -O2)
        endif()
    endif()
else()
    add_definitions(-DNDEBUG)
endif()

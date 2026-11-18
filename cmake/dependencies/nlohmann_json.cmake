#
# Loads the nlohmann_json library giving the priority to the system package first, with a fallback to FetchContent.
#
include_guard(GLOBAL)

find_package(nlohmann_json 3.11 QUIET GLOBAL)
if(NOT nlohmann_json_FOUND)
    message(STATUS "nlohmann_json v3.11.x package not found in the system. Falling back to FetchContent.")
    include(FetchContent)

    if (CMAKE_VERSION VERSION_GREATER_EQUAL "3.24.0")
        cmake_policy(SET CMP0135 NEW)  # Avoid warning about DOWNLOAD_EXTRACT_TIMESTAMP in CMake 3.24
    endif()
    if (CMAKE_VERSION VERSION_GREATER_EQUAL "3.31.0")
        cmake_policy(SET CMP0174 NEW)  # Handle empty variables
    endif()

    FetchContent_Declare(
            json
            URL      https://github.com/nlohmann/json/releases/download/v3.11.3/json.tar.xz
            URL_HASH SHA256=d6c65aca6b1ed68e7a182f4757257b107ae403032760ed6ef121c9d55e81757d
            DOWNLOAD_EXTRACT_TIMESTAMP
    )
    FetchContent_MakeAvailable(json)
endif()

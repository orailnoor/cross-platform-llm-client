# Custom FindVulkan for Android cross-compilation
# This bypasses the host Vulkan SDK search and uses NDK tools + cloned headers

if(ANDROID)
    # Try to find NDK path
    if(DEFINED CMAKE_ANDROID_NDK)
        set(_ANDROID_NDK "${CMAKE_ANDROID_NDK}")
    elseif(DEFINED ANDROID_NDK)
        set(_ANDROID_NDK "${ANDROID_NDK}")
    elseif(DEFINED ENV{ANDROID_NDK})
        set(_ANDROID_NDK "$ENV{ANDROID_NDK}")
    elseif(CMAKE_TOOLCHAIN_FILE)
        get_filename_component(_TOOLCHAIN_DIR "${CMAKE_TOOLCHAIN_FILE}" DIRECTORY)
        get_filename_component(_ANDROID_NDK "${_TOOLCHAIN_DIR}/../../.." ABSOLUTE)
    endif()

    if(NOT _ANDROID_NDK OR NOT EXISTS "${_ANDROID_NDK}")
        message(FATAL_ERROR "Android NDK not found. Cannot configure Vulkan backend.")
    endif()

    message(STATUS "Android NDK for Vulkan: ${_ANDROID_NDK}")

    # Find glslc from NDK shader-tools
    if(CMAKE_HOST_SYSTEM_NAME STREQUAL "Darwin")
        set(_HOST_SUBDIR "darwin-x86_64")
    elseif(CMAKE_HOST_SYSTEM_NAME STREQUAL "Linux")
        set(_HOST_SUBDIR "linux-x86_64")
    elseif(CMAKE_HOST_SYSTEM_NAME STREQUAL "Windows")
        set(_HOST_SUBDIR "windows-x86_64")
    else()
        set(_HOST_SUBDIR "${CMAKE_HOST_SYSTEM_NAME}")
    endif()

    set(_GLSLC_CANDIDATE "${_ANDROID_NDK}/shader-tools/${_HOST_SUBDIR}/glslc")
    if(EXISTS "${_GLSLC_CANDIDATE}")
        set(Vulkan_GLSLC_EXECUTABLE "${_GLSLC_CANDIDATE}" CACHE FILEPATH "Path to glslc" FORCE)
    else()
        # Try to find glslc in PATH as fallback
        find_program(Vulkan_GLSLC_EXECUTABLE NAMES glslc)
    endif()

    if(NOT Vulkan_GLSLC_EXECUTABLE)
        message(FATAL_ERROR "glslc not found in NDK (${_GLSLC_CANDIDATE}) or PATH. Cannot compile Vulkan shaders.")
    endif()

    message(STATUS "Found glslc: ${Vulkan_GLSLC_EXECUTABLE}")

    # Vulkan headers: use cloned Vulkan-Headers for vulkan.hpp, and NDK for vulkan_core.h
    # The NDK already has vulkan_core.h in its sysroot
    # We add our cloned headers directory which contains vulkan.hpp
    get_filename_component(_CMAKE_DIR "${CMAKE_CURRENT_LIST_FILE}" DIRECTORY)
    get_filename_component(_PLUGIN_DIR "${_CMAKE_DIR}/.." ABSOLUTE)
    set(_VULKAN_HPP_DIR "${_PLUGIN_DIR}/src/main/cpp/vulkan-headers/include")

    if(NOT EXISTS "${_VULKAN_HPP_DIR}/vulkan/vulkan.hpp")
        message(FATAL_ERROR "vulkan.hpp not found at ${_VULKAN_HPP_DIR}/vulkan/vulkan.hpp. Run: curl -L https://github.com/KhronosGroup/Vulkan-Headers/archive/refs/heads/main.zip | unzip - && mv Vulkan-Headers-main vulkan-headers")
    endif()

    # For Android, the NDK sysroot already contains vulkan/vulkan_core.h
    # We just need to add the vulkan.hpp directory
    set(Vulkan_INCLUDE_DIRS "${_VULKAN_HPP_DIR}")

    # Create imported target for Android's libvulkan.so
    # We link using -lvulkan which resolves to the NDK's stub lib at link time
    # and the system's libvulkan.so at runtime
    if(NOT TARGET Vulkan::Vulkan)
        add_library(Vulkan::Vulkan INTERFACE IMPORTED)
        set_target_properties(Vulkan::Vulkan PROPERTIES
            INTERFACE_LINK_LIBRARIES "-lvulkan"
            INTERFACE_INCLUDE_DIRECTORIES "${Vulkan_INCLUDE_DIRS}"
        )
    endif()

    set(Vulkan_FOUND TRUE)
    message(STATUS "Custom FindVulkan configured for Android cross-compilation")
else()
    # For non-Android builds, delegate to CMake's built-in FindVulkan
    include(${CMAKE_ROOT}/Modules/FindVulkan.cmake)
endif()

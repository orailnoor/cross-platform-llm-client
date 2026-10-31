cmake_minimum_required(VERSION 3.22.1)

project(llama_jni)

# Set C++17
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# Android 15 16KB page size compliance
set(CMAKE_EXE_LINKER_FLAGS "${CMAKE_EXE_LINKER_FLAGS} -Wl,-z,max-page-size=16384")
set(CMAKE_SHARED_LINKER_FLAGS "${CMAKE_SHARED_LINKER_FLAGS} -Wl,-z,max-page-size=16384")

# ARM64 optimizations. No global -march: the CPU backend is built once per
# Arm generation (below) and the best one for the phone is picked at runtime.
if(ANDROID_ABI STREQUAL "arm64-v8a")
    set(CMAKE_C_FLAGS "${CMAKE_C_FLAGS} -O3")
    set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -O3")
endif()

# llama.cpp options
set(GGML_CPU_AARCH64 ON CACHE BOOL "Enable ARM64 support")
set(GGML_NATIVE OFF CACHE BOOL "Cross-compiling: never tune for the build host" FORCE)

# Backends are separate .so modules loaded at runtime (see jni_wrapper.cpp):
#  - libggml-cpu-android_armv*.so: one per Arm generation (dotprod, fp16,
#    i8mm, SVE2, SME); the fastest one the phone supports is loaded.
#  - libggml-vulkan.so: GPU backend, loaded only when the app allows it, so
#    phones with unstable Vulkan drivers never initialise it.
#  - libggml-rpc.so: phone cluster. A worker serves its CPU to other phones;
#    a coordinator spreads model layers across the workers it adds.
option(LLAMA_ANDROID_VULKAN "Build the Vulkan GPU backend" ON)
option(LLAMA_ANDROID_RPC "Build the RPC backend (phone cluster)" ON)
if(ANDROID_ABI STREQUAL "arm64-v8a")
    set(GGML_BACKEND_DL ON CACHE BOOL "Load backends at runtime" FORCE)
    set(GGML_CPU_ALL_VARIANTS ON CACHE BOOL "Build every Arm CPU variant" FORCE)
    set(GGML_VULKAN ${LLAMA_ANDROID_VULKAN} CACHE BOOL "Enable Vulkan GPU backend" FORCE)
    set(GGML_RPC ${LLAMA_ANDROID_RPC} CACHE BOOL "Enable RPC backend" FORCE)
    set(GGML_RPC_RDMA OFF CACHE BOOL "No RDMA on Android" FORCE)
else()
    # 32-bit Arm (armeabi-v7a): plain CPU build. llamafile's sgemm uses
    # FP16 NEON intrinsics that ARMv7 lacks. No cluster support either.
    set(GGML_VULKAN OFF CACHE BOOL "Enable Vulkan GPU backend" FORCE)
    set(GGML_RPC OFF CACHE BOOL "Enable RPC backend" FORCE)
    set(GGML_LLAMAFILE OFF CACHE BOOL "No FP16 NEON on ARMv7" FORCE)
endif()

if(GGML_VULKAN)
    # The NDK ships vulkan.h but not vulkan.hpp/SPIR-V headers, and the
    # C++ headers must match vulkan.h exactly, so fetch one pinned set.
    include(FetchContent)
    # Plain HTTPS archives (not git): avoids git URL rewrites to SSH, which
    # hang a non-interactive Gradle build waiting for a key passphrase.
    FetchContent_Declare(vulkan_headers
        URL https://github.com/KhronosGroup/Vulkan-Headers/archive/refs/tags/v1.4.363.tar.gz
        URL_HASH SHA256=cbaf687d3c59b9666fe080e7f8396b6b4f4d344a768ee6b337c59852f4526b68)
    FetchContent_Declare(spirv_headers
        URL https://github.com/KhronosGroup/SPIRV-Headers/archive/refs/tags/vulkan-sdk-1.4.363.0.tar.gz
        URL_HASH SHA256=5b3a0d099f5c7649e29c0938476c462e71d66ad89a0bde42fa1ba3eb476956c9)
    FetchContent_GetProperties(vulkan_headers)
    if(NOT vulkan_headers_POPULATED)
        FetchContent_Populate(vulkan_headers)
    endif()
    FetchContent_GetProperties(spirv_headers)
    if(NOT spirv_headers_POPULATED)
        FetchContent_Populate(spirv_headers)
    endif()
    set(Vulkan_INCLUDE_DIR "${vulkan_headers_SOURCE_DIR}/include" CACHE PATH "" FORCE)
    include_directories(BEFORE SYSTEM "${spirv_headers_SOURCE_DIR}/include")
    # Newer ggml-vulkan calls find_package(SPIRV-Headers CONFIG). CMake 3.22
    # can't redirect find_package to FetchContent, so provide a minimal
    # config file for the headers fetched above.
    set(_spirv_cfg_dir "${CMAKE_BINARY_DIR}/spirv-headers-config")
    file(WRITE "${_spirv_cfg_dir}/SPIRV-HeadersConfig.cmake"
"if(NOT TARGET SPIRV-Headers::SPIRV-Headers)
  add_library(SPIRV-Headers::SPIRV-Headers INTERFACE IMPORTED)
  set_target_properties(SPIRV-Headers::SPIRV-Headers PROPERTIES
    INTERFACE_INCLUDE_DIRECTORIES \"${spirv_headers_SOURCE_DIR}/include\")
endif()
")
    set(SPIRV-Headers_DIR "${_spirv_cfg_dir}" CACHE PATH "" FORCE)

    # vulkan-shaders-gen is a separate host-side CMake build (ExternalProject).
    # It inherits the Ninja generator but not its path, so hand it a host
    # toolchain that points at the same ninja binary and the host compilers.
    # System compilers only: the NDK's clang (also on PATH) targets Android.
    find_program(_host_cc  NAMES clang gcc cc
        PATHS /usr/bin /usr/local/bin NO_DEFAULT_PATH NO_CMAKE_FIND_ROOT_PATH)
    find_program(_host_cxx NAMES clang++ g++ c++
        PATHS /usr/bin /usr/local/bin NO_DEFAULT_PATH NO_CMAKE_FIND_ROOT_PATH)
    set(_vk_host_tc "${CMAKE_BINARY_DIR}/vk-shaders-gen-host-toolchain.cmake")
    file(WRITE "${_vk_host_tc}"
"set(CMAKE_BUILD_TYPE Release)
set(CMAKE_C_FLAGS -O2)
set(CMAKE_CXX_FLAGS -O2)
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE NEVER)
set(CMAKE_C_COMPILER \"${_host_cc}\")
set(CMAKE_CXX_COMPILER \"${_host_cxx}\")
set(CMAKE_MAKE_PROGRAM \"${CMAKE_MAKE_PROGRAM}\" CACHE FILEPATH \"\")
")
    set(GGML_VULKAN_SHADERS_GEN_TOOLCHAIN "${_vk_host_tc}" CACHE FILEPATH "" FORCE)

    # Shaders are compiled with the NDK's own glslc.
    if(CMAKE_HOST_SYSTEM_NAME STREQUAL "Darwin")
        set(_ndk_host darwin-x86_64)
    elseif(CMAKE_HOST_SYSTEM_NAME STREQUAL "Windows")
        set(_ndk_host windows-x86_64)
    else()
        set(_ndk_host linux-x86_64)
    endif()
    # The NDK's glslc (shaderc 2022.x) is too old for current ggml-vulkan
    # shaders (cooperative matrix). Use a newer system glslc — e.g.
    # `brew install shaderc` — and only fall back to the NDK's.
    find_program(Vulkan_GLSLC_EXECUTABLE glslc
        PATHS /opt/homebrew/bin /usr/local/bin ENV VULKAN_SDK
        PATH_SUFFIXES bin
        NO_DEFAULT_PATH NO_CMAKE_FIND_ROOT_PATH)
    if(NOT Vulkan_GLSLC_EXECUTABLE)
        message(WARNING "No modern glslc found; falling back to the NDK's, "
                        "which can't compile all Vulkan shaders. "
                        "Install one with: brew install shaderc")
        find_program(Vulkan_GLSLC_EXECUTABLE glslc
            HINTS "${ANDROID_NDK}/shader-tools/${_ndk_host}" NO_DEFAULT_PATH)
    endif()
    message(STATUS "glslc: ${Vulkan_GLSLC_EXECUTABLE}")
endif()
set(GGML_OPENMP OFF CACHE BOOL "Disable OpenMP to avoid packaging libomp.so" FORCE)
set(GGML_STATIC OFF CACHE BOOL "Build as shared library")
set(BUILD_SHARED_LIBS ON CACHE BOOL "Build shared libraries")

# Disable unused features
set(LLAMA_BUILD_TESTS OFF CACHE BOOL "Disable tests")
set(LLAMA_BUILD_EXAMPLES OFF CACHE BOOL "Disable examples")
set(LLAMA_BUILD_SERVER OFF CACHE BOOL "Disable server")

# Multimodal (vision) support: build llama.cpp's mtmd library standalone,
# without common/ or the CLI tools. Video needs an ffmpeg binary, which
# Android doesn't have, so it stays off.
set(LLAMA_BUILD_MTMD ON CACHE BOOL "Build the mtmd library" FORCE)
set(MTMD_VIDEO OFF CACHE BOOL "No ffmpeg on Android" FORCE)

# Add llama.cpp
add_subdirectory(src/main/cpp/llama.cpp)

# ggml-base is linked as a standalone shared object and contains C++ sources.
# On Android/NDK it must explicitly link libc++ or symbols such as operator new
# and std::runtime_error stay unresolved during the native build.
if(ANDROID)
    foreach(target ggml-base ggml ggml-cpu ggml-vulkan ggml-rpc llama mtmd
            ggml-cpu-android_armv8.0_1 ggml-cpu-android_armv8.2_1
            ggml-cpu-android_armv8.2_2 ggml-cpu-android_armv8.6_1
            ggml-cpu-android_armv9.0_1 ggml-cpu-android_armv9.2_1
            ggml-cpu-android_armv9.2_2)
        if(TARGET ${target})
            target_link_libraries(${target} PRIVATE c++_shared)
        endif()
    endforeach()
endif()

# JNI wrapper library - simplified without common library
add_library(llama_jni SHARED
    src/main/cpp/jni_wrapper.cpp
)

target_link_libraries(llama_jni
    mtmd
    llama
    ggml
    c++_shared
    android
    log
    dl
)

if(GGML_BACKEND_DL)
    target_compile_definitions(llama_jni PRIVATE LLAMA_JNI_BACKEND_DL=1)
endif()

target_include_directories(llama_jni PRIVATE
    src/main/cpp/llama.cpp/include
    src/main/cpp/llama.cpp/ggml/include
)

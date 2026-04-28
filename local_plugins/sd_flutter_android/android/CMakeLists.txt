cmake_minimum_required(VERSION 3.22.1)

project(sd_jni)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# Android 15 16KB page size compliance
set(CMAKE_EXE_LINKER_FLAGS "${CMAKE_EXE_LINKER_FLAGS} -Wl,-z,max-page-size=16384")
set(CMAKE_SHARED_LINKER_FLAGS "${CMAKE_SHARED_LINKER_FLAGS} -Wl,-z,max-page-size=16384")

# Add stable-diffusion.cpp
set(SD_BUILD_EXAMPLES OFF CACHE BOOL "Disable SD examples")
set(SD_BUILD_SHARED_LIBS OFF CACHE BOOL "Build SD as static")
add_subdirectory(src/main/cpp/stable-diffusion.cpp)

# JNI wrapper library
add_library(sd_jni SHARED
    src/main/cpp/sd_jni_wrapper.cpp
)

target_link_libraries(sd_jni
    stable-diffusion
    android
    log
)

target_include_directories(sd_jni PRIVATE
    src/main/cpp/stable-diffusion.cpp/include
    src/main/cpp/stable-diffusion.cpp/src
)

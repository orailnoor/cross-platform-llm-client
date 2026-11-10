cmake_minimum_required(VERSION 3.19)
project(privatelm_native LANGUAGES C CXX)

option(PRIVATELM_WINDOWS_VULKAN "Enable Windows GPU inference through Vulkan" ON)
set(LLAMA_SOURCE "${CMAKE_CURRENT_SOURCE_DIR}/../android/src/main/cpp/llama.cpp")
set(BUILD_SHARED_LIBS OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_COMMON OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_TESTS OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_TOOLS OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_SERVER OFF CACHE BOOL "" FORCE)
set(LLAMA_OPENSSL OFF CACHE BOOL "" FORCE)
set(GGML_RPC ON CACHE BOOL "" FORCE)
set(GGML_VULKAN ${PRIVATELM_WINDOWS_VULKAN} CACHE BOOL "" FORCE)
set(GGML_NATIVE OFF CACHE BOOL "" FORCE)
set(GGML_AVX OFF CACHE BOOL "" FORCE)
set(GGML_AVX2 OFF CACHE BOOL "" FORCE)
set(GGML_FMA OFF CACHE BOOL "" FORCE)
set(GGML_F16C OFF CACHE BOOL "" FORCE)
set(GGML_BMI2 OFF CACHE BOOL "" FORCE)
set(GGML_SSE42 OFF CACHE BOOL "" FORCE)
set(GGML_OPENMP OFF CACHE BOOL "" FORCE)
# Shader-generator try-compile paths otherwise exceed Windows MAX_PATH.
include(ExternalProject)
set_property(DIRECTORY PROPERTY EP_BASE "${CMAKE_BINARY_DIR}/native-tools")
add_subdirectory("${LLAMA_SOURCE}" "${CMAKE_CURRENT_BINARY_DIR}/llama" EXCLUDE_FROM_ALL)

add_executable(privatelm-native native_engine.cpp)
target_compile_features(privatelm-native PRIVATE cxx_std_17)
target_compile_options(privatelm-native PRIVATE /utf-8 /EHsc)
target_compile_definitions(privatelm-native PRIVATE NOMINMAX WIN32_LEAN_AND_MEAN)
target_include_directories(privatelm-native PRIVATE "${LLAMA_SOURCE}/vendor")
target_link_libraries(privatelm-native PRIVATE llama ggml ggml-rpc psapi)
configure_file("${LLAMA_SOURCE}/LICENSE"
  "${CMAKE_CURRENT_BINARY_DIR}/LICENSE-llama.cpp" COPYONLY)
configure_file("${CMAKE_CURRENT_SOURCE_DIR}/../LICENSE"
  "${CMAKE_CURRENT_BINARY_DIR}/LICENSE-llama-flutter" COPYONLY)
configure_file("${LLAMA_SOURCE}/vendor/hash/xxhash/LICENSE"
  "${CMAKE_CURRENT_BINARY_DIR}/LICENSE-xxhash" COPYONLY)
configure_file("${LLAMA_SOURCE}/vendor/hash/sha256/LICENSE"
  "${CMAKE_CURRENT_BINARY_DIR}/LICENSE-sha256" COPYONLY)
configure_file("${LLAMA_SOURCE}/vendor/hash/rotate-bits/LICENSE.md"
  "${CMAKE_CURRENT_BINARY_DIR}/LICENSE-rotate-bits" COPYONLY)
set(llama_flutter_android_bundled_libraries
  "$<TARGET_FILE:privatelm-native>"
  "${CMAKE_CURRENT_BINARY_DIR}/LICENSE-llama.cpp"
  "${CMAKE_CURRENT_BINARY_DIR}/LICENSE-llama-flutter"
  "${CMAKE_CURRENT_BINARY_DIR}/LICENSE-xxhash"
  "${CMAKE_CURRENT_BINARY_DIR}/LICENSE-sha256"
  "${CMAKE_CURRENT_BINARY_DIR}/LICENSE-rotate-bits"
  "${CMAKE_CURRENT_SOURCE_DIR}/LICENSE-native-third-party" PARENT_SCOPE)

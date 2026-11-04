# Builds the Windows device-cluster worker. The same bundled llama.cpp tree
# as Android/iOS is used so every node speaks the same ggml RPC protocol.
cmake_minimum_required(VERSION 3.14)

set(PROJECT_NAME "llama_flutter_android")
project(${PROJECT_NAME} LANGUAGES CXX)

cmake_policy(VERSION 3.14...3.25)

set(PLUGIN_NAME "llama_flutter_android_plugin")

# ggml only: a Windows worker serves its CPU to a master. Set
# GGML_VULKAN=ON to build the Vulkan backend (needs the Vulkan SDK) and let
# the worker offer its GPU too.
set(BUILD_SHARED_LIBS OFF CACHE BOOL "" FORCE)
set(GGML_NATIVE OFF CACHE BOOL "" FORCE)
set(GGML_CCACHE OFF CACHE BOOL "" FORCE)
set(GGML_METAL OFF CACHE BOOL "" FORCE)
set(GGML_VULKAN OFF CACHE BOOL "" FORCE)
set(GGML_RPC ON CACHE BOOL "" FORCE)
set(GGML_RPC_RDMA OFF CACHE BOOL "" FORCE)
set(GGML_BLAS OFF CACHE BOOL "" FORCE)
set(GGML_OPENMP OFF CACHE BOOL "" FORCE)
set(GGML_ALL_WARNINGS OFF CACHE BOOL "" FORCE)
set(GGML_FATAL_WARNINGS OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_TESTS OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_SERVER OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_MTMD OFF CACHE BOOL "" FORCE)

add_subdirectory(
  "${CMAKE_CURRENT_SOURCE_DIR}/../android/src/main/cpp/llama.cpp"
  "${CMAKE_CURRENT_BINARY_DIR}/llama.cpp"
)

list(APPEND PLUGIN_SOURCES
  "llama_flutter_android_plugin.cpp"
  "llama_flutter_android_plugin.h"
)

add_library(${PLUGIN_NAME} SHARED
  "include/llama_flutter_android/llama_flutter_android_plugin_c_api.h"
  "llama_flutter_android_plugin_c_api.cpp"
  ${PLUGIN_SOURCES}
)

target_compile_features(${PLUGIN_NAME} PUBLIC cxx_std_17)
target_compile_options(${PLUGIN_NAME} PRIVATE /EHsc /W3 /wd4100)
target_compile_definitions(${PLUGIN_NAME} PRIVATE FLUTTER_PLUGIN_IMPL)

set_target_properties(${PLUGIN_NAME} PROPERTIES
  CXX_VISIBILITY_PRESET hidden)

target_include_directories(${PLUGIN_NAME} PRIVATE
  "${CMAKE_CURRENT_SOURCE_DIR}/../android/src/main/cpp/llama.cpp/ggml/include"
  "${CMAKE_CURRENT_SOURCE_DIR}/../android/src/main/cpp/llama.cpp/include")

target_include_directories(${PLUGIN_NAME} INTERFACE
  "${CMAKE_CURRENT_SOURCE_DIR}/include")

target_link_libraries(${PLUGIN_NAME} PRIVATE
  flutter
  flutter_wrapper_plugin
  ggml
  ggml-base
  ggml-cpu
  ggml-rpc
  ws2_32
  ole32
  psapi
)

# Everything is linked into the plugin DLL; there are no extra DLLs to copy.
set(llama_flutter_android_bundled_libraries
  ""
  PARENT_SCOPE
)

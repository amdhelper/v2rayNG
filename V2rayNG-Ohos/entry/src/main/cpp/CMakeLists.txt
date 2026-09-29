# CMake build for the v2rayNG HarmonyOS NAPI bridge.
#
# Builds libv2rayngohos.so from napi_init.cpp and copies the two lazily
# dlopen'ed cores (built by scripts/build_libv2ray_ohos.sh and
# scripts/build_hev_ohos.sh into ./prebuilt/<abi>/) into the HAP's native
# library directory so the loader can find them at runtime.
#
# NOTE: the ArkTS module name comes from napi_module.nm_modname in
#       napi_init.cpp ("v2rayngohos"); the SHARED library name here must match
#       so that `import ... from 'libv2rayngohos.so'` resolves.

cmake_minimum_required(VERSION 3.5.0)
project(v2rayngohos)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

set(NATIVEGLOBAL_TARGET_NAME v2rayngohos)

# $CMAKE_CURRENT_SOURCE_DIR/../../../.. == the entry module directory
get_filename_component(ENTRY_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../../.." ABSOLUTE)

add_library(${NATIVEGLOBAL_TARGET_NAME} SHARED
    napi_init.cpp
)

target_include_directories(${NATIVEGLOBAL_TARGET_NAME} PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}
)

target_link_libraries(${NATIVEGLOBAL_TARGET_NAME} PUBLIC
    libace_napi.z.so
    libhilog_ndk.z.so
    dl
    pthread
)

# ---------------------------------------------------------------------------
# Package the prebuilt cores next to the bridge.
# They are produced OUTSIDE the HAP build (see scripts/*.sh) because the Go one
# needs a special OpenHarmony Go toolchain that must not live in the repo.
# ---------------------------------------------------------------------------
foreach(abi_name arm64-v8a arm64)
    set(_prebuilt_dir "${CMAKE_CURRENT_SOURCE_DIR}/prebuilt/${abi_name}")
    if(EXISTS "${_prebuilt_dir}/libv2rayohos.so")
        add_custom_command(TARGET ${NATIVEGLOBAL_TARGET_NAME} POST_BUILD
            COMMAND ${CMAKE_COMMAND} -E copy_if_different
                    "${_prebuilt_dir}/libv2rayohos.so"
                    "$<TARGET_FILE_DIR:${NATIVEGLOBAL_TARGET_NAME}>/libv2rayohos.so"
            COMMENT "Packaging libv2rayohos.so (${abi_name})"
        )
        add_custom_command(TARGET ${NATIVEGLOBAL_TARGET_NAME} POST_BUILD
            COMMAND ${CMAKE_COMMAND} -E copy_if_different
                    "${_prebuilt_dir}/libhevsocks5tun.so"
                    "$<TARGET_FILE_DIR:${NATIVEGLOBAL_TARGET_NAME}>/libhevsocks5tun.so"
            COMMENT "Packaging libhevsocks5tun.so (${abi_name})"
        )
    endif()
endforeach()
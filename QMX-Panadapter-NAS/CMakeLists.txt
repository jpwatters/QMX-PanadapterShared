cmake_minimum_required(VERSION 3.16)
include($ENV{IDF_PATH}/tools/cmake/project.cmake)

# Tell LVGL's builtin memory pool to live in PSRAM (.ext_ram.bss) instead of
# internal SRAM. The LVGL ESP-IDF component does not expose this as a Kconfig
# option, so it must be injected as a compile-time define. EXT_RAM_BSS_ATTR
# expands to __attribute__((section(".ext_ram.bss"))).
# Requires CONFIG_SPIRAM_ALLOW_BSS_SEG_EXTERNAL_MEMORY=y in sdkconfig.
#
# Must be called BEFORE project() -- component registration happens INSIDE
# project() and captures COMPILE_DEFINITIONS at that point. Setting it after
# is too late and the define silently does not propagate (verified by checking
# build/compile_commands.json for lv_mem_core_builtin.c).
idf_build_set_property(COMPILE_DEFINITIONS "-DLV_ATTRIBUTE_LARGE_RAM_ARRAY=EXT_RAM_BSS_ATTR" APPEND)

# Network-radio build: report the release it is based on plus "-NAS"
# (e.g. v1.16.11-NAS) instead of git describe's v1.16.11-3-g<hash>-dirty, which
# is too long for the UI. The update check compares only the numbers before the
# first '-', so v1.16.11-NAS counts as v1.16.11.
execute_process(COMMAND git describe --tags --abbrev=0
                WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
                OUTPUT_VARIABLE QMX_BASE_TAG OUTPUT_STRIP_TRAILING_WHITESPACE ERROR_QUIET)
if(NOT QMX_BASE_TAG)
    set(QMX_BASE_TAG "v1.16.11")
endif()
set(PROJECT_VER "${QMX_BASE_TAG}-NAS")

project(qmx_panadapter)

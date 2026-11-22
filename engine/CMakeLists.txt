cmake_minimum_required(VERSION 3.16)
project(ore LANGUAGES C CXX)

# The engine is plain C with no dependencies. This file builds the static
# library and its command-line tools; the Swift package and the Rust crate
# compile the same sources directly.

if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
    set(CMAKE_BUILD_TYPE Release)
endif()
set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)
set(CMAKE_C_EXTENSIONS OFF)

set(ORE_SOURCES
    src/ore.c
    src/ore_cpu.c
    src/ore_decoder.c
    src/ore_encoder.c
    src/ore_gguf.c
    src/ore_kernels_generic.c
    src/ore_kernels_neon.c
    src/ore_kernels_avx2.c
    src/ore_kernels_sse.c
    src/ore_mel.c
    src/ore_model.c
    src/ore_threads.c)

add_library(ore STATIC ${ORE_SOURCES})
target_include_directories(ore PUBLIC include)
if(MSVC)
    target_compile_options(ore PRIVATE /W3 /fp:precise)
    # Every other compiler takes the instruction set from a function
    # attribute; MSVC takes it per file.
    set_source_files_properties(src/ore_kernels_avx2.c PROPERTIES COMPILE_OPTIONS "/arch:AVX2")
else()
    # No contraction: the code names its fused multiply-adds itself.
    target_compile_options(ore PRIVATE -Wall -Wextra -ffp-contract=off)
    if(NOT APPLE)
        target_compile_definitions(ore PRIVATE _POSIX_C_SOURCE=200809L _DEFAULT_SOURCE)
    endif()
endif()
find_package(Threads REQUIRED)
target_link_libraries(ore PUBLIC Threads::Threads)
if(UNIX AND NOT APPLE)
    target_link_libraries(ore PUBLIC m)
endif()

add_executable(kbench tools/kbench.c)
target_link_libraries(kbench PRIVATE ore)
add_executable(ore-cli tools/ore_cli.c)
target_link_libraries(ore-cli PRIVATE ore)
if(UNIX AND NOT APPLE)
    target_compile_definitions(kbench PRIVATE _POSIX_C_SOURCE=200809L)
    target_compile_definitions(ore-cli PRIVATE _POSIX_C_SOURCE=200809L)
endif()

# Comparison tools need an installed transcribe.cpp (cmake --install with
# TRANSCRIBE_INSTALL=ON); they are not part of the library.
set(ORE_TCPP_PREFIX "" CACHE PATH "Install prefix of transcribe.cpp for the comparison tools")
if(ORE_TCPP_PREFIX)
    function(ore_link_tcpp target)
        target_include_directories(${target} PRIVATE ${ORE_TCPP_PREFIX}/include)
        # The header marks its functions as DLL imports on Windows unless told
        # the library is a static archive.
        target_compile_definitions(${target} PRIVATE TRANSCRIBE_STATIC)
        target_link_directories(${target} PRIVATE ${ORE_TCPP_PREFIX}/lib ${ORE_TCPP_PREFIX}/lib64)
        target_link_libraries(${target} PRIVATE transcribe ggml ggml-cpu ggml-base Threads::Threads)
        if(APPLE)
            target_link_libraries(${target} PRIVATE "-framework Accelerate")
        elseif(UNIX)
            target_link_libraries(${target} PRIVATE m ${CMAKE_DL_LIBS})
        endif()
        set_target_properties(${target} PROPERTIES LINKER_LANGUAGE CXX)
        if(UNIX AND NOT APPLE)
            target_compile_definitions(${target} PRIVATE _POSIX_C_SOURCE=200809L)
        endif()
    endfunction()

    add_executable(tcpp-probe tools/tcpp_probe.c)
    ore_link_tcpp(tcpp-probe)

    add_executable(kbench-ggml tools/kbench.c)
    target_compile_definitions(kbench-ggml PRIVATE ORE_BENCH_GGML)
    target_link_libraries(kbench-ggml PRIVATE ore)
    ore_link_tcpp(kbench-ggml)
endif()

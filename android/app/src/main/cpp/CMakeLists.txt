cmake_minimum_required(VERSION 3.10)
project("emergency_protocol")

set(CPP_SRC_DIR "${CMAKE_CURRENT_SOURCE_DIR}")
message(STATUS "Using CPP source dir: ${CPP_SRC_DIR}")

# collect source files (only emergency_protocol.cpp expected)
set(SRC_FILES "${CPP_SRC_DIR}/emergency_protocol.cpp")

if(NOT EXISTS ${SRC_FILES})
    message(FATAL_ERROR "No emergency_protocol.cpp found in ${CPP_SRC_DIR}")
endif()

add_library(
    emergency_protocol
    SHARED
    ${SRC_FILES}
)

target_include_directories(emergency_protocol PRIVATE
    ${CPP_SRC_DIR}
)

target_compile_features(emergency_protocol PRIVATE cxx_std_17)

find_library(log-lib log)
target_link_libraries(emergency_protocol ${log-lib})

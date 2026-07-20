cmake_minimum_required(VERSION 3.8)
project(px4_offboard_cpp)

if(NOT CMAKE_CXX_STANDARD)
  set(CMAKE_CXX_STANDARD 17)
  set(CMAKE_CXX_STANDARD_REQUIRED ON)
endif()

# Default to an optimized build that still ships debug symbols. Override with
#   colcon build ... --cmake-args -DCMAKE_BUILD_TYPE=Debug
if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
  set(CMAKE_BUILD_TYPE "RelWithDebInfo" CACHE STRING
      "Choose the build type: Debug Release RelWithDebInfo MinSizeRel" FORCE)
  set_property(CACHE CMAKE_BUILD_TYPE PROPERTY STRINGS
      Debug Release RelWithDebInfo MinSizeRel)
endif()

# Per-build-type flags (full debug info in Debug; keep symbols in RelWithDebInfo).
set(CMAKE_CXX_FLAGS_DEBUG          "-O0 -g3 -ggdb -fno-omit-frame-pointer")
set(CMAKE_CXX_FLAGS_RELWITHDEBINFO "-O2 -g -DNDEBUG")

if(CMAKE_COMPILER_IS_GNUCXX OR CMAKE_CXX_COMPILER_ID MATCHES "Clang")
  add_compile_options(-Wall -Wextra -Wpedantic)
endif()

# Optional AddressSanitizer / UBSan build:
#   colcon build ... --cmake-args -DENABLE_ASAN=ON
option(ENABLE_ASAN "Build with Address/UB sanitizers" OFF)
if(ENABLE_ASAN)
  add_compile_options(-fsanitize=address,undefined -fno-omit-frame-pointer -g)
  add_link_options(-fsanitize=address,undefined)
endif()

find_package(ament_cmake REQUIRED)
find_package(rclcpp REQUIRED)
find_package(px4_msgs REQUIRED)

add_executable(offboard_control src/offboard_control.cpp)
ament_target_dependencies(offboard_control rclcpp px4_msgs)

install(TARGETS offboard_control
  DESTINATION lib/${PROJECT_NAME})

message(STATUS "px4_offboard_cpp build type: ${CMAKE_BUILD_TYPE} (ASAN=${ENABLE_ASAN})")

ament_package()

cmake_minimum_required(VERSION 3.22)
project(duatic_probe)

find_package(ament_cmake REQUIRED)
find_package(duatic_helper_msgs REQUIRED)

add_library(duatic_probe src/probe.cpp)
target_compile_features(duatic_probe PUBLIC cxx_std_17)
target_link_libraries(duatic_probe PUBLIC ${duatic_helper_msgs_TARGETS})

install(
  TARGETS duatic_probe
  ARCHIVE DESTINATION lib
  LIBRARY DESTINATION lib
  RUNTIME DESTINATION bin
)

ament_package()

cmake_minimum_required(VERSION 3.22)
project(duatic_probe_exec)

find_package(ament_cmake REQUIRED)

# No find_package(duatic_helper_msgs): the dependency is runtime-only.
install(
  FILES marker.txt
  DESTINATION share/${PROJECT_NAME}
)

ament_package()

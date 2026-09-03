cmake_minimum_required(VERSION 3.22)
project(duatic_fixture_tools)

find_package(ament_cmake REQUIRED)

install(FILES marker.txt DESTINATION share/${PROJECT_NAME})

ament_package()

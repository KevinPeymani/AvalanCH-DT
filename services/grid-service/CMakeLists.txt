cmake_minimum_required(VERSION 3.16)
project(grid_snowpack_service LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

find_package(GDAL REQUIRED)

add_executable(grid_snowpack_service
    src/main.cpp
)

target_include_directories(grid_snowpack_service PRIVATE ${GDAL_INCLUDE_DIRS})
target_link_libraries(grid_snowpack_service PRIVATE ${GDAL_LIBRARIES})

if(MSVC)
    target_compile_options(grid_snowpack_service PRIVATE /W4)
else()
    target_compile_options(grid_snowpack_service PRIVATE -Wall -Wextra -Wpedantic)
endif()

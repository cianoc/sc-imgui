cmake_minimum_required(VERSION 3.15)
project(sc_imgui_shim C CXX)

set(CMAKE_CXX_STANDARD 14)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)
set(CMAKE_C_VISIBILITY_PRESET default)
set(CMAKE_CXX_VISIBILITY_PRESET default)

set(TP ${CMAKE_CURRENT_SOURCE_DIR}/third_party)

# GLFW (static, linked into the shim)
set(BUILD_SHARED_LIBS OFF CACHE BOOL "" FORCE)
set(GLFW_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(GLFW_BUILD_TESTS OFF CACHE BOOL "" FORCE)
set(GLFW_BUILD_DOCS OFF CACHE BOOL "" FORCE)
set(GLFW_INSTALL OFF CACHE BOOL "" FORCE)
add_subdirectory(${TP}/glfw ${CMAKE_CURRENT_BINARY_DIR}/glfw EXCLUDE_FROM_ALL)

# Only one ImGui is compiled: third_party/imgui, pinned to the commit cimgui's
# generated output corresponds to. cimgui.cpp / cimplot.cpp include
# "./imgui/imgui.h" and "./implot/implot.h"; the nested submodules inside
# cimgui/ and cimplot/ are NOT initialised, so those includes resolve through
# the ${TP} include directory below to the top-level copies.
add_library(sc_imgui_shim SHARED
  ${TP}/imgui/imgui.cpp
  ${TP}/imgui/imgui_draw.cpp
  ${TP}/imgui/imgui_tables.cpp
  ${TP}/imgui/imgui_widgets.cpp
  ${TP}/imgui/imgui_demo.cpp
  ${TP}/imgui/backends/imgui_impl_glfw.cpp
  ${TP}/imgui/backends/imgui_impl_opengl3.cpp
  ${TP}/implot/implot.cpp
  ${TP}/implot/implot_items.cpp
  ${TP}/implot/implot_demo.cpp
  ${TP}/cimgui/cimgui.cpp
  ${TP}/cimplot/cimplot.cpp
  shim.cpp)

target_include_directories(sc_imgui_shim PUBLIC
  ${CMAKE_CURRENT_SOURCE_DIR}
  ${TP}/cimgui
  ${TP}/cimplot)
target_include_directories(sc_imgui_shim PRIVATE
  ${TP}
  ${TP}/imgui
  ${TP}/imgui/backends
  ${TP}/implot)

target_compile_definitions(sc_imgui_shim PUBLIC
  IMGUI_USER_CONFIG="sc_imgui_config.h")
target_compile_definitions(sc_imgui_shim PRIVATE
  IMGUI_IMPL_API=extern\ \"C\"
  IMGUI_DISABLE_OBSOLETE_FUNCTIONS=1)
if(APPLE)
  target_compile_definitions(sc_imgui_shim PRIVATE GL_SILENCE_DEPRECATION)
endif()

target_link_libraries(sc_imgui_shim PRIVATE glfw)
if(NOT APPLE)
  find_package(OpenGL REQUIRED)
  target_link_libraries(sc_imgui_shim PRIVATE OpenGL::GL)
else()
  target_link_libraries(sc_imgui_shim PRIVATE "-framework OpenGL")
endif()

enable_testing()
add_executable(test_assert test_assert.c)
target_link_libraries(test_assert PRIVATE sc_imgui_shim)
add_test(NAME test_assert COMMAND test_assert)

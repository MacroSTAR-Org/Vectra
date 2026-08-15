cmake_minimum_required(VERSION 3.14)
project(runner LANGUAGES CXX)

# Define the application target. To change its name, change BINARY_NAME in the
# top-level CMakeLists.txt, not the value here, or `flutter run` will no longer
# work.
#
# Any new source files that you add to the application should be added here.
add_executable(${BINARY_NAME} WIN32
  "flutter_window.cpp"
  "desktop_capture.cpp"
  "file_drop.cpp"
  "hit_region.cpp"
  "panel_window.cpp"
  "sidebar_window.cpp"
  "smtc.cpp"
  "main.cpp"
  "utils.cpp"
  "win32_window.cpp"
  "${FLUTTER_MANAGED_DIR}/generated_plugin_registrant.cc"
  "Runner.rc"
  "runner.exe.manifest"
)

# Apply the standard set of build settings. This can be removed for applications
# that need different build settings.
apply_standard_settings(${BINARY_NAME})

# 源码里有中文注释。MSVC 默认按系统代码页(936/GBK)读源文件，会把 UTF-8 的中文
# 误解码，轻则报 C4819（本工程 /WX 把警告当错误），重则吃掉相邻的 ASCII 字符
# 导致 #ifndef 配不上 #endif。/utf-8 明确告诉编译器源文件就是 UTF-8。
target_compile_options(${BINARY_NAME} PRIVATE "/utf-8")

# C++/WinRT（smtc.cpp 读系统媒体控件）需要协程：/std:c++17 下必须带 /await。
# 新版 MSVC 弃用了 /await + <experimental/coroutine>，会触发 STL1011 静态断言
# （本工程最初是在旧版 MSVC 上编的，没有这个断言）。静默弃用警告即可，行为不变。
target_compile_options(${BINARY_NAME} PRIVATE "/await")
target_compile_definitions(${BINARY_NAME} PRIVATE
  "_SILENCE_EXPERIMENTAL_COROUTINE_DEPRECATION_WARNINGS")

# C++/WinRT（smtc.cpp 读系统媒体控件）要求异常可用，而 apply_standard_settings
# 给所有目标加了 _HAS_EXCEPTIONS=0 —— 那是告诉 MSVC 标准库"本工程不用异常"，
# 而 winrt 的头文件里全是 try/throw，带着这个宏编不过。
#
# 只从 runner 这一个目标上摘掉它，不去动 windows/CMakeLists.txt 里的公共函数：
# 那个函数还管着所有 Flutter 插件的编译，为了一个文件改全局设置不划算。
# /EHsc 本来就在，编译器层面的异常一直是开的，这里只是把标准库的开关拨回来。
get_target_property(_runner_defs ${BINARY_NAME} COMPILE_DEFINITIONS)
if(_runner_defs)
  list(REMOVE_ITEM _runner_defs "_HAS_EXCEPTIONS=0")
  set_target_properties(${BINARY_NAME} PROPERTIES COMPILE_DEFINITIONS "${_runner_defs}")
endif()

# Add preprocessor definitions for the build version.
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION=\"${FLUTTER_VERSION}\"")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_MAJOR=${FLUTTER_VERSION_MAJOR}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_MINOR=${FLUTTER_VERSION_MINOR}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_PATCH=${FLUTTER_VERSION_PATCH}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_BUILD=${FLUTTER_VERSION_BUILD}")

# Disable Windows macros that collide with C++ standard library functions.
target_compile_definitions(${BINARY_NAME} PRIVATE "NOMINMAX")

# Add dependency libraries and include directories. Add any application-specific
# dependencies here.
target_link_libraries(${BINARY_NAME} PRIVATE flutter flutter_wrapper_app)
target_link_libraries(${BINARY_NAME} PRIVATE "dwmapi.lib")
# RegisterDragDrop/OleInitialize 在 ole32，DragQueryFile 在 shell32
target_link_libraries(${BINARY_NAME} PRIVATE "ole32.lib" "shell32.lib")
# C++/WinRT 的运行时（RoGetActivationFactory 等）在 windowsapp.lib
target_link_libraries(${BINARY_NAME} PRIVATE "windowsapp.lib")
target_include_directories(${BINARY_NAME} PRIVATE "${CMAKE_SOURCE_DIR}")

# Run the Flutter tool portions of the build. This must not be removed.
add_dependencies(${BINARY_NAME} flutter_assemble)

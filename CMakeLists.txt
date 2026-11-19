cmake_minimum_required(VERSION 3.25)
project(CirrusEngine VERSION 0.2.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")
include(CTest)

add_library(cirrus_weather src/weather.cpp)
target_include_directories(cirrus_weather PUBLIC src)
if(MSVC)
  # Public headers contain UTF-8 comments; consumers need the same source encoding.
  target_compile_options(cirrus_weather PUBLIC /utf-8 PRIVATE /W4 /permissive-)
else()
  target_compile_options(cirrus_weather PRIVATE -Wall -Wextra -Wpedantic)
endif()

if(WIN32)
  option(CIRRUS_BUILD_TEXTURE_STUDIO "Include the .NET 8 WinForms texture studio" OFF)

  add_executable(CirrusEngine WIN32 src/main.cpp src/renderer.cpp src/ui.cpp src/world.cpp src/scene_mesh.cpp src/model.cpp src/grass.cpp)
  set(CIRRUS_SHADERS shaders/common.hlsli shaders/formations.hlsli shaders/noise.hlsl shaders/clouds.hlsl shaders/atmosphere.hlsl shaders/scene.hlsl shaders/rain.hlsl shaders/lightning.hlsli shaders/mesh.hlsl shaders/geometry.hlsli)
  list(APPEND CIRRUS_SHADERS shaders/river_profile.hlsli shaders/river_water.hlsli shaders/grass.hlsl shaders/meadow.hlsli)
  # HLSL items must not become ClInclude: that runs the C++ IntelliSense parser.
  # Runtime compilation handles all entry points, so exclude FXCompile from MSBuild.
  set_source_files_properties(${CIRRUS_SHADERS} PROPERTIES VS_TOOL_OVERRIDE "None")
  set_source_files_properties(shaders/noise.hlsl shaders/clouds.hlsl shaders/atmosphere.hlsl shaders/scene.hlsl shaders/rain.hlsl shaders/mesh.hlsl shaders/grass.hlsl
    PROPERTIES VS_TOOL_OVERRIDE "FXCompile" VS_SETTINGS "ExcludedFromBuild=true" VS_SHADER_MODEL "5.0")
  target_sources(CirrusEngine PRIVATE ${CIRRUS_SHADERS} src/renderer.hpp src/ui.hpp src/weather.hpp src/cloud_formations.hpp src/cloud_volume.hpp src/world.hpp src/scene_mesh.hpp src/grass.hpp)
  source_group("Shaders" FILES ${CIRRUS_SHADERS})
  set_property(DIRECTORY PROPERTY VS_STARTUP_PROJECT CirrusEngine)
  set_target_properties(CirrusEngine PROPERTIES VS_DEBUGGER_WORKING_DIRECTORY "$<TARGET_FILE_DIR:CirrusEngine>")
  target_compile_definitions(CirrusEngine PRIVATE UNICODE _UNICODE NOMINMAX WIN32_LEAN_AND_MEAN)
  target_compile_options(CirrusEngine PRIVATE /W4 /permissive- /utf-8 /EHsc)
  target_link_libraries(CirrusEngine PRIVATE cirrus_weather d3d11 dxgi d3dcompiler windowscodecs ole32 gdi32 shell32)
  # Refresh runtime files even when the executable does not need relinking.
  add_custom_target(cirrus_shaders ALL
    COMMAND ${CMAKE_COMMAND} -E copy_directory "${CMAKE_CURRENT_SOURCE_DIR}/shaders" "$<TARGET_FILE_DIR:CirrusEngine>/shaders"
    COMMAND ${CMAKE_COMMAND} -E copy_directory "${CMAKE_CURRENT_SOURCE_DIR}/assets" "$<TARGET_FILE_DIR:CirrusEngine>/assets"
    VERBATIM)
  add_dependencies(CirrusEngine cirrus_shaders)
  if(CIRRUS_BUILD_TEXTURE_STUDIO)
    find_program(CIRRUS_DOTNET dotnet REQUIRED)
    add_custom_target(CirrusTextureStudio ALL
      COMMAND "${CMAKE_COMMAND}" -E env --unset=LIB DOTNET_CLI_UI_LANGUAGE=en-US
        "${CIRRUS_DOTNET}" publish
        "${CMAKE_CURRENT_SOURCE_DIR}/tools/CirrusTextureStudio/CirrusTextureStudio.csproj"
        --configuration "$<CONFIG>" --no-self-contained --nologo
        --artifacts-path "${CMAKE_CURRENT_BINARY_DIR}/texture-studio-artifacts"
        --output "$<TARGET_FILE_DIR:CirrusEngine>/TextureStudio"
      VERBATIM)
    add_dependencies(CirrusEngine CirrusTextureStudio)
    install(DIRECTORY "$<TARGET_FILE_DIR:CirrusEngine>/TextureStudio" DESTINATION .
      PATTERN "*.pdb" EXCLUDE)
  endif()
  install(TARGETS CirrusEngine RUNTIME DESTINATION .)
  install(DIRECTORY shaders DESTINATION .)
  install(DIRECTORY assets DESTINATION .)
  install(DIRECTORY docs DESTINATION .)
  install(DIRECTORY config DESTINATION .)
  install(FILES README.md LICENSE start.cmd weather-demo.cmd cloud-formations.cmd DESTINATION .)
  install(FILES third_party/cgltf/LICENSE DESTINATION third_party/cgltf)
  install(FILES tests/pbr-panel.gltf DESTINATION tests)
endif()

if(BUILD_TESTING)
  add_executable(weather_tests tests/weather_tests.cpp)
  target_link_libraries(weather_tests PRIVATE cirrus_weather)
  add_test(NAME weather_invariants COMMAND weather_tests)
  add_executable(formation_tests tests/formation_tests.cpp)
  target_link_libraries(formation_tests PRIVATE cirrus_weather)
  add_test(NAME formation_config COMMAND formation_tests)
  add_executable(cloud_volume_tests tests/cloud_volume_tests.cpp)
  target_link_libraries(cloud_volume_tests PRIVATE cirrus_weather)
  add_test(NAME cloud_control_volume COMMAND cloud_volume_tests)
  if(WIN32)
    add_test(NAME hlsl_compile COMMAND CirrusEngine --check-shaders --warp --headless)
    set_tests_properties(hlsl_compile PROPERTIES TIMEOUT 120)
  endif()
endif()

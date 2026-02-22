# Usage:
#   set(FFMPEG_PREBUILT_DIR "${CMAKE_SOURCE_DIR}/third_party/ffmpeg")
#   set(FFMPEG_TRIPLET "x64-linux-dynamic")
#   include(path/to/use_ffmpeg_prebuilt.cmake)
#   target_link_ffmpeg_prebuilt(your_target)

if(NOT DEFINED FFMPEG_PREBUILT_DIR)
  message(FATAL_ERROR "FFMPEG_PREBUILT_DIR is required")
endif()

if(NOT DEFINED FFMPEG_TRIPLET)
  message(FATAL_ERROR "FFMPEG_TRIPLET is required")
endif()

set(FFMPEG_ROOT "${FFMPEG_PREBUILT_DIR}/${FFMPEG_TRIPLET}")
set(FFMPEG_INCLUDE_DIR "${FFMPEG_ROOT}/include")
set(FFMPEG_LIBRARY_DIR "${FFMPEG_ROOT}/lib")

if(NOT EXISTS "${FFMPEG_INCLUDE_DIR}")
  message(FATAL_ERROR "missing FFmpeg includes: ${FFMPEG_INCLUDE_DIR}")
endif()

if(NOT EXISTS "${FFMPEG_LIBRARY_DIR}")
  message(FATAL_ERROR "missing FFmpeg libs: ${FFMPEG_LIBRARY_DIR}")
endif()

function(target_link_ffmpeg_prebuilt target_name)
  target_include_directories(${target_name} PRIVATE "${FFMPEG_INCLUDE_DIR}")
  target_link_directories(${target_name} PRIVATE "${FFMPEG_LIBRARY_DIR}")
  target_link_libraries(${target_name} PRIVATE avformat avcodec avutil swresample swscale)

  if(WIN32)
    target_link_libraries(${target_name} PRIVATE ws2_32 bcrypt)
  endif()
endfunction()

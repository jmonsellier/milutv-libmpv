# ANGLE as two DLLs (libEGL.dll, libGLESv2.dll) on the dynamic MSVC runtime, like libmpv.
# Its dependencies (zlib) are linked in statically, so the release ships no extra DLL.
set(VCPKG_TARGET_ARCHITECTURE arm64)
set(VCPKG_CRT_LINKAGE dynamic)
set(VCPKG_BUILD_TYPE release)
if(PORT STREQUAL "angle")
  set(VCPKG_LIBRARY_LINKAGE dynamic)
else()
  set(VCPKG_LIBRARY_LINKAGE static)
endif()

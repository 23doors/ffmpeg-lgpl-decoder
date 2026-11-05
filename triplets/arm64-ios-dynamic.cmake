set(VCPKG_TARGET_ARCHITECTURE arm64)
set(VCPKG_CRT_LINKAGE dynamic)
set(VCPKG_LIBRARY_LINKAGE dynamic)
set(VCPKG_CMAKE_SYSTEM_NAME iOS)
set(VCPKG_OSX_DEPLOYMENT_TARGET 11.0)
# The Darwin SDK has iconv: GNU libiconv beside it makes libxml2 use one header and the other library.
set(X_VCPKG_BUILD_GNU_LIBICONV 0)

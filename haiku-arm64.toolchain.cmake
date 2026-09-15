# CMake toolchain file for cross-compiling to Haiku arm64 with the
# aarch64-unknown-haiku gcc built by the Haiku build (cross-tools-arm64).
#
# The cross gcc was configured with --with-sysroot, so headers, startup
# objects and Haiku's own libraries are found with no flags at all. What this
# file adds is the search path for CMake's own find_path/find_library, which
# never consult the compiler's sysroot, and Haiku's develop/headers +
# develop/lib layout, which CMake does not know.
#
# CMAKE_SYSROOT is deliberately not set: it would make CMake look for
# $sysroot/usr/include, which no Haiku tree has.

set(CMAKE_SYSTEM_NAME Haiku)
set(CMAKE_SYSTEM_PROCESSOR aarch64)

set(HAIKU_CROSS_BIN "$ENV{HAIKU_CROSS_BIN}")
if(NOT HAIKU_CROSS_BIN)
    set(HAIKU_CROSS_BIN /root/gen-arm64/cross-tools-arm64/bin)
endif()
set(HAIKU_SYSROOT "$ENV{HAIKU_SYSROOT}")
if(NOT HAIKU_SYSROOT)
    set(HAIKU_SYSROOT /root/pybuild/sysroot)
endif()
set(SR ${HAIKU_SYSROOT}/boot/system)

set(CMAKE_C_COMPILER   ${HAIKU_CROSS_BIN}/aarch64-unknown-haiku-gcc)
set(CMAKE_CXX_COMPILER ${HAIKU_CROSS_BIN}/aarch64-unknown-haiku-g++)
set(CMAKE_AR           ${HAIKU_CROSS_BIN}/aarch64-unknown-haiku-ar CACHE FILEPATH "")
set(CMAKE_RANLIB       ${HAIKU_CROSS_BIN}/aarch64-unknown-haiku-ranlib CACHE FILEPATH "")
set(CMAKE_STRIP        ${HAIKU_CROSS_BIN}/aarch64-unknown-haiku-strip CACHE FILEPATH "")
set(CMAKE_NM           ${HAIKU_CROSS_BIN}/aarch64-unknown-haiku-nm CACHE FILEPATH "")
set(CMAKE_OBJCOPY      ${HAIKU_CROSS_BIN}/aarch64-unknown-haiku-objcopy CACHE FILEPATH "")

# Where find_path / find_library look. Haiku keeps headers under
# develop/headers and link-time libraries under develop/lib and lib.
set(CMAKE_FIND_ROOT_PATH ${SR})
set(CMAKE_INCLUDE_PATH ${SR}/develop/headers)
set(CMAKE_LIBRARY_PATH ${SR}/lib ${SR}/develop/lib)
set(CMAKE_PREFIX_PATH ${SR})
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY BOTH)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE BOTH)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE BOTH)

# pkg-config must answer from the sysroot only, never from the host's .pc files.
set(ENV{PKG_CONFIG_LIBDIR} ${SR}/develop/lib/pkgconfig)
set(ENV{PKG_CONFIG_PATH} "")

# CMake's Platform/Haiku.cmake adds /boot/system/develop/headers etc. as
# implicit directories; those do not exist on the host and are ignored.
set(CMAKE_CROSSCOMPILING TRUE)

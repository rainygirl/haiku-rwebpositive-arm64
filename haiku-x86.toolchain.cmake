# CMake toolchain file for cross-compiling to the x86 secondary architecture of
# an x86_gcc2 hybrid Haiku, with the i586-pc-haiku gcc built by the Haiku build
# (cross-tools-x86).
#
# A hybrid keeps the secondary architecture one level down: headers in
# develop/headers/x86, libraries in lib/x86 and develop/lib/x86, .pc files in
# develop/lib/x86/pkgconfig. Only the libraries are per-architecture -- Haiku's
# own os/ and posix/ headers are architecture-independent and live in the
# primary haiku_devel package, so they come from the source tree here instead.
#
# CMAKE_SYSROOT is deliberately not set: it would make CMake look for
# $sysroot/usr/include, which no Haiku tree has.

set(CMAKE_SYSTEM_NAME Haiku)
set(CMAKE_SYSTEM_PROCESSOR x86)

set(HAIKU_CROSS_BIN "$ENV{HAIKU_CROSS_BIN}")
if(NOT HAIKU_CROSS_BIN)
    set(HAIKU_CROSS_BIN /root/gen-x86/cross-tools-x86/bin)
endif()
set(HAIKU_SYSROOT "$ENV{HAIKU_SYSROOT}")
if(NOT HAIKU_SYSROOT)
    set(HAIKU_SYSROOT /root/x86sysroot)
endif()
set(SR ${HAIKU_SYSROOT})

set(CMAKE_C_COMPILER   ${HAIKU_CROSS_BIN}/i586-pc-haiku-gcc)
set(CMAKE_CXX_COMPILER ${HAIKU_CROSS_BIN}/i586-pc-haiku-g++)
set(CMAKE_AR           ${HAIKU_CROSS_BIN}/i586-pc-haiku-ar CACHE FILEPATH "")
set(CMAKE_RANLIB       ${HAIKU_CROSS_BIN}/i586-pc-haiku-ranlib CACHE FILEPATH "")
set(CMAKE_STRIP        ${HAIKU_CROSS_BIN}/i586-pc-haiku-strip CACHE FILEPATH "")
set(CMAKE_NM           ${HAIKU_CROSS_BIN}/i586-pc-haiku-nm CACHE FILEPATH "")
set(CMAKE_OBJCOPY      ${HAIKU_CROSS_BIN}/i586-pc-haiku-objcopy CACHE FILEPATH "")

# The startup objects (crti.o, crtn.o, start_dyn.o, init_term_dyn.o) and the
# target's libgcc/libstdc++ live in the sysroot, not in the cross toolchain, and
# gcc does not look for them along -L. -B is what puts a directory on its search
# path for those, so without it every link fails with "cannot find crti.o".
set(HAIKU_X86_LIBDIR ${SR}/develop/lib/x86)
set(CMAKE_C_FLAGS_INIT "-B${HAIKU_X86_LIBDIR}")
set(CMAKE_CXX_FLAGS_INIT "-B${HAIKU_X86_LIBDIR}")

# The secondary architecture's third-party headers come first, because the
# primary architecture of this hybrid is x86_gcc2 and its develop/headers/c++
# is gcc 2's -- picking that up in a gcc 13 build goes badly. Haiku's own
# headers are architecture-independent and come from the primary haiku_devel.
# Every subdirectory of develop/headers/os, because Haiku's headers are
# included by bare name -- <SupportDefs.h>, <Errors.h> -- and each kit keeps its
# own directory. On a native build the compiler's specs carry these; the cross
# toolchain built here has an empty sysroot, so they have to be listed.
file(GLOB HAIKU_OS_HEADER_DIRS LIST_DIRECTORIES true ${SR}/develop/headers/os/*)
foreach(d ${HAIKU_OS_HEADER_DIRS})
    if(IS_DIRECTORY ${d})
        list(APPEND HAIKU_HEADER_PATH ${d})
    endif()
endforeach()

include_directories(SYSTEM
    ${SR}/develop/headers/x86
    ${SR}/develop/headers/os
    ${HAIKU_HEADER_PATH}
    ${SR}/develop/headers/posix
    ${SR}/develop/headers/private/system
    ${SR}/develop/headers/private/system/arch/x86
    ${SR}/develop/headers
)
link_directories(${SR}/lib/x86 ${SR}/develop/lib/x86)

set(CMAKE_FIND_ROOT_PATH ${SR})
set(CMAKE_INCLUDE_PATH ${SR}/develop/headers/x86)
set(CMAKE_LIBRARY_PATH ${SR}/lib/x86 ${SR}/develop/lib/x86)
set(CMAKE_PREFIX_PATH ${SR})
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY BOTH)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE BOTH)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE BOTH)

# pkg-config must answer from the sysroot only, never from the host's .pc files.
set(ENV{PKG_CONFIG_LIBDIR} ${SR}/develop/lib/x86/pkgconfig)
set(ENV{PKG_CONFIG_PATH} "")

set(CMAKE_CROSSCOMPILING TRUE)

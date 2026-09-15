#!/bin/bash
#
# Cross-build HaikuWebKit 1.10.0 (JavaScriptCore + WebCore + WebKitLegacy)
# for Haiku arm64, and install it into a staging tree the packaging script
# turns into haikuwebkit / haikuwebkit_devel .hpkg files.
#
# Runs inside the haiku-builder container, after build-webkit-deps-arm64.sh
# has filled the sysroot and haikuwebkit-1.10.0-arm64.patch has been applied
# to the source tree.
#
# Usage: build-haikuwebkit-arm64.sh [configure|build|install|all]
#
set -eu

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CROSS_BIN="${HAIKU_CROSS_BIN:-/root/gen-arm64/cross-tools-arm64/bin}"
SYSROOT="${HAIKU_SYSROOT:-/root/pybuild/sysroot}"
SR=$SYSROOT/boot/system
WK="${WK:-/root/wk}"
SRC="${WEBKIT_SRC:-$WK/haikuwebkit}"
BUILD="${WEBKIT_BUILD:-$WK/webkit-build}"
STAGE="${WEBKIT_STAGE:-$WK/webkit-stage}"
TOOLCHAIN="${TOOLCHAIN:-$HERE/haiku-arm64.toolchain.cmake}"
# Compiles of WebCore's unified sources take well over a gigabyte each with
# gcc; on a 7 GB container more than five at once gets one of them killed.
JOBS="${JOBS:-5}"
STEP="${1:-all}"

export PATH=$CROSS_BIN:$PATH
# WTF's PlatformHaiku.cmake picks the private arch headers by this variable;
# on a native build the shell exports it.
export BE_HOST_CPU=arm64
export PKG_CONFIG_LIBDIR=$SR/develop/lib/pkgconfig
export PKG_CONFIG_PATH=

configure() {
	mkdir -p "$BUILD"
	# Choices, and why:
	#  ENABLE_JIT=ON, ENABLE_DFG_JIT=ON, ENABLE_FTL_JIT=OFF: baseline + DFG
	#    JITs. The first port ran LLInt only and was verified; the JIT tiers
	#    are what make JavaScript-heavy pages usable. FTL (B3) stays off for
	#    now: it is the largest and least-exercised tier on a new OS.
	#  USE_CXX_STDLIB_ASSERTIONS=OFF: WebKit turns on _GLIBCXX_ASSERTIONS by
	#    default even in Release; that is bounds checking on every libstdc++
	#    container access, not something a shipping browser wants.
	#  ENABLE_WEBASSEMBLY=OFF: out of scope here.
	#  USE_AVIF=ON: libavif and its dav1d decoder are built by the deps
	#    script. Decode only -- no encoder, so no rav1e. WOFF2 and LCMS come
	#    from the same script.
	#  ENABLE_LAYOUT_TESTS=OFF, ENABLE_API_TESTS=OFF, DEVELOPER_MODE=OFF:
	#    no DumpRenderTree, no test binaries; they cannot run here anyway.
	#  CMAKE_INSTALL_PREFIX=/boot/system: DATA_DIR and the inspector path are
	#    compiled in from it, so it has to be the real runtime location;
	#    the install step relocates with DESTDIR.
	#  -ftrack-macro-expansion=0 --param ggc-min-expand=10: the flags the
	#    HaikuPorts recipe uses to keep gcc's memory use down.
	cmake -S "$SRC" -B "$BUILD" -G Ninja \
		-DPORT=Haiku \
		-DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN" \
		-DCMAKE_BUILD_TYPE=Release \
		-DCMAKE_INSTALL_PREFIX=/boot/system \
		-DHAIKU_SYSTEM_DIR="$SR" \
		-DENABLE_JIT=ON -DENABLE_DFG_JIT=ON -DENABLE_FTL_JIT=OFF -DENABLE_C_LOOP=OFF \
		-DUSE_CXX_STDLIB_ASSERTIONS=OFF \
		-DENABLE_WEBASSEMBLY=OFF -DENABLE_SAMPLING_PROFILER=OFF \
		-DUSE_AVIF=ON -DUSE_JPEGXL=OFF -DUSE_LCMS=ON -DUSE_WOFF2=ON \
		-DENABLE_WEBGL=OFF \
		-DENABLE_LAYOUT_TESTS=OFF -DENABLE_API_TESTS=OFF -DDEVELOPER_MODE=OFF \
		-DSHOULD_INSTALL_JS_SHELL=ON \
		-DCMAKE_CXX_FLAGS="-ftrack-macro-expansion=0 --param ggc-min-expand=10" \
		-DCMAKE_C_FLAGS="-ftrack-macro-expansion=0" \
		"$@"
}

build() {
	ninja -C "$BUILD" -j "$JOBS" -k 0 "$@"
}

install() {
	rm -rf "$STAGE"
	DESTDIR="$STAGE" ninja -C "$BUILD" install
	# The devel symlinks a Haiku package expects: develop/lib/libX.so ->
	# ../../lib/libX.so, so an application links against the runtime copy.
	S=$STAGE/boot/system
	mkdir -p "$S/develop/lib"
	for f in "$S"/lib/*.so; do
		n=$(basename "$f")
		ln -sf "../../lib/$n" "$S/develop/lib/$n"
	done
	echo "staged in $STAGE:"
	find "$S" -maxdepth 2 | sort | head -40
}

case "$STEP" in
	configure) shift; configure "$@" ;;
	build)     shift; build "$@" ;;
	install)   install ;;
	all)       configure; build; install ;;
	*) echo "usage: $0 [configure|build|install|all]" >&2; exit 2 ;;
esac

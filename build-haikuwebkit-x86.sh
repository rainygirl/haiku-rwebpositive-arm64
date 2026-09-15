#!/bin/bash
#
# Cross-build HaikuWebKit 1.9.19 for the x86 secondary architecture of an
# x86_gcc2 hybrid -- the configuration the VAIO P runs -- and package it as a
# drop-in replacement for the official haikuwebkit_x86 hpkg.
#
# This is the x86 counterpart of build-haikuwebkit-arm64.sh. It targets 1.9.19
# rather than 1.10.0 because that is what the machine's other packages were
# built against, and it carries haikuwebkit-1.9.19-x86.patch, which is the
# subset of the arm64 leak fixes that applies to 1.9.19. The largest arm64 leak
# is absent here: it came from WTF_OVERRIDE_DELETE_FOR_CHECKED_PTR destroying
# PathHaiku's operator delete, and 1.9.19's PathImpl does not use that macro.
#
# Usage: build-haikuwebkit-x86.sh [sysroot|patch|configure|build|install|package|verify|all]
#
set -eu

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CROSS_BIN="${HAIKU_CROSS_BIN:-/root/gen-x86/cross-tools-x86/bin}"
SR="${HAIKU_SYSROOT:-/root/x86sysroot}"
WK="${WK:-/root/wk86}"
SRC="${WEBKIT_SRC:-$WK/haikuwebkit}"
BUILD="${WEBKIT_BUILD:-$WK/build}"
STAGE="${WEBKIT_STAGE:-$WK/stage}"
PKGDIR="${PKGDIR:-$WK/pkg}"
TOOLCHAIN="${TOOLCHAIN:-$HERE/haiku-x86.toolchain.cmake}"
TARBALL="${TARBALL:-/root/haikuwebkit-1.9.19.tar.gz}"
# The official package this one replaces. Its .PackageInfo is the source of
# truth for "requires" and for the NEEDED check in the verify step.
OFFICIAL="${OFFICIAL:-/root/x86pkgs/haikuwebkit_x86-1.9.19-2-x86_gcc2.hpkg}"
PACKAGE_TOOL="${PACKAGE_TOOL:-/root/gen-a64/objects/linux/x86_64/release/tools/package/package}"
REVISION="${REVISION:-3}"
JOBS="${JOBS:-9}"
STEP="${1:-all}"

export PATH=$CROSS_BIN:$PATH
export BE_HOST_CPU=x86
export PKG_CONFIG_LIBDIR=$SR/develop/lib/x86/pkgconfig
export PKG_CONFIG_PATH=

# WTF/PlatformHaiku.cmake hardcodes /system/develop/headers/private/... .
# Rather than patch the source -- the patch that ships should carry the bug
# fixes and nothing else -- point /system at the sysroot.
[ -e /system ] || ln -s "$SR" /system

# Haiku's POSIX headers have to come AFTER the compiler's own, not before.
# libstdc++ reaches stdlib.h with #include_next, which resumes the search past
# the directory the including header was found in, so a -isystem that puts
# Haiku's posix directory first is skipped over and the header is reported
# missing. -idirafter appends instead.
# gnu/ and bsd/ must precede posix/: pthread_getattr_np lives in the first and
# link.h in the second, and their headers reach the posix ones with
# #include_next, so they have to be found first.
HAIKU_INC="-idirafter $SR/develop/headers/gnu"
HAIKU_INC="$HAIKU_INC -idirafter $SR/develop/headers/bsd"
HAIKU_INC="$HAIKU_INC -idirafter $SR/develop/headers/posix"
HAIKU_INC="$HAIKU_INC -idirafter $SR/develop/headers"

step_sysroot() {
	# The sysroot's library sonames must match the target machine's, not just
	# satisfy the package's "requires" list. Those are different things: a
	# package can declare requires: lib:libavif_x86>=16.4.2, be accepted by the
	# package system, and still ship a binary whose DT_NEEDED says
	# libavif.so.13 -- which the runtime loader then refuses. That exact
	# mismatch shipped once here. avif is called out because the sysroot came
	# with 0.9.3 (soname 13) while the machine has 1.4.2 (soname 16).
	echo "== sysroot: avif =="
	local have
	have=$(readlink "$SR/develop/lib/x86/libavif.so" 2>/dev/null || echo none)
	echo "   develop/lib/x86/libavif.so -> $have  (must be libavif.so.16)"
	case "$have" in
	libavif.so.16) ;;
	*)
		echo "   fetching libavif1.0_x86 1.4.2 from HaikuPorts"
		local base=https://eu.hpkg.haiku-os.org/haikuports/master/build-packages
		mkdir -p "$WK/avif" && cd "$WK/avif"
		for f in libavif1.0_x86-1.4.2-1-x86_gcc2.hpkg \
			 libavif1.0_x86_devel-1.4.2-1-x86_gcc2.hpkg; do
			[ -f "$f" ] || curl -fsSL -o "$f" "$base/packages/$f"
			"$PACKAGE_TOOL" extract -C "$SR" "$f"
		done
		;;
	esac
	# ninja stats the symlink target, not the link, and a package's files carry
	# the mtime they had upstream -- older than an object built yesterday. A
	# freshly installed library therefore looks stale to nothing and no relink
	# happens, with ninja still exiting 0. Make it newer.
	touch "$SR/lib/x86/libavif.so.16.4.2" "$SR/develop/headers/x86/avif/avif.h" 2>/dev/null || true

	# develop/headers/os is on the include path but its subdirectories are not,
	# and Screen.h reaches for <Accelerant.h>, which lives in
	# os/add-ons/graphics. Link the add-ons headers up one level rather than
	# adding a compiler flag: changing the flags rehashes every command line
	# and rebuilds the whole tree. Do not flatten os/ wholesale -- arch/*/
	# holds one arch_debugger.h per architecture, and ISA.h, PCI.h and USB.h
	# would shadow the ones already there.
	echo "== sysroot: os/add-ons headers =="
	( cd "$SR/develop/headers/os/add-ons" &&
	  find . -mindepth 2 -name '*.h' | while read -r h; do
		ln -sf "${h#./}" "$(basename "$h")"
	  done )
	echo "   Accelerant.h -> $(readlink "$SR/develop/headers/os/add-ons/Accelerant.h")"
}

step_patch() {
	echo "== unpack and patch =="
	mkdir -p "$WK" && cd "$WK"
	[ -d "$SRC" ] || tar xzf "$TARBALL"
	cd "$WK" && patch -p0 -N < "$HERE/haikuwebkit-1.9.19-x86.patch" || true
	# ThirdParty/ANGLE is absent from the release tarball but CMake still walks
	# into it. WebGL is off, so an unbuilt copy is enough to satisfy the walk.
	[ -d "$SRC/Source/ThirdParty/ANGLE" ] || {
		echo "   Source/ThirdParty/ANGLE is missing; copy it in from a git checkout" >&2
		exit 1
	}
}

step_configure() {
	echo "== configure =="
	cmake -S "$SRC" -B "$BUILD" -G Ninja \
		-DPORT=Haiku \
		-DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN" \
		-DCMAKE_BUILD_TYPE=Release \
		-DCMAKE_INSTALL_PREFIX=/boot/system \
		-DCMAKE_HAIKU_SECONDARY_ARCH=x86 \
		-DCMAKE_HAIKU_SECONDARY_ARCH_SUBDIR=/x86 \
		-DUSE_CXX_STDLIB_ASSERTIONS=OFF \
		-DENABLE_WEBASSEMBLY=OFF -DENABLE_SAMPLING_PROFILER=OFF \
		-DUSE_AVIF=ON -DUSE_JPEGXL=OFF -DUSE_LCMS=ON -DUSE_WOFF2=ON \
		-DENABLE_WEBGL=OFF \
		-DENABLE_LAYOUT_TESTS=OFF -DENABLE_API_TESTS=OFF -DDEVELOPER_MODE=OFF \
		-DSHOULD_INSTALL_JS_SHELL=ON \
		`# CMAKE_*_STANDARD_LIBRARIES is appended at the very END of the link
		 # line, which is what makes it the right lever for two ordering
		 # problems. libPAL.a references WTF::ucsdet_detectAll_span but comes
		 # after libWTF.a, and static archives resolve left to right, so the
		 # definition is already past. And libshared.a needs _Unwind_Resume,
		 # which this --disable-shared cross GCC does not pull in on its own;
		 # Haiku's own x86 shared libraries all link libgcc_s.so.1, so match
		 # them. Naming one symbol here fixes its whole class at once.` \
		-DCMAKE_CXX_STANDARD_LIBRARIES="$BUILD/lib/libWTF.a -lgcc_s" \
		-DCMAKE_C_STANDARD_LIBRARIES="-lgcc_s" \
		`# No JIT flags on purpose: WebKitFeatures.cmake gives 32-bit x86 the
		 # else() branch -- JIT off, C_LOOP on -- because upstream WebKit has
		 # no JIT for this architecture. Forcing ENABLE_JIT=ON the way the
		 # arm64 build does yields 160 copies of "DFG and FTL JIT require
		 # baseline JIT to be enabled" and nothing else.` \
		-DCMAKE_CXX_FLAGS="-B$SR/develop/lib/x86 $HAIKU_INC -ftrack-macro-expansion=0 --param ggc-min-expand=10" \
		-DCMAKE_C_FLAGS="-B$SR/develop/lib/x86 $HAIKU_INC -ftrack-macro-expansion=0"
}

step_build() {
	echo "== build =="
	ninja -C "$BUILD" -j"$JOBS"
	# Exit status is not the result here. ninja has reported 0 with nothing
	# relinked (see the mtime note in step_sysroot), so check the artifact.
	ls -la "$BUILD/lib/libWebKitLegacy.so.1.9.19"
}

step_install() {
	echo "== install to staging =="
	DESTDIR="$STAGE" ninja -C "$BUILD" install
}

step_package() {
	echo "== package =="
	local S=$STAGE/boot/system
	mkdir -p "$PKGDIR"/bin "$PKGDIR"/data/WebKit "$PKGDIR"/data/licenses "$PKGDIR"/lib/x86
	# Exactly the official layout. develop/headers and the unversioned .so
	# symlinks belong to haikuwebkit_x86_devel; shipping them here collides
	# with that package.
	cp -a "$S/bin/jsc" "$PKGDIR/bin/"
	cp -a "$S/data/WebKit/Directory Listing Template.html" "$PKGDIR/data/WebKit/"
	"$PACKAGE_TOOL" extract -C "$PKGDIR" "$OFFICIAL" "data/licenses/WebKit Apple"
	cp -a "$S/lib/x86/libJavaScriptCore.so.18.7.4" "$PKGDIR/lib/x86/"
	cp -a "$S/lib/x86/libWebKitLegacy.so.1.9.19" "$PKGDIR/lib/x86/"
	ln -sf libJavaScriptCore.so.18.7.4 "$PKGDIR/lib/x86/libJavaScriptCore.so.18"
	ln -sf libWebKitLegacy.so.1.9.19 "$PKGDIR/lib/x86/libWebKitLegacy.so.1"

	# The requires list in this file is the official one, copied verbatim.
	# Anything stricter can demand an upgrade the target machine has no way to
	# satisfy, and pkgman update must never be run there.
	sed "s/^version\t\t\t1\.9\.19-.*/version\t\t\t1.9.19-$REVISION/" \
		"$HERE/haikuwebkit-x86.PackageInfo" > "$PKGDIR/.PackageInfo"
	grep -q "^version.*1\.9\.19-$REVISION" "$PKGDIR/.PackageInfo" ||
		{ echo "   could not set the revision in .PackageInfo" >&2; exit 1; }
	"$PACKAGE_TOOL" create -C "$PKGDIR" \
		"$WK/haikuwebkit_x86-1.9.19-$REVISION-x86_gcc2.hpkg"
}

step_verify() {
	# The check that matters, and the one whose absence shipped a broken
	# package once: compare DT_NEEDED of the library inside the package against
	# the official one. A matching "requires" list does not imply matching
	# sonames.
	echo "== verify: DT_NEEDED against the official package =="
	local t=$WK/verify
	mkdir -p "$t/a" "$t/b"
	"$PACKAGE_TOOL" extract -C "$t/a" "$OFFICIAL" lib/x86/libWebKitLegacy.so.1.9.19
	"$PACKAGE_TOOL" extract -C "$t/b" \
		"$WK/haikuwebkit_x86-1.9.19-$REVISION-x86_gcc2.hpkg" \
		lib/x86/libWebKitLegacy.so.1.9.19
	needed() {
		i586-pc-haiku-readelf -d "$1" | sed -n 's/.*NEEDED.*\[\(.*\)\]/\1/p' | sort
	}
	if diff <(needed "$t/a/lib/x86/libWebKitLegacy.so.1.9.19") \
		<(needed "$t/b/lib/x86/libWebKitLegacy.so.1.9.19"); then
		echo "   NEEDED identical to the official package"
	else
		echo "   NEEDED differs -- do not install this package" >&2
		exit 1
	fi
}

case "$STEP" in
sysroot)   step_sysroot ;;
patch)     step_patch ;;
configure) step_configure ;;
build)     step_build ;;
install)   step_install ;;
package)   step_package ;;
verify)    step_verify ;;
all)       step_sysroot; step_patch; step_configure; step_build
           step_install; step_package; step_verify ;;
*)         echo "usage: $0 [sysroot|patch|configure|build|install|package|verify|all]" >&2
           exit 1 ;;
esac

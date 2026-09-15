#!/bin/bash
#
# Feed the cross-built HaikuWebKit packages to the Haiku arm64 build, build
# WebPositive with jam, and produce a RENKU arm64 ISO that has both.
#
# How WebPositive gets built: src/apps/webpositive/Jamfile compiles it only
# when the "webkit" build feature is enabled, and build/jam/BuildFeatures
# enables that when a haikuwebkit_devel package is available in the
# repository for the architecture. So the two packages are listed in
# build/jam/repositories/HaikuPorts/arm64 and dropped into the download
# directory under the names jam expects; jam finds them there and never
# tries the network for them.
#
# How they get into the image: the haikuwebkit runtime package goes in via
# the local package hook in build/jam/images/HaikuImage, WebPositive via
# AddOptionalHaikuImagePackages in build/jam/DefaultBuildProfiles. Both are
# tracked files, so this does not depend on a UserBuildConfig this script
# happens to have written.
#
# Runs inside the haiku-builder container.
#
# Usage: build-webpositive-image-arm64.sh [prepare|webpositive|image|all]
#
set -eu

WK="${WK:-/root/wk}"
G="${RENKU_GEN:-/root/gen-kd}"
TREE="${RENKU_TREE:-/root/haiku-arm64}"
PKGS="${WEBKIT_PACKAGES:-$WK/packages}"
JAM_BIN="${JAM_BIN:-/haiku-build/buildtools/jam/bin.linuxx86}"
JOBS="${JOBS:-8}"
VER=1.10.0-2
SSL_VER=3.5.4-1
SSH_VER=10.4p1-1
CJK_VER=2.004-1
STEP="${1:-all}"
export PATH=$JAM_BIN:$PATH
# Setting this in UserBuildConfig is too late for the repository rules; it
# has to be in jam's environment. See the note in prepare().
export HAIKU_NO_DOWNLOADS=1

prepare() {
	for p in haikuwebkit haikuwebkit_devel; do
		[ -f "$PKGS/$p-$VER-arm64.hpkg" ] || { echo "missing $PKGS/$p-$VER-arm64.hpkg" >&2; exit 1; }
	done

	# 1. The repository list. jam names packages "<name>-<version>"; the file
	#    it then looks for is "<name>-<version>-arm64.hpkg".
	REPO=$TREE/build/jam/repositories/HaikuPorts/arm64
	if ! grep -q "^	haikuwebkit-$VER$" "$REPO"; then
		# Insert after the gcc_syslibs_devel line, keeping the list sorted the
		# way upstream keeps it.
		sed -i "/^	gcc_syslibs_devel-.*bootstrap-1$/a\\
	haikuwebkit-$VER\\
	haikuwebkit_devel-$VER" "$REPO"
		echo "added haikuwebkit to $REPO"
	fi

	# 1b. OpenSSL 3 and OpenSSH (package-ssl-ssh-arm64.sh). openssl3_devel in
	#     the list also switches on the tree's "openssl" build feature, so
	#     libbnetapi and friends get TLS. The python package is re-cut without
	#     its bundled OpenSSL so the two don't collide in packagefs.
	for entry in openssl3-$SSL_VER openssl3_devel-$SSL_VER openssh-$SSH_VER; do
		grep -q "^	$entry$" "$REPO" || sed -i "/^	haikuwebkit_devel-$VER$/a\\
	$entry" "$REPO"
	done

	# 1c. Noto Sans CJK (package-cjk-font-arm64.sh), so Korean, Japanese and
	#     Chinese text is not drawn as empty boxes. It is an "any" package,
	#     hence the other section of the list. The profile installs it; this
	#     only makes the repository aware of it.
	grep -q "^	noto_sans_cjk_kr-$CJK_VER$" "$REPO" || sed -i "/^	noto-20170202_bootstrap-7$/a\
	noto_sans_cjk_kr-$CJK_VER" "$REPO"

	# 2. The package files, where the download rules expect them and where
	#    the local-package hook reads them.
	mkdir -p "$G/download" "$TREE/data/renku-packages"
	cp -f "$PKGS/haikuwebkit-$VER-arm64.hpkg" "$PKGS/haikuwebkit_devel-$VER-arm64.hpkg" "$G/download/"
	cp -f "$PKGS/haikuwebkit-$VER-arm64.hpkg" "$TREE/data/renku-packages/"
	for p in openssl3-$SSL_VER openssl3_devel-$SSL_VER openssh-$SSH_VER; do
		[ -f "$PKGS/$p-arm64.hpkg" ] && cp -f "$PKGS/$p-arm64.hpkg" "$G/download/"
	done
	[ -f "$PKGS/noto_sans_cjk_kr-$CJK_VER-any.hpkg" ] \
		&& cp -f "$PKGS/noto_sans_cjk_kr-$CJK_VER-any.hpkg" "$G/download/"
	if [ -f "$PKGS/python3.14-3.14.7-2-arm64.hpkg" ]; then
		rm -f "$TREE"/data/renku-packages/python3.14-3.14.7-1-arm64.hpkg
		cp -f "$PKGS/python3.14-3.14.7-2-arm64.hpkg" "$TREE/data/renku-packages/"
	fi
	# A stale extraction from an earlier package would be used as-is.
	rm -rf "$G/build_packages/haikuwebkit-$VER-arm64" "$G/build_packages/haikuwebkit_devel-$VER-arm64" \
	       "$G/build_packages/openssl3-$SSL_VER-arm64" "$G/build_packages/openssl3_devel-$SSL_VER-arm64"

	# 2b. Anything HaikuPorts ships with heap compression 2 (zstd) is invisible
	#     to this kernel: packagefs is built without zstd, because the arm64
	#     bootstrap repository has no zstd package to enable the build feature.
	#     Such a package sits in /boot/system/packages and is never activated,
	#     with no error anywhere. Re-create those with the build's own package
	#     tool, which writes zlib. Bytes 18-19 of the file hold the field.
	PKGTOOL=$(find "$G/objects/linux" /root/gen-arm64/objects/linux -name package -type f -perm -u+x 2>/dev/null | head -1)
	for hp in "$G"/download/*.hpkg; do
		[ -f "$hp" ] || continue
		[ "$(od -A n -t x1 -j 18 -N 2 "$hp" | tr -d ' ')" = "0002" ] || continue
		T=$(mktemp -d)
		( cd "$T" && "$PKGTOOL" extract "$hp" >/dev/null && "$PKGTOOL" create -q "$T.hpkg" )
		cp -f "$hp" "$hp.zstd-original"
		mv -f "$T.hpkg" "$hp"
		rm -rf "$T"
		echo "re-created $(basename "$hp") with zlib compression"
	done

	# 3. UserBuildConfig: everything the image gets beyond @minimum-anyboot.
	#    The RENKU_* lines reproduce what build-renku-arm64.sh writes, so the
	#    image keeps python, gn/ninja, clang and the development packages
	#    (AGENTS.md in renku-arm64 describes them).
	LOCAL_PKGS=$(cd "$TREE/data/renku-packages" && ls *.hpkg | tr '\n' ' ')
	# Other sessions add their own lines to this file, so replace only our
	# own block and keep everything else. The markers delimit what we own.
	UBC=$TREE/build/jam/UserBuildConfig
	BEGIN="# >>> build-webpositive-image-arm64.sh"
	END="# <<< build-webpositive-image-arm64.sh"
	if [ -f "$UBC" ]; then
		python3 - "$UBC" "$BEGIN" "$END" <<'PRUNE'
import sys
path, begin, end = sys.argv[1], sys.argv[2], sys.argv[3]
lines = open(path).read().splitlines(True)
out, skip = [], False
for line in lines:
    if line.startswith(begin):
        skip = True
        continue
    if line.startswith(end):
        skip = False
        continue
    if not skip:
        out.append(line)
open(path, "w").writelines(out)
PRUNE
	fi
	cat >> "$UBC" <<EOF
$BEGIN

# Adding packages to the repository list changes its checksum, and jam then
# tries to fetch "<checksum>/repo" from the HaikuPorts server, which does not
# exist for a local list (HTTP 404). With downloads off, jam builds the
# repository index from the .hpkg files already in the download directory
# instead, which is all of them. This one has to be set before the repository
# file is read, so exporting it into jam's environment (below) is what
# actually takes effect; it is repeated here for a jam run started by hand.
HAIKU_NO_DOWNLOADS = 1 ;

# A compiler in the image is useless without headers and startup objects.
RENKU_EXTRA_SYSTEM_PACKAGES = haiku_devel.hpkg ;
RENKU_INCLUDE_DEVEL_PACKAGES = 1 ;

# WebPositive itself, the CJK font, ca_root_certificates, openssl3 and
# openssh are no longer listed here. They live in build/jam/DefaultBuildProfiles
# under the arm64 arm of the minimum profile, which is a tracked file, so a
# fresh tree or a second build directory gets them too. The local package
# directory is picked up by build/jam/images/HaikuImage on its own.
$END
EOF
	echo "wrote our block in $UBC:"; sed -n "/^$BEGIN/,/^$END/p" "$UBC"
}

webpositive() {
	cd "$G"
	jam -q -j"$JOBS" WebPositive 2>&1 | tail -20
	local bin
	bin=$(find "$G/objects/haiku/arm64/release/apps/webpositive" -maxdepth 1 -name WebPositive -type f | head -1)
	[ -n "$bin" ] || { echo "WebPositive did not build" >&2; exit 1; }
	file "$bin"
	jam -q -j"$JOBS" webpositive.hpkg 2>&1 | tail -40
	ls -la "$G"/objects/haiku/arm64/packaging/packages/webpositive.hpkg
}

image() {
	cd "$G"
	# haiku-boot-cd is a temporary of the anyboot target and deleted after a
	# successful build, so a later @minimum-anyboot fails without it.
	jam -q -j"$JOBS" haiku-boot-cd 2>&1 | tail -5
	jam -q -j"$JOBS" @minimum-anyboot 2>&1 | tail -20
	ls -la "$G/haiku-minimum-anyboot.iso"
}

case "$STEP" in
	prepare)     prepare ;;
	webpositive) webpositive ;;
	image)       image ;;
	all)         prepare; webpositive; image ;;
	*) echo "usage: $0 [prepare|webpositive|image|all]" >&2; exit 2 ;;
esac

#!/bin/bash
#
# Package the cross-built OpenSSL 3 and OpenSSH for Haiku arm64, and re-cut
# the python3.14 package so it stops bundling OpenSSL (two packages shipping
# lib/libssl.so.3 would collide in packagefs).
#
#   openssl3-3.5.4-1-arm64.hpkg        libssl, libcrypto, the openssl tool
#   openssl3_devel-3.5.4-1-arm64.hpkg  headers, link symlinks, .pc files;
#                                      what turns on the Haiku tree's "openssl"
#                                      build feature (SSL in libbnetapi etc.)
#   openssh-10.4p1-1-arm64.hpkg        ssh, sshd and friends, laid out as the
#                                      HaikuPorts recipe does it
#   python3.14-3.14.7-2-arm64.hpkg     python without libssl/libcrypto/sqlite
#                                      duplicates of the new packages
#
# Runs inside the haiku-builder container after the OpenSSL and OpenSSH
# builds (see the README). Names follow HaikuPorts so the repository list
# entries are "openssl3-3.5.4-1" etc.
#
set -eu

WK="${WK:-/root/wk}"
G="${RENKU_GEN:-/root/gen-arm64-kd2}"
TREE="${RENKU_TREE:-/root/haiku-renku}"
CROSS_BIN="${HAIKU_CROSS_BIN:-/root/gen-arm64/cross-tools-arm64/bin}"
PB="${PYBUILD_DIR:-/root/pybuild}"
OUTDIR="${1:-$WK/packages}"
PKG=$(find /root/gen-arm64/objects/linux "$G/objects/linux" -name package -type f -perm -u+x 2>/dev/null | head -1)
STRIP=$CROSS_BIN/aarch64-unknown-haiku-strip
HL=$TREE/data/system/data/licenses
[ -n "$PKG" ] || { echo "no package tool" >&2; exit 1; }
mkdir -p "$OUTDIR"

SSL_VER=3.5.4
SSL_STAGE=$WK/ssl-stage/boot/system
SSH_VER=10.4p1
SSH_STAGE=$WK/ssh-stage/boot/system
[ -f "$SSL_STAGE/lib/libssl.so.3" ] || { echo "no OpenSSL install at $SSL_STAGE" >&2; exit 1; }
[ -f "$SSH_STAGE/bin/ssh" ] || { echo "no OpenSSH install at $SSH_STAGE" >&2; exit 1; }

mkpkg() {  # <dir> <output>
	rm -f "$2"
	( cd "$1" && "$PKG" create -q "$2" )
	echo "built $2 ($(du -h "$2" | cut -f1))"
}

# ---------------------------------------------------------------- openssl3
B=$WK/pkg/openssl3; D=$WK/pkg/openssl3_devel
rm -rf "$B" "$D"; mkdir -p "$B/lib" "$B/bin" "$B/data/licenses" "$D/develop/lib/pkgconfig" "$D/develop/headers" "$D/data/licenses"
cp -a "$SSL_STAGE"/lib/libssl.so.3 "$SSL_STAGE"/lib/libcrypto.so.3 "$B/lib/"
[ -d "$SSL_STAGE/lib/ossl-modules" ] && cp -a "$SSL_STAGE/lib/ossl-modules" "$B/lib/"
[ -d "$SSL_STAGE/lib/engines-3" ] && cp -a "$SSL_STAGE/lib/engines-3" "$B/lib/"
cp -a "$SSL_STAGE"/bin/openssl "$B/bin/"
# openssl.cnf and the CA bundle both live in data/ssl (the ca_root_certificates
# package supplies the bundle).
if [ -d "$WK/ssl-stage/boot/system/data/ssl" ]; then
	mkdir -p "$B/data/ssl"; cp -a "$WK/ssl-stage/boot/system/data/ssl/." "$B/data/ssl/"
fi
# OpenSSL's built-in default verify file is $OPENSSLDIR/cert.pem, and nothing
# installs a file by that name: ca_root_certificates ships the bundle as
# CARootCertificates.pem. So every program that verifies with the library
# defaults -- SSL_CTX_set_default_verify_file(), which is what Haiku's
# libnetapi SecureSocket uses, and so pkgman -- fails with "unable to get
# local issuer certificate" on any https URL, while WebPositive works because
# WebKit points curl at the bundle by name. Link the default at it.
mkdir -p "$B/data/ssl"
ln -sf CARootCertificates.pem "$B/data/ssl/cert.pem"
$STRIP --strip-unneeded "$B"/lib/*.so.3 "$B"/bin/openssl "$B"/lib/ossl-modules/*.so 2>/dev/null || true
cp "$HL/Apache v2" "$B/data/licenses/Apache v2"; cp "$HL/Apache v2" "$D/data/licenses/Apache v2"
cat > "$B/.PackageInfo" <<EOF
name			openssl3
version			$SSL_VER-1
architecture		arm64
summary			"The OpenSSL toolkit, a TLS/SSL and crypto library"
description		"OpenSSL $SSL_VER cross-compiled for Haiku arm64 (no assembler
optimisations: OpenSSL has no Haiku arm64 target, this is the haiku-x86_64
configuration with the word-size flag removed)."
packager		"The RENKU project"
vendor			"Haiku Project"
licenses {
	"Apache v2"
}
copyrights {
	"1998-2025 The OpenSSL Project Authors"
}
provides {
	openssl3 = $SSL_VER compat >= 3
	cmd:openssl = $SSL_VER
	lib:libcrypto = 3 compat >= 3
	lib:libssl = 3 compat >= 3
}
requires {
	haiku
	lib:libz
}
urls {
	"https://www.openssl.org/"
}
EOF
# devel: headers, link-time symlinks into the runtime package, .pc files
cp -a "$SSL_STAGE/include/openssl" "$D/develop/headers/openssl"
ln -s ../../lib/libssl.so.3 "$D/develop/lib/libssl.so"
ln -s ../../lib/libcrypto.so.3 "$D/develop/lib/libcrypto.so"
for pc in "$SSL_STAGE"/lib/pkgconfig/*.pc; do
	sed -e 's|^prefix=.*|prefix=/boot/system|' -e 's|^exec_prefix=.*|exec_prefix=${prefix}|' \
	    -e 's|^libdir=.*|libdir=${prefix}/develop/lib|' -e 's|^includedir=.*|includedir=${prefix}/develop/headers|' \
	    "$pc" > "$D/develop/lib/pkgconfig/$(basename "$pc")"
done
cat > "$D/.PackageInfo" <<EOF
name			openssl3_devel
version			$SSL_VER-1
architecture		arm64
summary			"The OpenSSL toolkit (development files)"
description		"Headers and link libraries for OpenSSL $SSL_VER on Haiku arm64."
packager		"The RENKU project"
vendor			"Haiku Project"
licenses {
	"Apache v2"
}
copyrights {
	"1998-2025 The OpenSSL Project Authors"
}
provides {
	openssl3_devel = $SSL_VER
	devel:libcrypto = 3 compat >= 3
	devel:libssl = 3 compat >= 3
}
requires {
	openssl3 == $SSL_VER base
}
EOF
mkpkg "$B" "$OUTDIR/openssl3-$SSL_VER-1-arm64.hpkg"
mkpkg "$D" "$OUTDIR/openssl3_devel-$SSL_VER-1-arm64.hpkg"

# ------------------------------------------------------------------ openssh
# Lay the DESTDIR install out the way the HaikuPorts recipe's INSTALL() does.
S=$WK/pkg/openssh; rm -rf "$S"; mkdir -p "$S/bin" "$S/lib" "$S/settings/ssh" "$S/data/openssh/empty" "$S/data/licenses" "$S/boot/post-install"
cp -a "$SSH_STAGE"/bin/* "$S/bin/"
[ -d "$SSH_STAGE/sbin" ] && cp -a "$SSH_STAGE"/sbin/* "$S/bin/"		# Haiku has no sbin; the service file runs /boot/system/bin/sshd
cp -a "$SSH_STAGE/lib/openssh" "$S/lib/openssh"
cp -a "$SSH_STAGE"/settings/ssh/* "$S/settings/ssh/"
install -m 755 "$WK/sshb/openssh-$SSH_VER/contrib/ssh-copy-id" "$S/bin/ssh-copy-id"
# The recipe's path fixes: user keys live in the user settings directory,
# and sshd's pid/privsep/libexec paths must be the real system locations.
sed -i -e 's| ~/\.ssh/| /boot/home/config/settings/ssh/|' "$S/settings/ssh/ssh_config"
# Every Haiku account is uid 0, and OpenSSH decides "is this root?" by uid, so
# the stock "PermitRootLogin prohibit-password" refuses a password login for
# *every* user on Haiku. Without this line sshd runs and authenticates nothing.
printf '\n# Haiku: every account is uid 0, so the default prohibit-password\n# setting would refuse password logins for all users.\nPermitRootLogin yes\n' \
	>> "$S/settings/ssh/sshd_config"
cp "$S/settings/ssh/ssh_config" "$S/data/openssh/ssh_config.default"
cp "$S/settings/ssh/sshd_config" "$S/data/openssh/sshd_config.default"
cp "$WK/ssh/sshd_keymaker.sh" "$WK/ssh/fix_openssh_config_paths.sh" "$S/boot/post-install/"
# net_server's settings/network/services also names an "ssh" service, but on
# this image it never starts it, so give the launch_daemon its own job.
#
# It launches a wrapper rather than sshd itself. The launch_daemon starts
# services before the package_daemon runs a package's first-boot scripts, so
# at that moment sshd_keymaker.sh has not run and there are no host keys --
# sshd exits immediately with "no hostkeys available". The wrapper generates
# them if they are missing and then becomes sshd.
mkdir -p "$S/data/launch" "$S/lib/openssh"
cat > "$S/lib/openssh/sshd-launch" <<'WRAP'
#!/bin/sh
# Generate host keys if the first-boot script has not run yet, then exec sshd.
dir="$(finddir B_SYSTEM_SETTINGS_DIRECTORY)/ssh"
mkdir -p "$dir"
for type in rsa ecdsa ed25519; do
	if [ ! -f "$dir/ssh_host_${type}_key" ]; then
		/boot/system/bin/ssh-keygen -q -t "$type" -f "$dir/ssh_host_${type}_key" -N "" || exit 1
	fi
done
exec /boot/system/bin/sshd -D
WRAP
chmod 755 "$S/lib/openssh/sshd-launch"
cat > "$S/data/launch/sshd" <<'LAUNCH'
service x-vnd.openssh-sshd {
	launch /boot/system/lib/openssh/sshd-launch
	legacy
	no_safemode
}
LAUNCH
chmod 755 "$S"/boot/post-install/*.sh
cp "$WK/sshb/openssh-$SSH_VER/LICENCE" "$S/data/licenses/OpenSSH"
$STRIP --strip-unneeded "$S"/bin/* "$S"/lib/openssh/* 2>/dev/null || true
cat > "$S/.PackageInfo" <<EOF
name			openssh
version			$SSH_VER-1
architecture		arm64
summary			"The OpenSSH secure shell: ssh, scp, sftp and sshd"
description		"OpenSSH $SSH_VER cross-compiled for Haiku arm64, with the HaikuPorts
patch set. Host keys are generated on first boot by the post-install script;
sshd is started by the net_server ssh service (settings/network/services)."
packager		"The RENKU project"
vendor			"Haiku Project"
licenses {
	"OpenSSH"
}
copyrights {
	"2005-2025 Tatu Ylonen et al."
}
provides {
	openssh = $SSH_VER compat >= 5
	cmd:scp = $SSH_VER compat >= 5
	cmd:sftp = $SSH_VER compat >= 5
	cmd:ssh = $SSH_VER compat >= 5
	cmd:ssh_add = $SSH_VER compat >= 5
	cmd:ssh_agent = $SSH_VER compat >= 5
	cmd:ssh_copy_id = $SSH_VER compat >= 5
	cmd:ssh_keygen = $SSH_VER compat >= 5
	cmd:ssh_keyscan = $SSH_VER compat >= 5
	cmd:sshd = $SSH_VER compat >= 5
}
requires {
	haiku
	lib:libcrypto
	lib:libssl
	lib:libz
}
users {
	sshd real-name "sshd user" home "/packages/openssh-$SSH_VER-1/.self/data/openssh/empty" shell "/bin/true" groups "sshd"
}
groups {
	sshd
}
post-install-scripts {
	"boot/post-install/sshd_keymaker.sh"
	"boot/post-install/fix_openssh_config_paths.sh"
}
global-writable-files {
	"settings/ssh/ssh_config" keep-old
	"settings/ssh/sshd_config" keep-old
}
urls {
	"https://www.openssh.com/"
}
EOF
mkpkg "$S" "$OUTDIR/openssh-$SSH_VER-1-arm64.hpkg"

# ------------------------------------------------- python3.14 without OpenSSL
# Same tree the python packaging script uses, minus the OpenSSL runtime and
# headers, which the openssl3 packages now own. SQLite, xz, bzip2, readline
# stay (nothing else provides them).
P=$WK/pkg/python314; rm -rf "$P"; mkdir -p "$P"
cp -a "$PB/stage/boot/system/." "$P/"
rm -f "$P"/lib/libssl.so* "$P"/lib/libcrypto.so* "$P"/develop/lib/libssl.so* "$P"/develop/lib/libcrypto.so* "$P"/develop/lib/pkgconfig/libssl.pc "$P"/develop/lib/pkgconfig/libcrypto.pc "$P"/develop/lib/pkgconfig/openssl.pc
rm -rf "$P/develop/headers/openssl" "$P/bin/openssl"
mkdir -p "$P/data/licenses"
L="$P/data/licenses"
cp "$PB/Python-3.14.7/LICENSE" "$L/Python Software Foundation License"
for pair in "Public Domain" "BSD (2-clause)" "GNU GPL v3"; do cp "$HL/$pair" "$L/$pair"; done
cat > "$P/.PackageInfo" <<EOF
name			python3.14
version			3.14.7-2
architecture		arm64
summary			"An interpreted, interactive, object-oriented programming language"
description		"Python 3.14, cross-compiled for Haiku arm64. Revision 2 no longer
bundles OpenSSL: it comes from the openssl3 package now. SQLite, xz, bzip2
and readline are still carried here, since the arm64 repository has none."
packager		"The RENKU project"
vendor			"Haiku Project"
licenses {
	"Python Software Foundation License"
	"Public Domain"
	"BSD (2-clause)"
	"GNU GPL v3"
}
copyrights {
	"2001-2026 Python Software Foundation"
	"2000-2025 D. Richard Hipp (SQLite, public domain)"
	"1996-2010 Julian R Seward (bzip2)"
	"2005-2024 The Tukaani Project (xz)"
	"1987-2022 Free Software Foundation (readline)"
}
provides {
	python3.14 = 3.14.7
	cmd:python3 = 3.14.7
	cmd:python3.14 = 3.14.7
	lib:libpython3.14 = 3.14.7
	lib:libsqlite3 = 3.50.4
	lib:liblzma = 5.6.3
	lib:libbz2 = 1.0.8
	lib:libreadline = 8.2
	lib:libhistory = 8.2
}
requires {
	haiku
	lib:libz
	lib:libffi
	lib:libncursesw
	lib:libssl
	lib:libcrypto
}
urls {
	"https://www.python.org/"
}
EOF
mkpkg "$P" "$OUTDIR/python3.14-3.14.7-2-arm64.hpkg"
ls -la "$OUTDIR"

#!/bin/bash
# Build the multikernel kernel on a Fedora host and export it in the
# layout bootc expects. Does not touch the build host's /boot: it copies
# the architecture's boot image instead of running "make install".
#
#   ./build-kernel.sh
#   KVER=$(cat kbuild/KVER)
#
# Overrides:
#   REPO=...      kernel source URL (default: multikernel/linux)
#   REF=...       tag/branch to clone (default: the remote default branch;
#                 v7.0-mk4 is the current release tag)
#   SRC=...       existing source tree (skips clone; survives rebuilds)
#   CONFIG=...    starting config (default: /boot/config-$(uname -r);
#                 CONFIG=defconfig is a faster but less complete build)
#   STRIP_MODULES=0
#                 keep module debug info (default: strip it; the Fedora
#                 config otherwise produces ~7 GB of modules and a ~600 MB
#                 initramfs)
#   PATCHES=0     do not apply patches/*.patch to the source tree
#                 (default: apply them; already-applied patches are
#                 detected and skipped)
#   OUT=...       export directory (default: <script dir>/kbuild)
#   JOBS=...      build parallelism
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
repo=${REPO:-https://github.com/multikernel/linux.git}
ref=${REF:-}
src=${SRC:-$here/linux}
config=${CONFIG:-/boot/config-$(uname -r)}
out=${OUT:-$here/kbuild}
jobs=${JOBS:-$(nproc)}
strip_modules=${STRIP_MODULES:-1}
patches=${PATCHES:-1}

die() { printf 'build-kernel: %s\n' "$*" >&2; exit 1; }
note() { printf 'build-kernel: %s\n' "$*" >&2; }

if [ "$config" != defconfig ] && [ ! -r "$config" ]; then
	die "config $config not readable; set CONFIG="
fi

for tool in gcc make flex bison bc depmod; do
	command -v "$tool" >/dev/null || die "$tool not found"
done

# A source tree from a tarball or a previous build is reused as-is.
if [ ! -f "$src/Makefile" ] || [ ! -x "$src/scripts/config" ]; then
	if [ -d "$src" ] && [ -n "$(ls -A "$src" 2>/dev/null)" ]; then
		die "$src exists and is not a kernel source tree; set SRC="
	fi
	if [ -n "$ref" ]; then
		note "cloning $repo at $ref (shallow)"
		git clone --depth=1 --branch "$ref" "$repo" "$src"
	else
		note "cloning $repo (shallow)"
		git clone --depth=1 "$repo" "$src"
	fi
fi

cd "$src"
if [ "$patches" = 1 ] && [ -d "$here/patches" ]; then
	for p in "$here"/patches/*.patch; do
		[ -f "$p" ] || continue
		name=$(basename "$p")
		if git apply --check "$p" 2>/dev/null; then
			git apply "$p"
			note "applied $name"
		elif git apply --check --reverse "$p" 2>/dev/null; then
			note "already applied: $name"
		else
			die "cannot apply $name (set PATCHES=0 to skip)"
		fi
	done
fi

if [ "$config" = defconfig ]; then
	note "starting from make defconfig"
	make defconfig
else
	cp "$config" .config
fi

opts=(
	VSOCKETS
	MULTIKERNEL
	MULTIKERNEL_VSOCKETS
	MKTTY
	MEMORY_HOTPLUG
	MEMORY_HOTREMOVE
	CONTIG_ALLOC
	KEXEC_FILE
	CRASH_DUMP
	EROFS_FS
	EROFS_FS_BACKED_BY_FILE
)
args=()
for opt in "${opts[@]}"; do
	args+=(--enable "$opt")
done
./scripts/config "${args[@]}"
make olddefconfig

grep -q '^CONFIG_MULTIKERNEL=y$' .config ||
	die "CONFIG_MULTIKERNEL did not stick: is this a multikernel tree?"
grep -qE '^CONFIG_MULTIKERNEL_VSOCKETS=[ym]$' .config ||
	die "CONFIG_MULTIKERNEL_VSOCKETS did not stick"
if grep -q '^CONFIG_MULTIKERNEL_VSOCKETS=m$' .config; then
	note "mk_transport is a module; set 'modules = mk_transport' in kmorph.conf"
fi

note "building with $jobs jobs"
make -j"$jobs"

kver=$(make -s kernelrelease)
case $(uname -m) in
x86_64) image=arch/x86/boot/bzImage ;;
aarch64|arm64) image=arch/arm64/boot/Image ;;
*) die "unsupported build architecture $(uname -m)" ;;
esac
[ -f "$image" ] || die "boot image $image not found"

rm -rf "$out"
mkdir -p "$out"
if [ "$strip_modules" = 1 ] && grep -q '^CONFIG_MODULE_SIG_FORCE=y$' .config; then
	note "CONFIG_MODULE_SIG_FORCE is set; keeping module debug info"
	strip_modules=0
fi
if [ "$strip_modules" = 1 ]; then
	make modules_install INSTALL_MOD_PATH="$out" INSTALL_MOD_STRIP=1
else
	make modules_install INSTALL_MOD_PATH="$out"
fi
install -m0644 "$image" "$out/vmlinuz"
install -m0644 .config "$out/config"
if [ -f System.map ]; then
	install -m0644 System.map "$out/System.map"
fi
printf '%s\n' "$kver" > "$out/KVER"

note "kernel $kver exported to $out"

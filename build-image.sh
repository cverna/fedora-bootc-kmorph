#!/bin/bash
# Build a disk image from a bootc container image with bootc-image-builder.
#
#   ./build-image.sh localhost/fedora-bootc-kmorph:dev
#   LOCAL=1 ./build-image.sh localhost/fedora-bootc-kmorph:dev
#
# The result is output/<type>/disk.<ext>.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
image=${1:?usage: build-image.sh IMAGE_REF}
out=${OUT:-$here/output}
type=${TYPE:-qcow2}
rootfs=${ROOTFS:-ext4}
builder=${BUILDER:-quay.io/centos-bootc/bootc-image-builder:latest}

mkdir -p "$out"

args=(
	podman run --rm --privileged
	--security-opt label=type:unconfined_t
	-v /var/lib/containers/storage:/var/lib/containers/storage
	-v "$out":/output
)
if [ -n "${CONFIG_TOML:-}" ]; then
	args+=(-v "$CONFIG_TOML":/config.toml)
fi

args+=(
	"$builder"
	--type "$type"
	--rootfs "$rootfs"
)
if [ "${LOCAL:-0}" = 1 ]; then
	args+=(--local)
fi
args+=("$image")

printf 'build-image: %s\n' "${args[*]}" >&2
"${args[@]}"

printf 'build-image: image written under %s\n' "$out" >&2

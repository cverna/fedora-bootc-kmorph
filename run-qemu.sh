#!/bin/bash
# Boot a qcow2 produced by build-image.sh with UEFI firmware and no
# Secure Boot.
#
#   ./run-qemu.sh output/qcow2/disk.qcow2
#
# MEM, CPUS and VARS override the defaults. The firmware variable store
# is copied next to the disk image on first use.
set -euo pipefail

disk=${1:?usage: run-qemu.sh DISK_IMAGE}
mem=${MEM:-4096}
cpus=${CPUS:-4}

# build-image.sh produces qcow2, bootc install to-disk produces raw.
if [ -n "${FORMAT:-}" ]; then
	format=$FORMAT
else
	format=$(qemu-img info --output=json "$disk" 2>/dev/null |
		jq -r '.format // "raw"' 2>/dev/null) || format=raw
fi

# SNAPSHOT=1 keeps writes in a temporary overlay.
snapshot=
if [ "${SNAPSHOT:-0}" = 1 ]; then
	snapshot=",snapshot=on"
fi

# VIRTIO_CONSOLE=1 attaches a virtio-serial console (hvc0). Unlike the
# PL011 platform serial, it is a PCI function the successor can adopt, so
# it gives the successor a console after a takeover.
vc=()
if [ "${VIRTIO_CONSOLE:-0}" = 1 ]; then
	hvc_log=${HVC_LOG:-$(dirname "$disk")/mk-hvc.log}
	vc=(-chardev "file,id=vc0,path=$hvc_log" \
		-device virtio-serial-pci -device virtconsole,chardev=vc0)
fi

accel=()
case ${ACCEL:-auto} in
kvm)
	accel=(-enable-kvm -cpu host)
	;;
tcg)
	accel=(-accel tcg,thread=multi -cpu max)
	;;
*)
	if [ -w /dev/kvm ]; then
		# On aarch64 KVM needs -cpu host; without it KVM init fails
		# with EINVAL.
		accel=(-enable-kvm -cpu host)
	else
		# Slow but portable.
		accel=(-accel tcg,thread=multi -cpu max)
	fi
	;;
esac

case $(uname -m) in
x86_64)
	firmware=/usr/share/OVMF/OVMF_CODE.fd
	vars=/usr/share/OVMF/OVMF_VARS.fd
	machine=q35
	;;
aarch64)
	firmware=/usr/share/AAVMF/AAVMF_CODE.fd
	vars=/usr/share/AAVMF/AAVMF_VARS.fd
	# The multikernel spawn path needs GICv3 (mk_dtb rejects a GICv2
	# MADT); QEMU's TCG default is GICv2, so ask for v3 explicitly.
	machine="virt,gic-version=${GIC_VERSION:-3}"
	;;
*)
	echo "run-qemu: unsupported architecture $(uname -m)" >&2
	exit 2
	;;
esac

[ -r "$firmware" ] || {
	echo "run-qemu: $firmware not found (install edk2-ovmf or edk2-aarch64)" >&2
	exit 2
}

vstore=${VARS:-$(dirname "$disk")/efivars.fd}
[ -f "$vstore" ] || cp "$vars" "$vstore"

netdev=user,id=net0
if [ -n "${SSH_PORT:-}" ]; then
	netdev="$netdev,hostfwd=tcp::${SSH_PORT}-:22"
fi

exec "qemu-system-$(uname -m)" \
	-machine "$machine" -m "$mem" -smp "$cpus" "${accel[@]}" \
	-drive if=pflash,format=raw,readonly=on,file="$firmware" \
	-drive if=pflash,format=raw,file="$vstore" \
	-drive "if=virtio,format=$format,file=$disk$snapshot" \
	"${vc[@]}" \
	-netdev "$netdev" -device virtio-net-pci,netdev=net0 \
	-nographic

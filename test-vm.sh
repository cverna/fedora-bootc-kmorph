#!/bin/bash
# Boot an installed kmorph test VM, wait for the successor to arm, and
# optionally crash the predecessor to exercise the takeover.
#
#   ./test-vm.sh /path/to/disk.raw
#   CRASH=1 ./test-vm.sh /path/to/disk.raw
#
# The disk must be prepared by prepare-test-disk.sh (root password and
# SSH enabled; default password "kmorph"). Runs on the KVM/TCG host,
# beside run-qemu.sh. Writes the serial log next to the disk as
# mk-boot.log unless LOG= is set.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
disk=${1:?usage: test-vm.sh DISK}
password=${PASSWORD:-kmorph}
port=${SSH_PORT:-2222}
cpus=${CPUS:-2}
mem=${MEM:-4096}
crash=${CRASH:-0}
snapshot=${SNAPSHOT:-1}
accel=${ACCEL:-auto}
vc=${VIRTIO_CONSOLE:-0}
hvc=${HVC_LOG:-$(dirname "$disk")/mk-hvc.log}
log=${LOG:-$(dirname "$disk")/mk-boot.log}

ssh_opts=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
	-o ConnectTimeout=4 -o ServerAliveInterval=15 -p "$port")
guest() { sshpass -p "$password" ssh "${ssh_opts[@]}" root@127.0.0.1 "$@"; }
say() { printf 'test-vm: %s\n' "$*" >&2; }

if pgrep -f "[q]emu-system.*$disk" >/dev/null; then
	say "a QEMU for $disk is already running; stop it first"
	exit 1
fi

say "booting $disk (accel=$accel, cpus=$cpus, mem=$mem)"
setsid env SNAPSHOT="$snapshot" ACCEL="$accel" CPUS="$cpus" MEM="$mem" \
	SSH_PORT="$port" VIRTIO_CONSOLE="$vc" HVC_LOG="$hvc" \
	"$here/run-qemu.sh" "$disk" >"$log" 2>&1 </dev/null &
if [ "$vc" = 1 ]; then
	say "virtio console on hvc0 -> $hvc"
fi

wait_ssh() {
	local i
	for ((i = 1; i <= 150; i++)); do
		guest true 2>/dev/null && return 0
		sleep 2
	done
	return 1
}

if ! wait_ssh; then
	say "guest SSH did not come up; see $log"
	tail -20 "$log" >&2 || true
	exit 1
fi
say "guest SSH is up"

armed=0
for i in $(seq 1 60); do
	status=$(guest 'kmorph status 2>&1' || true)
	say "status[$i]: $status"
	case "$status" in
	*ARMED*) armed=1; break ;;
	esac
	sleep 5
done

guest '
  echo "== uname"; uname -r
  echo "== multikernel"; ls -l /sys/fs/multikernel 2>&1 | head
  echo "== status"; kmorph status 2>&1
  echo "== instance"; cat /sys/fs/multikernel/instances/*/status 2>&1
  echo "== dmesg"; dmesg | tail -15
'

if [ "$armed" != 1 ]; then
	say "successor did not arm"
	guest 'systemctl --no-pager --lines=30 status kmorph 2>&1; journalctl -u kmorph -b --no-pager 2>&1 | tail -30' || true
	exit 1
fi

if [ "$crash" != 1 ]; then
	say "armed; not crashing (set CRASH=1)"
	exit 0
fi

say "crashing predecessor"
guest 'sync; echo c > /proc/sysrq-trigger' || true

if ! wait_ssh; then
	say "successor SSH did not come back; see $log"
	exit 1
fi
say "successor SSH is back"
sleep 5
guest '
  echo "== uname"; uname -r
  echo "== status"; kmorph status 2>&1
  echo "== state"; cat /run/kmorph/state 2>&1
  echo "== instance"; cat /sys/fs/multikernel/instances/*/status 2>&1
  echo "== dmesg"; dmesg | tail -25
'

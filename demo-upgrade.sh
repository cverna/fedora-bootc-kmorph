#!/bin/bash
# kmorph on Fedora bootc: live update demo.
#
# Stages a new bootc image that carries a new kernel, arms that staged
# deployment as the kmorph successor, and takes over.  The machine ends
# up running the new image and the new kernel without rebooting.
#
# Runs on a host that can reach the VM's sshd (run-qemu.sh defaults).
# PAUSE sets the base delay after each block so the recording is readable.
set -uo pipefail

SSH_PORT=${SSH_PORT:-2222}
SSH_PASS=${SSH_PASS:-kmorph}
IMAGE=${IMAGE:-10.0.2.2:5000/fedora-bootc-kmorph:upgrade}
PAUSE=${PAUSE:-3}

opts=(-q -o LogLevel=ERROR -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
      -o ConnectTimeout=4 -o ServerAliveInterval=15 -p "$SSH_PORT")
# Guest commands run with a pty so programs print their normal, human
# output (bootc status prints YAML without a tty).
g()  { sshpass -p "$SSH_PASS" ssh -tt "${opts[@]}" root@127.0.0.1 "$@"; }
# Internal polling only; no pty.
gq() { sshpass -p "$SSH_PASS" ssh "${opts[@]}" root@127.0.0.1 "$@"; }

step() { printf '\n\033[1;36m# %s\033[0m\n' "$*"; }
note() { printf '\033[2m# %s\033[0m\n' "$*"; }
cmd()  { printf '\033[1m[old]\033[0m $ %s\n' "$*"; }
cmd_new() { printf '\033[1m[new]\033[0m $ %s\n' "$*"; }
# Commands run without a pty; only bootc status needs one, so it prints
# its human form instead of YAML.
run()  { cmd "$*"; gq "$@"; }
run_new() { cmd_new "$*"; gq "$@"; }
run_status() { cmd "bootc status"; g 'bootc status'; }
run_status_new() { cmd_new "bootc status"; g 'bootc status'; }
# hold the screen so the output can be read
hold() { sleep "${1:-$PAUSE}"; }

qemu_pid() { pgrep -f '[q]emu-system-aarch64' | head -1; }

qpid=$(qemu_pid)
printf '\033[1mkmorph + Fedora bootc: live update of image and kernel, no reboot\033[0m\n'
note "2-vCPU Fedora 45 bootc VM (arm64) on bare-metal KVM"
hold 4

step "1/5  the running system"
run uname -r
hold 2
run kmorph status
hold 4
run_status
hold 8
note "qemu pid $qpid (host)"
hold 3

step "2/5  stage a new bootc image carrying the new kernel"
note "same base image, so only the kernel layers are new"
run bootc switch "$IMAGE"
hold 4
run_status
hold 9

step "3/5  finalize the staged deployment (BLS entry + /etc merge)"
run ostree admin finalize-staged
hold 4
run_status
note "bootc now reports the deployment as a queued rollback"
hold 8

step "4/5  arm the staged deployment as the live successor"
run systemctl stop kmorph
hold 2
run /run/kmorph/kmorph-bootc arm --staged
hold 7

armed=0
for _ in $(seq 1 60); do
	s=$(gq 'kmorph status' 2>/dev/null || true)
	case "$s" in *ARMED*) armed=1; break ;; esac
	sleep 1
done
[ "$armed" = 1 ] || { printf '# successor did not arm\n'; exit 1; }
run kmorph status
hold 5

step "5/5  take over: same VM, no reboot"
note "the handover freezes the old kernel; this ssh session will drop"
run kmorph upgrade --config /run/kmorph/mk.conf
note "waiting for the successor"

back=0
for _ in $(seq 1 120); do
	if gq true 2>/dev/null; then back=1; break; fi
	sleep 1
done
[ "$back" = 1 ] || { printf '# successor did not come back\n'; exit 1; }
hold 2

run_new uname -r
hold 3
run_status_new
hold 9
run_new cat /run/kmorph/state
hold 3
now=$(qemu_pid)
if [ "$now" = "$qpid" ]; then
	note "qemu pid $now (host, unchanged)"
else
	note "qemu pid $qpid -> $now (host)"
fi
hold 6

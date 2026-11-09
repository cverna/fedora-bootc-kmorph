#!/bin/bash
# Recorded demo: kmorph crash takeover on a Fedora bootc host.
# Run on the KVM host with the test VM already booted and its successor ARMED.
set -uo pipefail

port=${SSH_PORT:-2222}
password=${PASSWORD:-kmorph}
log=${LOG:-$HOME/mk-hvc.log}
opts=(-q -o LogLevel=ERROR -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
      -o ConnectTimeout=4 -o ServerAliveInterval=15 -p "$port")
g()  { sshpass -p "$password" ssh "${opts[@]}" root@127.0.0.1 "$@"; }
gt() { sshpass -p "$password" ssh -tt "${opts[@]}" root@127.0.0.1 "$@"; }
say() { printf '\n\033[1;36m## %s\033[0m\n' "$*"; }
show() { printf '\n\033[1;33m$ %s\033[0m\n' "$1"; shift; "$@"; }

say "kmorph on Fedora bootc: a crash takeover without rebooting the machine"

say "The bootc host is running the multikernel kernel, and has armed a successor kernel."
show "bootc status (on the bootc host)" gt 'bootc status'
show "kmorph status" g 'kmorph status'
show "successor instance state" g 'cat /sys/fs/multikernel/instances/*/status'
sleep 2

say "The successor is a separate kernel instance, alive beside the running one."
show "the successor is probing this kernel" g 'cat /sys/fs/multikernel/instances/*/status; kmorph status'
sleep 2

say "Now kill the running kernel. The QEMU machine stays up; only the kernel dies."
show "echo c > /proc/sysrq-trigger" g 'sync; echo c > /proc/sysrq-trigger' || true
sleep 1

say "The successor notices the silence, fences the dead kernel, and adopts its devices, CPU and memory."
for _ in $(seq 1 20); do grep -q 'state TAKEN_OVER' "$log" 2>/dev/null && break; sleep 1; done
grep -aE 'Host fenced|adopted [0-9]+ devices|adopted [0-9]+ CPUs|state TAKEN_OVER' "$log" | tail -6
sleep 2

say "The same bootc deployment is running again, now on the successor kernel."
for _ in $(seq 1 60); do g true 2>/dev/null && break; sleep 2; done
sleep 1
show "bootc status (on the successor)" gt 'bootc status'
show "uname -r" g 'uname -r'
show "takeover state" g 'cat /run/kmorph/state'
sleep 1

qpid=$(pgrep -f '[q]emu-system-aarch64' | head -1)
say "The VM itself never rebooted: QEMU pid $qpid is still the same process."
ps -p "$qpid" -o pid=,etime=,comm=
say "The bootc deployment, /etc and /var are the same; only the kernel changed."

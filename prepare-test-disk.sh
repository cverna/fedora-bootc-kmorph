#!/bin/bash
# Prepare an installed bootc disk for the kmorph test VM.
#
# Sets a test root password with SSH password login, and ensures SELinux
# is off in the boot entries. The kmorph config itself (memory, console)
# comes from the image; keep `console` unset on arm64.
#
#   sudo ./prepare-test-disk.sh /path/to/disk.raw [PASSWORD]
#
# The disk must be a raw image whose second partition is the bootc root
# (what `bootc install to-disk` produces).
set -euo pipefail

disk=${1:?usage: prepare-test-disk.sh DISK [PASSWORD]}
password=${2:-kmorph}

[ "$(id -u)" = 0 ] || { echo "prepare-test-disk: run as root" >&2; exit 2; }
[ -f "$disk" ] || { echo "prepare-test-disk: $disk not found" >&2; exit 2; }
command -v openssl >/dev/null || { echo "prepare-test-disk: openssl not found" >&2; exit 2; }

mnt=$(mktemp -d)
loop=$(losetup --partscan --find --show "$disk")
cleanup() {
	umount "$mnt" 2>/dev/null || true
	losetup -d "$loop" 2>/dev/null || true
	rmdir "$mnt" 2>/dev/null || true
}
trap cleanup EXIT

mount "${loop}p2" "$mnt"
conf=$(find "$mnt" -path '*/etc/kmorph/kmorph.conf' | head -1)
[ -n "$conf" ] || { echo "prepare-test-disk: no kmorph.conf in the deployment" >&2; exit 1; }
dep=${conf%/etc/kmorph/kmorph.conf}

hash=$(openssl passwd -6 -salt kmorph "$password")
python3 - "$dep/etc/shadow" "$dep/etc/ssh/sshd_config" "$hash" <<'PY'
import sys
shadow, sshd, h = sys.argv[1:4]
lines = open(shadow).read().splitlines()
for i, line in enumerate(lines):
    if line.startswith('root:'):
        f = line.split(':')
        f[1] = h
        lines[i] = ':'.join(f)
open(shadow, 'w').write('\n'.join(lines) + '\n')
s = open(sshd).read().splitlines()
for key, val in (('PermitRootLogin', 'yes'), ('PasswordAuthentication', 'yes')):
    if not any(line.strip().startswith(key) for line in s):
        s.append(f'{key} {val}')
open(sshd, 'w').write('\n'.join(s) + '\n')
PY

for f in "$mnt"/boot/loader/entries/*.conf "$mnt"/boot/loader.1/entries/*.conf; do
	[ -f "$f" ] || continue
	python3 - "$f" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
if 'selinux=0' not in s:
    s = s.replace('options ', 'options selinux=0 ', 1)
    open(p, 'w').write(s)
PY
done

echo "prepare-test-disk: root password + SSH enabled"
grep -E '^(memory|console)' "$conf" || true
grep '^options' "$mnt"/boot/loader/entries/*.conf || true

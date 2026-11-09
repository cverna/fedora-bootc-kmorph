#!/bin/bash
# Exercise kmorph-bootc's deployment derivation with fake bootc state.
# No kernel, bootc or /boot needed: the script's paths are overridable.
#
#   ./test-kmorph-bootc.sh
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

BOOTED_ROOT=
fail=0
check() {
	if ! eval "$2"; then
		printf 'FAIL: %s\n' "$1" >&2
		fail=1
	else
		printf 'ok: %s\n' "$1"
	fi
}

# A fake bootc that prints the given JSON.
fake_bootc() {
	cat >"$work/bootc" <<EOF
#!/bin/sh
cat <<'JSON'
$1
JSON
EOF
	chmod +x "$work/bootc"
}

run() {
	KMORPH_CONF="$work/kmorph.conf" \
	BOOTC="$work/bootc" \
	KMORPH_RUNTIME_CONF="$work/mk.conf" \
	KMORPH_BOOT_DIR="$work/boot" \
	KMORPH_PROC_CMDLINE="$work/cmdline" \
	KMORPH_OSTREE_ROOT="$work/ostree" \
	KMORPH_COMPOSEFS_STAGED="$work/composefs/staged-deployment" \
	KMORPH_BOOTED_ROOT="$BOOTED_ROOT" \
	"$here/kmorph-bootc" "$@"
}

deployment() {
	local root=$1 kver=$2

	mkdir -p "$root/usr/lib/modules/$kver" "$root/usr/lib/kmorph"
	echo kernel >"$root/usr/lib/modules/$kver/vmlinuz"
	echo initrd >"$root/usr/lib/kmorph/successor.img"
}

cat >"$work/kmorph.conf" <<'EOF'
cpus = 1
memory = 512MB
console = ttyS0
console_login = /bin/sh
EOF

mkdir -p "$work/boot/loader/entries"
: >"$work/cmdline"

# 1. ostree staged deployment, entry present
ostree_root=$work/ostree/deploy/fedora/deploy/abc123.0
deployment "$ostree_root" 6.1.0-test
cat >"$work/boot/loader/entries/ostree-staged.conf" <<EOF
title Fedora 45.1
version 45.1
options root=UUID=deadbeef ostree=/ostree/boot.1/fedora/abc123/0 rw quiet
EOF
fake_bootc '{"status":{"staged":{"ostree":{"stateroot":"fedora","checksum":"abc123","deploySerial":0},"image":{"version":"45.1"}}}}'
run generate --staged
check "ostree kernel" "grep -qF 'kernel = $ostree_root/usr/lib/modules/6.1.0-test/vmlinuz' '$work/mk.conf'"
check "ostree initrd" "grep -qF 'initrd = $ostree_root/usr/lib/kmorph/successor.img' '$work/mk.conf'"
check "ostree cmdline" "grep -qF 'ostree=/ostree/boot.1/fedora/abc123/0' '$work/mk.conf'"
check "earlyprintk added" "grep -qF 'earlyprintk=serial,ttyS0,115200' '$work/mk.conf'"

# 2. no staged deployment
fake_bootc '{"status":{"staged":null}}'
if run generate --staged 2>"$work/err"; then
	check "no staged deployment fails" false
else
	check "no staged deployment fails" "grep -q 'no staged or queued rollback deployment' '$work/err'"
fi

# 3. ostree staged without a matching BLS entry
rm -f "$work/boot/loader/entries/ostree-staged.conf"
fake_bootc '{"status":{"staged":{"ostree":{"stateroot":"fedora","checksum":"abc123","deploySerial":0},"image":{"version":"45.1"}}}}'
if run generate --staged 2>"$work/err"; then
	check "missing BLS entry fails" false
else
	check "missing BLS entry fails" "grep -q 'finalize-staged' '$work/err'"
fi

# 4. composefs: booted and staged share a version; pick the staged entry
composefs_root=$work/composefs/staged-deployment
deployment "$composefs_root" 6.2.0-test
cat >"$work/boot/loader/entries/composefs-booted.conf" <<EOF
title Fedora 45.2 (booted)
version 45.2
options root=UUID=deadbeef composefs.digest=v1-sha512-12:old rw quiet
EOF
cat >"$work/boot/loader/entries/composefs-staged.conf" <<EOF
title Fedora 45.2 (staged)
version 45.2
options root=UUID=deadbeef composefs.digest=v1-sha512-12:new rw quiet
EOF
echo "BOOT_IMAGE=/vmlinuz root=UUID=deadbeef composefs.digest=v1-sha512-12:old rw quiet" >"$work/cmdline"
fake_bootc '{"status":{"staged":{"composefs":{"verity":"new","bootType":"Bls","bootloader":"systemd"},"image":{"version":"45.2"}}}}'
run generate --staged
check "composefs kernel" "grep -qF 'kernel = $composefs_root/usr/lib/modules/6.2.0-test/vmlinuz' '$work/mk.conf'"
check "composefs picks staged digest" "grep -qF 'composefs.digest=v1-sha512-12:new' '$work/mk.conf'"

# 5. booted deployment
BOOTED_ROOT=$work/booted
deployment "$BOOTED_ROOT" 6.3.0-test
echo "BOOT_IMAGE=/vmlinuz root=UUID=deadbeef ro no_timer_check" >"$work/cmdline"
fake_bootc '{"status":{"booted":{"ostree":{"stateroot":"fedora","checksum":"def","deploySerial":0}}}}'
run generate
check "booted kernel" "grep -qF 'kernel = $BOOTED_ROOT/usr/lib/modules/6.3.0-test/vmlinuz' '$work/mk.conf'"
check "booted drops BOOT_IMAGE" "! grep -q 'BOOT_IMAGE' '$work/mk.conf'"
check "booted keeps root" "grep -qF 'cmdline = root=UUID=deadbeef ro no_timer_check' '$work/mk.conf'"

# 6. finalized staged deployment is the queued rollback
rb_root=$work/ostree/deploy/fedora/deploy/def456.0
deployment "$rb_root" 6.4.0-test
cat >"$work/boot/loader/entries/ostree-rollback.conf" <<EOF
title Fedora 45.2
version 45.2
options root=UUID=deadbeef ostree=/ostree/boot.0.1/fedora/def456/0 rw quiet
EOF
fake_bootc '{"status":{"staged":null,"rollback":{"ostree":{"stateroot":"fedora","checksum":"def456","deploySerial":0},"image":{"version":"45.2"}},"rollbackQueued":true}}'
run generate --staged
check "rollback kernel" "grep -qF 'kernel = $rb_root/usr/lib/modules/6.4.0-test/vmlinuz' '$work/mk.conf'"
check "rollback initrd" "grep -qF 'initrd = $rb_root/usr/lib/kmorph/successor.img' '$work/mk.conf'"
check "rollback cmdline" "grep -qF 'ostree=/ostree/boot.0.1/fedora/def456/0' '$work/mk.conf'"

[ "$fail" = 0 ] || exit 1
echo "all kmorph-bootc checks passed"

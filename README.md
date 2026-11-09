# kmorph on Fedora bootc

This repository is a proof of concept that integrates
[kmorph](https://github.com/multikernel/kmorph) with Fedora bootc. It
builds a Fedora bootc image that carries the multikernel kernel and
kmorph, and provides the glue bootc needs where a normal dnf host would
use `kernel-install`. The kernel comes from
[multikernel/linux](https://github.com/multikernel/linux); the kmorph
user space is fetched at image build time.

Status: the image build has been run against the Fedora 45 bootc base on
aarch64 with a source-built multikernel kernel: master `702f783`,
version `7.0.0-mk4` locally and `7.0.0-mk4+` on the bare-metal build,
5,739 modules, all required options built in. The Fedora-complete modules
tree is 7.4 GB unstripped (11.5 GB image, 618 MB initramfs);
`build-kernel.sh` strips module debug info by default, which gives
405 MB of modules, a 79 MB initramfs and a 2.9 GB image. Both goals
work end to end on bare-metal Graviton/KVM: the crash takeover and a
live bootc update that stages a new image with a new kernel
(`7.0.0-mk4-upgrade+`) and hands over without a reboot (see
[Demo](#demo)). They need the arm64 PCI patch in `patches/`. The
generation-2 re-arm is the remaining step.

The two goals, in order:

1. **Crash takeover on a bootc host.** A successor built from the booted
   deployment takes over when the predecessor dies, and bootc user space
   comes back on the successor kernel.
2. **Live bootc update.** `bootc upgrade`/`switch` stages a new deployment;
   kmorph arms a successor from that staged deployment and hands over, so
   the machine boots the new image without a firmware/bootloader reboot.

Both work end to end now; the staged-update glue lives in
`kmorph-bootc`, and its sequencing and caveats are in
[Live-update experiment](#live-update-experiment).

## Demo

Two asciinema recordings on a real Fedora 45 bootc image, made on a
bare-metal Graviton3 instance (64 vCPU, native KVM) with a 2-vCPU/16 GB
test VM.

### Crash takeover

`demo.cast` is an asciinema recording of the crash takeover on a
real Fedora 45 bootc image:

```bash
asciinema play demo.cast
# or publish it:
asciinema upload demo.cast
```

Recorded: <https://asciinema.org/a/SRHCm3BYVHpURZNu> (unlisted).

It shows:

- `bootc status` on the bootc host — image `localhost/fedora-bootc-kmorph:mk`,
  digest and version;
- `kmorph status` — `successor: active`, `kmorphd: ARMED`;
- the sysrq crash of the predecessor;
- the successor's `adopted 3 devices`, `adopted 1 CPUs and 14296 MB`,
  `state TAKEN_OVER`;
- the same bootc image and deployment back, `uname -r 7.0.0-mk4+`,
  `/run/kmorph/state: TAKEN_OVER`;
- the QEMU process still the same PID, i.e. the virtual machine itself
  never rebooted.

`demo.sh` is the host-side script used for the recording; run it
after `test-vm.sh` has booted the VM and its successor is `ARMED`.
It needs `sshpass`, `asciinema`, and the hvc0 log (`HVC_LOG`, default
`$HOME/mk-hvc.log`).

### Live update

`demo-upgrade.cast` stages a new bootc image that carries a new
kernel, arms it as the successor, and hands over without rebooting:

```bash
asciinema play demo-upgrade.cast
```

Recorded: <https://asciinema.org/a/dG5Gj9q1tUJK6lGS> (unlisted). Each
step is held on screen long enough to read, and narration is comments
only: the commands print their own output unchanged.

It shows:

- old side: `uname -r 7.0.0-mk4+`, image `localhost/fedora-bootc-kmorph:mk`,
  `kmorphd: ARMED`;
- `bootc switch` to `10.0.2.2:5000/fedora-bootc-kmorph:upgrade`; the
  layers are shared with the base image, so only the new kernel layers
  (~394 MB) are downloaded;
- `ostree admin finalize-staged` — bootc then lists the deployment as
  `Rollback image (queued):`, not as `Staged image:`;
- `kmorph-bootc arm --staged` builds the successor from that deployment:
  kernel `7.0.0-mk4-upgrade+`, the staged initramfs and command line;
- `kmorph upgrade` freezes the filesystems and hands over; the old ssh
  session dies with the old kernel;
- new side: `uname -r 7.0.0-mk4-upgrade+`, `bootc status` booted on
  `...:upgrade` with the old image as rollback, `TAKEN_OVER
  predecessor=handed-over`;
- the QEMU process is the same PID throughout.

`demo-upgrade.sh` drives the recording. It needs an `ARMED`
predecessor, a local registry reachable from the guest with the upgrade
image, and the `kmorph-bootc` helper in `/run/kmorph`.

The successor still cannot arm a generation-2 successor after the
handover; see [Known gaps](#known-gaps).

## Why this is not just "make install"

bootc changes three things kmorph assumes on a dnf/apt host:

- The kernel and its initramfs are part of the immutable container image,
  and `bootc container lint` allows exactly one `/usr/lib/modules/$kver`.
  A custom multikernel kernel has to replace the stock one.
- bootc ships `/usr/lib/kernel/install.conf` with `layout=ostree`, so
  `kernel-install` does not run dracut and `60-kmorph.install` never does
  its job. The successor image is built into the image instead, and the
  kernel/initramfs/cmdline are derived at runtime.
- `/usr` is read-only, `/etc` is 3-way merged, and `/var` content from an
  image update is not applied. Everything kmorph needs at runtime is
  therefore installed under `/usr`; only machine settings live in `/etc`.

## Files

| File | Purpose |
| --- | --- |
| `Containerfile` | Clones kmorph, builds it, then builds the bootc image with the multikernel kernel. |
| `build-kernel.sh` | Builds the multikernel kernel on a Fedora build host, applies `patches/`, and exports `kbuild/`. |
| `patches/` | Kernel patches applied by `build-kernel.sh` (currently the arm64 PCI adoption fix). |
| `kmorph.conf` | Machine keys baked into `/etc/kmorph/kmorph.conf`. |
| `kmorph-bootc` | Derives `kernel`, `initrd` and `cmdline` from a bootc deployment and runs kmorph. |
| `kmorph.service.d/10-bootc.conf` | Replaces kmorph.service's host-side mkimage/arm steps with the helper. |
| `build-image.sh` | Wraps `bootc-image-builder` to produce a qcow2. |
| `run-qemu.sh` | Boots that qcow2 with the matching firmware. |
| `prepare-test-disk.sh` | Enables a test root password/SSH and SELinux-off in an installed disk. |
| `test-vm.sh` | Boots an installed disk, waits for `ARMED`, optionally crashes it, and reports the successor. |
| `demo.sh` | Host-side script that drives and narrates the crash-takeover demo. |
| `demo.cast` | Asciinema recording of the crash takeover. |
| `demo-upgrade.sh` | Host-side script that drives and narrates the live-update demo. |
| `demo-upgrade.cast` | Asciinema recording of the live update of image and kernel. |
| `test-kmorph-bootc.sh` | Exercises the deployment-derivation logic with fake bootc state. |

## Prerequisites

- Fedora build host for the kernel: `gcc`, `make`, `flex`, `bison`,
  `bc`, `elfutils-libelf-devel`, `openssl-devel`, `perl`, `kmod`, `git`,
  and enough disk for a kernel tree.
- `podman` and `bootc-image-builder`, plus `qemu` for a VM test. A
  nested VM test also needs hardware virtualization in the outer VM.
- **Secure Boot off** in the VM. The multikernel kernel is unsigned, and
  `kexec_file_load` is refused under lockdown. Kernel dumps additionally
  need `iomem=relaxed`, which kmorph adds itself.
- A multikernel source tree that actually has `CONFIG_MULTIKERNEL`. The
  tree linked from <https://multikernel.io/getting-started> is the one
  kmorph targets; if it is not reachable (it is not publicly indexed),
  point `REPO=`/`SRC=` at your own checkout.

## Quick start

### 1. Build the kernel

```bash
REF=v7.0-mk4 ./build-kernel.sh
cat kbuild/KVER
```

This is only needed for a takeover. The image build, the helper and the
bootc boot itself can be exercised with the base image's own kernel as a
stand-in (that is what the current test image does), but kmorph cannot arm
without `CONFIG_MULTIKERNEL`.

The `v7.0-mk4` release ships prebuilt **x86_64** RPM/DEB packages only.
On arm64 there is no shortcut: build from source.

`v7.0-mk4` is also from 2026-10-26 and predates fixes that matter for
takeover (fenced-CPU confirmation, IPI delivery, memory hotplug). For a
fresh arm64 build, `master` is a reasonable choice; pin the commit you
built if you need reproducibility. The current test build used master at
`702f783`.

The Fedora-complete config builds 5,739 modules. Unstripped they are
7.4 GB and produce a ~600 MB initramfs and an 11.5 GB image; the script
strips module debug info at install (`STRIP_MODULES=1`, the default),
which gives 405 MB of modules, a 79 MB initramfs and a 2.9 GB image.
`STRIP_MODULES=0` keeps debug info. The kernel's `modules_install`
strips before it signs, so the default stripped modules stay signed and
load under Secure Boot/lockdown rules that enforce signatures. (Stripping
an already-signed module tree by hand, as we did once before rebuilding,
would invalidate the signatures.) `kmorph` wants `memory` to be at least
three times the initramfs size: 1 GB is enough for the 80 MB stripped
image, 2 GB for the 600 MB unstripped one. On a QEMU guest with
fragmented RAM, a 2 GB contiguous pool can fail with `Cannot allocate
memory`; 1 GB is also the safer test value.

The clone is one-time and shallow; the build is the expensive part. Keep
the source tree and the exported `kbuild/` so later image rebuilds do not
recompile the kernel:

```bash
SRC=$HOME/src/multikernel-linux ./build-kernel.sh
# later, after a source change, the same SRC= is an incremental make
```

Useful overrides:

```bash
REF=... SRC=... CONFIG=/path/to/fedora.config OUT=... JOBS=4 \
    ./build-kernel.sh
```

`CONFIG=defconfig` gives a much faster build for a QEMU-only test, but it
is not a Fedora config and may miss pieces bootc needs (zstd initramfs,
overlayfs, EROFS, SELinux, virtio). Use it to iterate, not for a real
image. The default starts from the build host's
`/boot/config-$(uname -r)`.

By default it downloads the remote default branch; `REF=v7.0-mk4` pins
the current release. It applies `patches/*.patch` after the clone
(`PATCHES=0` skips them; patches that are already applied are detected
and left alone), starts from `/boot/config-$(uname -r)`, enables
the options kmorph needs, and writes:

```text
kbuild/vmlinuz
kbuild/lib/modules/<kver>/...
kbuild/KVER
```

If the build stops with `CONFIG_MULTIKERNEL_VSOCKETS did not stick`, the
base config has `CONFIG_VSOCKETS=m`; the script enables `VSOCKETS=y` so
the multikernel transport is built in. If it stays a module, set
`modules = mk_transport` in `kmorph.conf` so the dracut module
carries it into the successor image.

The script does not run `make install` (which would try to update the
build host's bootloader). It copies the architecture's boot image:

- x86_64: `arch/x86/boot/bzImage`
- arm64: `arch/arm64/boot/Image`

### 2. Build the image

The build context is this repository. The builder stage clones the
kmorph user space from `KMORPH_REPO` at `KMORPH_REF` (default: the commit
this PoC was tested with), so you do not need a local kmorph checkout.
Override either with `--build-arg` to build against another version.

```bash
podman build -f Containerfile \
    --build-arg KVER="$(cat kbuild/KVER)" \
    -t localhost/fedora-bootc-kmorph:dev .
```

`BASE` is the bootc image to derive from and `BUILDER` is the Fedora
image used to compile kmorph. Both default to the Fedora 45 images in
`registry.fedoraproject.org`; pass them explicitly to use a local or
differently tagged base, for example:

```bash
--build-arg BASE=quay.io/fedora/fedora-bootc:45 \
--build-arg BUILDER=quay.io/fedora/fedora:45
```

The Containerfile:

- removes the stock Fedora kernel, then installs the multikernel kernel
  as the only `/usr/lib/modules` entry;
- depmods and generates the boot initramfs `initramfs.img`;
- installs kmorph, the dracut module and the systemd units;
- builds the successor initramfs with `kmorph-mkimage` and moves it to
  `/usr/lib/kmorph/successor.img`. `/var` content in an image is only
  unpacked on first install, so it must live in `/usr`;
- enables `kmorph.service` and `kmorph-nm-handback.service`.

Run `bootc container lint` in the built image before installing. It
checks the one-kernel invariant and other image rules; fix findings
rather than ignoring them.

Two dracut messages are expected in a container build and are not fatal:
`No '/dev/log' or 'logger' included for syslog logging` and
`dracut-install: ERROR: installing '/root'`. The resulting initramfs is
the same size as the base image's and contains the bootc/ostree units,
`ostree-prepare-root` and `bootc-root-setup.service`.

`bootc image-builder` is not the only way to get a disk. To install
directly to a disk or a raw file with the image's own `bootc`:

```bash
truncate -s 12G disk.raw
sudo podman run --rm --privileged --pid=host --ipc=host \
    --security-opt label=type:unconfined_t \
    -v /dev:/dev -v /var/lib/containers:/var/lib/containers \
    -v "$PWD":/output \
    localhost/fedora-bootc-kmorph:dev \
    bootc install to-disk --generic-image --filesystem ext4 \
        --karg=console=ttyAMA0,115200 \
        --via-loopback /output/disk.raw
```

`--filesystem ext4` is needed for this base image; without it `bootc`
reports "No install configuration found". Use `console=ttyS0,115200`
on x86_64 so the installed system keeps a serial console for
`run-qemu.sh -nographic`.

For the test VM, unlock root over SSH so the arm/crash sequence can be
driven without a console:

```bash
sudo ./prepare-test-disk.sh /output/disk.raw kmorph
```

then boot with `SSH_PORT=2222` and `sshpass -p kmorph ssh -p 2222
root@127.0.0.1`. Leave `console` unset on arm64 (see Troubleshooting).

The multikernel image is much larger than the base if the modules are
not stripped: 7.4 GB of modules and an 11.5 GB image need a 20 GB disk.
With the default stripped modules (2.9 GB image, 79 MB initramfs) a
12 GB disk is enough.

### 3. Install and boot

```bash
./build-image.sh localhost/fedora-bootc-kmorph:dev
./run-qemu.sh output/qcow2/disk.qcow2
```

`build-image.sh` runs `bootc-image-builder` from a privileged container
and writes `output/`. `run-qemu.sh` picks OVMF/AAVMF for the host
architecture, auto-detects raw/qcow2, and boots with `-nographic`. Set
`SNAPSHOT=1` to discard writes, `MEM=`/`CPUS=` to size the VM, and
`FORMAT=` to override detection. Log in as the user configured in the
image; `bootc-image-builder` creates one from a
`[[customizations.user]]` entry in its config, or you can set a password
or SSH key in the Containerfile. Then check:

```bash
bootc status
kmorph status          # should show an armed generation-1 successor
systemctl status kmorph
```

`kmorph.service` should have generated `/run/kmorph/mk.conf`, armed
`generation-1`, and started `kmorph watch`.

### 4. Test the crash takeover

```bash
cat /run/kmorph/mk.conf
kmorph status
echo c > /proc/sysrq-trigger
```

The successor should fence the predecessor, adopt the devices and memory,
restart the bootc deployment, and `kmorph.service` should arm the next
generation. Check `bootc status` and `journalctl -b -u kmorph`.

If the console fills with the successor's boot, that is expected; the
README's `earlyprintk` advice is already added by `kmorph-bootc` when
`console=` is set in `kmorph.conf`.

## Fast test host

Nested virtualization is slow. A native `/dev/kvm` host on arm64 is the
better setup: no L1/L2 nesting, native GICv3, and many cores. An AWS
Graviton3 metal instance (for example `c7g.metal`, 64 vCPU / 125 GiB)
with Fedora 45 runs the whole experiment comfortably; `run-qemu.sh`
selects KVM automatically and passes `-cpu host` and
`-machine virt,gic-version=3`. A kernel build that takes tens of minutes
on a nested 8-vCPU VM takes a few minutes there.

On a fresh Fedora 45 arm64 host:

```bash
sudo dnf -y install git gcc make flex bison bc elfutils-libelf-devel \
  openssl-devel perl qemu-system-aarch64 qemu-img edk2-aarch64 jq sshpass
./build-kernel.sh        # /boot/config-$(uname -r), strips modules
```

Build the image with `sudo podman build` so that `bootc install` finds
it in root's storage, install and prepare the disk as above, then:

```bash
CRASH=1 MEM=16384 ./test-vm.sh /path/to/disk.raw
```

Give the test VM plenty of RAM (16 GB on a 64 GB+ host): the successor
pool is a contiguous allocation, and a 4 GB guest can fail with
`Cannot allocate memory` even when most of that 4 GB is free.

With KVM the guest CPU must be `-cpu host`; `run-qemu.sh` does that
already. Without it, KVM fails with
`kvm_arch_init_vcpu failed (0): Invalid argument`.

## How kmorph-bootc works

`kmorph-bootc generate`:

1. Reads the deployment root:
   - booted: `/`;
   - `--staged`: the ostree deployment path from `bootc status --json`
     (`status.staged.ostree`), or from `status.rollback.ostree` when
     `rollbackQueued` is true (what `ostree admin finalize-staged`
     leaves behind); `/run/composefs/staged-deployment` for composefs.
2. Finds the one kernel in `<root>/usr/lib/modules` and uses
   `<root>/usr/lib/modules/<kver>/vmlinuz`.
3. Uses `<root>/usr/lib/kmorph/successor.img`.
4. Builds the command line:
   - booted: `/proc/cmdline` with `BOOT_IMAGE=`/`initrd=` removed;
   - staged: the `options` line of the staged BLS entry, which carries
     the new deployment's `ostree=` (or composefs digest) and root. The
     entry is matched by resolving its `ostree=` boot path to the
     deployment root.
5. Appends `earlyprintk=serial,<console>,115200 keep_bootcon` unless an
   `earlyprintk=` is already present.
6. Writes `/run/kmorph/mk.conf`: the machine keys from
   `/etc/kmorph/kmorph.conf` plus the generated `kernel`, `initrd` and
   `cmdline`.

The service drop-in then does `kmorph arm` and `kmorph watch` with that
config. Keeping generated keys out of `/etc` matters: an edited
`/etc/kmorph/kmorph.conf` is preserved by bootc's 3-way merge, so a
kernel path baked there would go stale on the next image.

The derivation logic has a self-test that needs no kernel, bootc or
`/boot`:

```bash
./test-kmorph-bootc.sh
```

## Live-update experiment

A management agent would drive this; the steps are still manual, but the
path works end to end (see the live-update [demo](#live-update)):

```bash
# build and push image v2 with a new kernel/kver
bootc switch quay.io/you/fedora-bootc-kmorph:v2
bootc status                       # v2 is staged

# make the staged deployment bootable and merge /etc
ostree admin finalize-staged       # ostree backend; see notes below

# bootc now reports it as the queued rollback, not as "staged"
bootc status                       # bootOrder=rollback, rollbackQueued=true

# arm the successor from that deployment
systemctl stop kmorph              # disarm the old successor first
kmorph-bootc arm --staged
kmorph status                      # kmorphd: ARMED

# hand over; the ssh session dies with the old kernel
kmorph upgrade --config /run/kmorph/mk.conf
```

`v2` comes from a second kernel build (`OUT=kbuild-upgrade`, with
`CONFIG_LOCALVERSION="-upgrade"`) and the same Containerfile:

```bash
podman build -f Containerfile \
    --build-arg KVER="$(cat kbuild-upgrade/KVER)" \
    --build-arg KERNEL_DIR=kbuild-upgrade \
    -t localhost/fedora-bootc-kmorph:v2 .
```

Then verify on the other side:

```bash
uname -r                           # v2's kernel
bootc status                       # v2 booted; v1 is the rollback
cat /run/kmorph/state              # TAKEN_OVER predecessor=handed-over
```

Notes and open questions:

- `ostree admin finalize-staged` is designed to run at shutdown. Running
  it live is the experiment; the alternative is to accept that `/etc`
  comes from the image until the next real reboot.
- On the composefs backend the finalize step is different. Check
  `bootc status` and the `bootc-finalize-staged.service` behaviour for
  the version you run.
- After `finalize-staged`, `status.staged` is null and the new
  deployment is `status.rollback` with `rollbackQueued: true`; bootc
  also switches `spec.bootOrder` to `rollback`. `kmorph-bootc` accepts
  either state.
- The staged BLS entry must carry the new deployment's `ostree=` or
  composefs arguments. `kmorph-bootc` takes them from the entry rather
  than reconstructing them. For ostree, the `ostree=` argument's
  checksum is the **boot** checksum, and its `/0` resolves to the
  deployment root; the helper resolves that path to match the target
  deployment (with the `/sysroot` prefix allowed), and its version
  fallback ignores composefs entries when the target is ostree.
- If the staged deployment is a UKI (`bootType: Uki`), there is no
  separate `vmlinuz`/`initramfs.img`; kmorph-bootc fails with a clear
  message. Start with split-kernel BLS images.
- Whether ostree considers the new deployment booted after a kmorph
  handover depends on the `ostree=` argument reaching the successor's
  `/proc/cmdline`. Check `bootc status` and rollback behaviour before
  relying on it.

## Troubleshooting under QEMU

- **GICv3 is required.** `kmorph arm` may create the instance and then
  fail with `exec of instance N failed: Invalid argument`; the kernel log
  says `mk_dtb: The MADT describes no usable GICv3` and
  `mk_spawn: No boot device tree for instance N: -22`. QEMU's TCG
  `virt` machine defaults to GICv2. `run-qemu.sh` now passes
  `-machine virt,gic-version=3` on aarch64.
- **The start timeout is too short for slow hosts.** The base unit
  inherits a 45 s `TimeoutStartSec`; creating a 2 GB pool and kexec'ing a
  kernel plus initramfs can exceed that under TCG. The bootc drop-in
  sets `TimeoutStartSec=600`.
- **arm64 console.** `console = ttyAMA0` adds the PL011 as a platform
  device to the instance; arm64's `mk_dtb` refuses platform devices
  (`platform devices cannot be given to an instance on arm64`) and
  `kmorph arm` fails with `Invalid argument`. Leave `console` unset on
  arm64 and use SSH. The successor's command line still carries the
  predecessor's `console=ttyAMA0`, but the controller stays with the
  predecessor.
- **SELinux labels for the experiment's files.** The custom binaries and
  units are not package-labelled. For a test VM, install with
  `--karg=selinux=0` (or run permissive) until a policy exists.

## Known gaps

- **arm64 PCI adoption needs a kernel fix.** On arm64 the successor
  adopted CPUs and memory but zero devices:
  `Failed to move device ...: -1` / `adopt_function` `-EPERM`. The
  fence left `mk_pcifront_direct_access` false because
  `mk_pcifront_host_fenced()` returned early when its bus list was
  empty; a backup has no buses until a function is adopted and the
  host's buses live in `/chosen/multikernel,pci-buses`. Apply
  `patches/0001-pcifront-direct-access.patch` to the kernel tree
  before building. Without it the successor has no disk, NIC or
  console, so it cannot bring user space back.
- **Generation-2 re-arm fails on arm64.** After a takeover (crash or
  live update) the successor cannot create the next pool:
  `cannot claim the 1028 MB kept at 0x3a4000000 for the pool (Invalid
  argument)`, then `pool initialisation failed: Invalid argument`. The
  machine runs normally, but `kmorph.service` fails and no next
  successor is armed. The claim file (`/run/kmorph/pool-memory`) is
  consumed and unlinked; the fallback baseline fails too.
- **Standby services** are not usable yet. `kmorph-mkimage`'s standby
  switch requires `/` to be a plain partition or disk with `/usr` on it,
  which a composefs/overlay bootc root is not. Services restart after
  takeover; only the boot is overlapped.
- **Sealed/UKI images** are out of scope for this route.
- **SELinux**: kmorph has no policy module and the COPYed files are not
  labelled by a package script. Run `bootc container lint` and check
  `ausearch -m avc` after the first takeover; add a policy or run
  permissive while bringing the experiment up.
- **Boot counting/rollback**: bypassing the bootloader means no boot
  counter is consumed. Validate that `ostree-boot-complete` and rollback
  still behave.
- **`kmorph-mkimage`** hardcodes `/var/lib/kmorph/successor.img` and has
  no `--kmoddir`. The Containerfile works around the first; the second
  matters if you ever want to build a successor image at runtime for a
  kernel whose modules are only in another deployment.
- **Cross-architecture builds** are not handled: the kernel script builds
  for the host architecture and the Containerfile uses the matching base
  image.

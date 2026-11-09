# Build a Fedora bootc image carrying the multikernel kernel and kmorph.
#
# Run from this repository:
#
#   ./build-kernel.sh
#   podman build -f Containerfile \
#       --build-arg KVER="$(cat kbuild/KVER)" \
#       -t localhost/fedora-bootc-kmorph:dev .
#
# The base image must match the architecture of the kernel in kbuild/.
# The kmorph user space is cloned from KMORPH_REPO at KMORPH_REF; override
# either with --build-arg to build against a different version.

ARG BASE=registry.fedoraproject.org/fedora-bootc:45
ARG BUILDER=registry.fedoraproject.org/fedora:45

FROM ${BUILDER} AS kmorphbuild

ARG KMORPH_REPO=https://github.com/multikernel/kmorph.git
ARG KMORPH_REF=50ac6ac481a9bc280c6d647c944d7931ce5624de

RUN dnf -y install --setopt=install_weak_deps=False \
        gcc make git musl-gcc musl-libc-static
RUN git clone "${KMORPH_REPO}" /src && \
    git -C /src checkout "${KMORPH_REF}"
WORKDIR /src
RUN make -j"$(nproc)" && \
    make install PREFIX=/usr DESTDIR=/out

FROM ${BASE}

ARG KVER
ARG KERNEL_DIR=kbuild
RUN test -n "${KVER}"

# Keep dracut from trying to preserve xattrs of the build host.
ENV DRACUT_NO_XATTR=1

# bootc allows exactly one kernel, and the stock one is not multikernel.
# Remove it before installing the replacement below.
RUN dnf -y install --setopt=install_weak_deps=False dracut jq erofs-utils
RUN rpm -qa --qf '%{NAME}\n' | \
        grep -E '^kernel(-core|-modules(-core|-extra)?)?$' | \
        xargs -r dnf -y --setopt=protected_packages= remove

# kmorph binaries, libexec helpers, dracut module, systemd units and the
# kernel-install hook (the hook is inert under bootc's layout=ostree).
COPY --from=kmorphbuild /out/usr /usr
COPY kmorph-bootc /usr/libexec/kmorph-bootc
COPY kmorph.service.d/10-bootc.conf /usr/lib/systemd/system/kmorph.service.d/10-bootc.conf
COPY kmorph.conf /etc/kmorph/kmorph.conf

# COPY keeps the source modes; the drop-in must be world-readable.
RUN chmod 0755 /usr/libexec/kmorph-bootc && \
    chmod 0644 /usr/lib/systemd/system/kmorph.service.d/10-bootc.conf \
               /etc/kmorph/kmorph.conf

# The multikernel kernel in bootc's canonical layout.
COPY ${KERNEL_DIR}/vmlinuz /usr/lib/modules/${KVER}/vmlinuz
COPY ${KERNEL_DIR}/lib/modules/${KVER} /usr/lib/modules/${KVER}

RUN test "$(find /usr/lib/modules -mindepth 1 -maxdepth 1 -type d | wc -l)" -eq 1 && \
    depmod -a "${KVER}" && \
    dracut --force "/usr/lib/modules/${KVER}/initramfs.img" "${KVER}"

# The successor image is built here, from this image's own user space, and
# stored under /usr because image updates to /var are not applied.
RUN /usr/lib/kmorph/kmorph-mkimage "${KVER}" && \
    install -D -m0644 /var/lib/kmorph/successor.img /usr/lib/kmorph/successor.img && \
    rm -rf /var/lib/kmorph

RUN systemctl enable kmorph.service kmorph-nm-handback.service

# The package operations above leave dnf state and logs in /var. bootc
# unpacks /var from the image only on first install, but `bootc container
# lint` still reports them.
RUN dnf clean all && \
    rm -rf /var/cache/dnf /var/cache/libdnf5 /var/lib/dnf /run/dnf \
           /var/log/dnf*.log /var/cache/ldconfig

# Recommended after a build, but not enforced here because it reports the
# experiment's unlabelled custom files:
#   podman run --rm localhost/fedora-bootc-kmorph:dev bootc container lint

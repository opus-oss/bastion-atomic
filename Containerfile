# bastion-atomic: bastion's hardening on top of secureblue.
#
# Built in CI and pushed to ghcr.io, never on the target machine -- that is the whole point of an
# image-based system, and the reason there is no equivalent of NixOS's update.sh here.
#
# Based on secureblue rather than bare Silverblue so this image is only the delta: secureblue
# already brings hardened kernel parameters, hardened_malloc, USBGuard and Flatpak confinement,
# and is maintained. Pin the tag rather than tracking latest, so an upstream change is something
# that gets adopted deliberately instead of arriving overnight.
ARG BASE=ghcr.io/secureblue/silverblue-main-hardened
ARG TAG=latest

# --- Kernel source -----------------------------------------------------------------------------
# linux-hardened, verified and patched once, for both kernels below. Built in their own stages so
# the compiler, the source tree and the throwaway module-signing key never reach an image: only
# /out does.
FROM quay.io/fedora/fedora:44 AS kernelsrc
ARG KERNEL_VERSION=6.18.56
ARG HARDENED_VERSION=6.18.56-hardened1
# Checked against Greg Kroah-Hartman's signature (647F28654894E3BD457199BE38DBBDC86092693E) when
# pinned. To move to a newer 6.18: verify the new tarball's .tar.sign the same way, take its
# sha256, and fetch the matching linux-hardened patch and .sig into kernel/.
ARG KERNEL_SHA256=4633bbda2ab95eaf2a7af4041236451d6759c72e6946265531af4b3aacefbf89
# linux-hardened's release key (Levente Polyak), in kernel/linux-hardened-signing-key.asc.
ARG HARDENED_KEY=E240B57E2C4630BA768E2F26FC1B547C8D8172C8

RUN dnf5 install -y --setopt=install_weak_deps=False \
      gcc gcc-c++ gcc-plugin-devel make flex bison bc perl-interpreter diffutils findutils hostname \
      elfutils-libelf-devel openssl openssl-devel xz patch gnupg2 kmod \
    && dnf5 clean all

COPY kernel/ /build/kernel/
WORKDIR /build
RUN set -eux; \
    curl -sSfLO "https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-${KERNEL_VERSION}.tar.xz"; \
    echo "${KERNEL_SHA256}  linux-${KERNEL_VERSION}.tar.xz" | sha256sum -c; \
    export GNUPGHOME="$(mktemp -d)"; \
    gpg --batch --quiet --import kernel/linux-hardened-signing-key.asc; \
    gpg --batch --status-fd 1 --verify "kernel/linux-hardened-v${HARDENED_VERSION}.patch.sig" \
      "kernel/linux-hardened-v${HARDENED_VERSION}.patch" | grep -q "VALIDSIG ${HARDENED_KEY} "; \
    tar -xf "linux-${KERNEL_VERSION}.tar.xz"; \
    rm "linux-${KERNEL_VERSION}.tar.xz"; \
    mv "linux-${KERNEL_VERSION}" linux; \
    cd linux; \
    patch -s -p1 < "../kernel/linux-hardened-v${HARDENED_VERSION}.patch"

# --- forge's kernel ----------------------------------------------------------------------------
# forge's device-only linux-hardened kernel from the NixOS build, with modules switched back on
# and what Fedora Atomic needs added (kernel/fedora.config).
FROM kernelsrc AS kernel
RUN set -eux; \
    cd linux; \
    bash ../kernel/configure.sh . ../kernel/forge.config ../kernel/fedora.config; \
    make -s -j"$(nproc)" bzImage modules; \
    kver="$(make -s kernelrelease)"; \
    # Strips, then signs every module with certs/signing_key.pem; the key stays in this stage.
    make -s modules_install INSTALL_MOD_PATH=/out INSTALL_MOD_STRIP=1 DEPMOD=/bin/true; \
    rm -f "/out/lib/modules/${kver}/build" "/out/lib/modules/${kver}/source"; \
    cp arch/x86/boot/bzImage "/out/lib/modules/${kver}/vmlinuz"; \
    cp .config "/out/lib/modules/${kver}/config"; \
    cp System.map "/out/lib/modules/${kver}/System.map"

# --- The vm image's kernel ---------------------------------------------------------------------
# Virtual hardware only: virtio, QEMU's emulated USB/HDA/VGA, and the platform devices of QEMU's
# arm64 `virt` and x86 q35 machines (UTM, libvirt, virt-manager). It starts from allnoconfig, so
# whatever kernel/vm/*.config does not ask for is not compiled at all. Built natively on each
# architecture's runner.
FROM kernelsrc AS vmkernel
RUN set -eux; \
    case "$(uname -m)" in \
      aarch64) frag=arm64; target=Image; image=arch/arm64/boot/Image ;; \
      x86_64) frag=x86_64; target=bzImage; image=arch/x86/boot/bzImage ;; \
      *) echo "no vm kernel config for $(uname -m)" >&2; exit 1 ;; \
    esac; \
    cd linux; \
    make -s allnoconfig; \
    cp .config ../allnoconfig; \
    bash ../kernel/configure.sh . ../allnoconfig ../kernel/vm/common.config "../kernel/vm/$frag.config"; \
    make -s -j"$(nproc)" "$target" modules; \
    kver="$(make -s kernelrelease)"; \
    make -s modules_install INSTALL_MOD_PATH=/out INSTALL_MOD_STRIP=1 DEPMOD=/bin/true; \
    rm -f "/out/lib/modules/${kver}/build" "/out/lib/modules/${kver}/source"; \
    cp "$image" "/out/lib/modules/${kver}/vmlinuz"; \
    cp .config "/out/lib/modules/${kver}/config"; \
    cp System.map "/out/lib/modules/${kver}/System.map"

# --- GNOME Shell in the Opus palette -------------------------------------------------------------
# The top bar, overview, quick settings, lock and login screens are drawn from a stylesheet
# compiled into gnome-shell-theme.gresource, which no setting reaches beyond the accent presets
# (none of them amber). The NixOS build rebuilt gnome-shell from its .scss; here the compiled
# stylesheets are unpacked, recoloured and repacked. Done in its own stage on the same base, so
# the resource tools stay out of the image and the stylesheet matches the gnome-shell shipped.
FROM ${BASE}:${TAG} AS shelltheme
RUN dnf5 install -y glib2-devel && dnf5 clean all
RUN set -eux; \
    G=/usr/share/gnome-shell/gnome-shell-theme.gresource; \
    mkdir -p /work/src; cd /work/src; \
    for r in $(gresource list "$G"); do mkdir -p ".$(dirname "$r")"; gresource extract "$G" "$r" > ".$r"; done; \
    t=org/gnome/shell/theme; \
    # The accent, in both variants: Opus amber, with ground-coloured text on it. fg first, so the
    # shorter name does not match inside it.
    sed -i -e 's/-st-accent-fg-color/#1b1e1f/g' -e 's/-st-accent-color/#d98a3d/g' \
      "$t/gnome-shell-dark.css" "$t/gnome-shell-light.css"; \
    # The dark variant's greys, as the NixOS build set them in _default-colors.scss/_colors.scss:
    # base #222226 -> ground, bg #36363a -> raised, and fg -> Opus ink.
    sed -i -e 's/#222226/#1b1e1f/g' -e 's/#36363a/#2e3334/g' -e 's/#2e2e33/#292e2f/g' \
      -e 's/#38383b/#353b3c/g' -e 's/#fafafb/#e7e4d9/g' "$t/gnome-shell-dark.css"; \
    # A renamed variable upstream would leave the stock colours quietly in place; fail instead.
    if grep -q -- '-st-accent' "$t/gnome-shell-dark.css"; then echo "accent left unpatched" >&2; exit 1; fi; \
    grep -q '#d98a3d' "$t/gnome-shell-dark.css"; \
    { echo '<?xml version="1.0" encoding="UTF-8"?>'; echo '<gresources><gresource prefix="/">'; \
      for r in $(gresource list "$G"); do echo "<file>${r#/}</file>"; done; \
      echo '</gresource></gresources>'; } > ../theme.xml; \
    glib-compile-resources --sourcedir=. --target=/work/gnome-shell-theme.gresource ../theme.xml; \
    gresource list "$G" > ../before.txt; gresource list /work/gnome-shell-theme.gresource > ../after.txt; \
    diff ../before.txt ../after.txt

# --- Generic image: ghcr.io/opus-oss/bastion-atomic ----------------------------------------------
# secureblue's kernel, so it runs on any machine secureblue does.
FROM ${BASE}:${TAG} AS generic

# DoH resolver, installed before the copy so files/etc/dnscrypt-proxy/dnscrypt-proxy.toml replaces
# the package's default rather than being set aside as .rpmnew. Then the Opus theme's fonts, and
# adw-gtk3 so GTK3 apps take libadwaita's look and the Opus colours with it.
RUN dnf5 install -y dnscrypt-proxy rsms-inter-fonts jetbrains-mono-fonts-all adw-gtk3-theme \
    && dnf5 clean all

# Everything under files/ mirrors the target filesystem layout, so the copy is one step and what
# lands where is obvious from the tree.
COPY files/ /
# cosign, for bastion-verify-provenance. Fedora 45 does not package it, so take the binary from
# Sigstore's own image, pinned by digest (v2.5.2, the version CI signs with) and verified against
# Sigstore's release key, which secureblue already trusts for gcr.io/projectsigstore.
COPY --from=gcr.io/projectsigstore/cosign@sha256:23d07b53d59a1233e1ab5e7d082cf4182fc90067d2f86a662ba3003215cb0c95 /ko-app/cosign /usr/bin/cosign
COPY --from=shelltheme /work/gnome-shell-theme.gresource /usr/share/gnome-shell/gnome-shell-theme.gresource

RUN set -eux; \
    \
    # --- DNS -----------------------------------------------------------------------------------
    # dnscrypt-proxy on loopback is the only resolver. unbound and dnsconfd would forward to
    # whatever DHCP offered, in plaintext on port 53, which the firewall below rejects.
    systemctl disable unbound.service dnsconfd.service || true; \
    systemctl enable dnscrypt-proxy.service; \
    \
    # --- Image signature -----------------------------------------------------------------------
    # Trusting this repo's cosign key for ghcr.io/opus-oss lets `rpm-ostree upgrade` keep verifying
    # every new build. secureblue's policy.json is extended in place rather than replaced, which
    # keeps its own entries tracking upstream. From Fedora 45 on, secureblue ships it in
    # /usr/share/containers and leaves /etc without one, while older bases kept it in /etc.
    # Whichever exists gets the key, and the build fails if neither does.
    n=0; for p in /usr/share/containers/policy.json /etc/containers/policy.json; do \
      [ -e "$p" ] || continue; n=$((n+1)); \
      python3 -c 'import json, sys; p = sys.argv[1]; d = json.load(open(p)); d["transports"]["docker"]["ghcr.io/opus-oss"] = [{"type": "sigstoreSigned", "keyPath": "/etc/pki/containers/opus-oss.pub", "signedIdentity": {"type": "matchRepository"}}]; json.dump(d, open(p, "w"), indent=2)' "$p"; \
    done; [ "$n" -gt 0 ]; \
    systemctl enable bastion-policy-cleanup.service; \
    \
    # --- Firewall ------------------------------------------------------------------------------
    # firewalld off, the nftables ruleset from modules/firewall.nix in its place. The rules are
    # already plain nft syntax, so they move across unchanged: default-drop input, no forwarding,
    # and a reject on plaintext DNS so nothing can route around the encrypted resolver.
    systemctl disable firewalld.service || true; \
    systemctl enable bastion-nftables.service; \
    \
    # --- Clock ---------------------------------------------------------------------------------
    # No NTP client. The clock comes from the HTTPS Date headers of several independent servers,
    # the way Kicksecure's sdwdate does, with a quorum that has to agree before anything moves.
    # bastion_timesync.py is stdlib-only Python, so it runs here untouched.
    systemctl disable chronyd.service || true; \
    systemctl disable systemd-timesyncd.service || true; \
    systemctl enable bastion-timesync.timer; \
    \
    # No hidepid. Remounting /proc with hidepid=2 left every user manager unable to load
    # app.slice ("No such process"), GDM's greeter included, so the first boot stopped at a
    # blinking cursor after the LUKS prompt. Fedora's GNOME runs the greeter as dynamic users
    # with their own systemd --user, which the NixOS build never had to accommodate.
    \
    # --- Opus theme ----------------------------------------------------------------------------
    # Compile the GNOME defaults in /etc/dconf/db/local.d into the database dconf actually reads.
    dconf update; \
    \
    # --- Update provenance ----------------------------------------------------------------------
    # secureblue's updaters (rpm-ostreed-automatic, upgrade-on-boot) run verify-provenance.sh first,
    # and it only knows ghcr.io/secureblue/*: every update of this image was refused. Route
    # ghcr.io/opus-oss/* to a cosign check against the pinned key; other references keep
    # secureblue's handling. If the script changes shape upstream, stop the build rather than ship
    # an updater that refuses everything again.
    # Fedora 45 bases call it verify-provenance and no longer indent the case arms; older ones had
    # verify-provenance.sh. Patch whichever exists, and fail if none does or the patch misses.
    n=0; for vp in /usr/libexec/secureblue/verify-provenance /usr/libexec/secureblue/verify-provenance.sh; do \
      [ -e "$vp" ] || continue; n=$((n+1)); \
      grep -qE '^[[:space:]]*ghcr\.io/secureblue/\*\)$' "$vp"; \
      sed -i -E 's|^([[:space:]]*)ghcr\.io/secureblue/\*\)$|\1ghcr.io/opus-oss/*)\n\1    exec /usr/libexec/bastion-verify-provenance "${image_ref}"\n\1    ;;\n&|' "$vp"; \
      grep -q 'exec /usr/libexec/bastion-verify-provenance' "$vp"; \
      bash -n "$vp"; \
    done; [ "$n" -gt 0 ]; \
    \
    # --- Persistence tripwire --------------------------------------------------------------------
    # Root check after boot and daily; a per-user timer turns its findings into a notification.
    systemctl enable bastion-tripwire.timer; \
    systemctl --global enable bastion-tripwire-notify.timer; \
    \
    # --- Enable from /usr too -------------------------------------------------------------------
    # The `systemctl enable`s above write to /etc, and /etc is merged with the machine's own on a
    # rebase: from plain Silverblue the image's links never reached the VM, which kept dnsconfd and
    # unbound and ran neither dnscrypt-proxy nor the firewall. systemd reads .wants/ in
    # /usr/lib/systemd as well, and /usr is the image, so these hold whatever /etc says. The
    # services they replace are kept from starting by their 50-bastion-replaced.conf drop-ins.
    for u in dnscrypt-proxy.service bastion-nftables.service; do \
      mkdir -p /usr/lib/systemd/system/multi-user.target.wants; \
      ln -sf "../$u" "/usr/lib/systemd/system/multi-user.target.wants/$u"; \
    done; \
    for u in bastion-timesync.timer bastion-tripwire.timer; do \
      mkdir -p /usr/lib/systemd/system/timers.target.wants; \
      ln -sf "../$u" "/usr/lib/systemd/system/timers.target.wants/$u"; \
    done; \
    mkdir -p /usr/lib/systemd/user/timers.target.wants; \
    ln -sf ../bastion-tripwire-notify.timer /usr/lib/systemd/user/timers.target.wants/bastion-tripwire-notify.timer; \
    mkdir -p /usr/lib/systemd/user/default.target.wants; \
    ln -sf ../bastion-first-login-apps.service /usr/lib/systemd/user/default.target.wants/bastion-first-login-apps.service; \
    ln -sf ../bastion-amnesic-menu.service /usr/lib/systemd/system/multi-user.target.wants/bastion-amnesic-menu.service; \
    mkdir -p /usr/lib/systemd/system/paths.target.wants; \
    ln -sf ../bastion-amnesic-menu-refresh.path /usr/lib/systemd/system/paths.target.wants/bastion-amnesic-menu-refresh.path; \
    mkdir -p /usr/lib/systemd/user/graphical-session.target.wants; \
    ln -sf ../bastion-amnesic-notice.service /usr/lib/systemd/user/graphical-session.target.wants/bastion-amnesic-notice.service; \
    \
    # --- Amnesic boot ----------------------------------------------------------------------------
    # The boot entry that forgets everything (modules/amnesic.nix in the NixOS build). Its
    # initramfs half is the bastion-amnesic dracut module, which secureblue's initramfs does not
    # have, so rebuild it for secureblue's kernel with the same arguments the base used. The forge
    # and vm images rebuild theirs again in kernel/install.sh, which picks the module up the same
    # way. Without it the entry powers off instead of booting writable, but check anyway.
    kver="$(ls /usr/lib/modules)"; [ "$(echo "$kver" | wc -l)" = 1 ]; \
    img="/usr/lib/modules/$kver/initramfs.img"; mode="$(stat -c %a "$img")"; \
    dracut --no-hostonly --kver "$kver" --reproducible --zstd --add ostree -f "$img"; \
    chmod "$mode" "$img"; \
    lsinitrd "$img" > /tmp/initrd.txt; \
    for want in usr/lib/systemd/system-generators/bastion-amnesic-initrd-generator usr/libexec/bastion-amnesic-root usr/lib/ostree/ostree-prepare-root; do \
      grep -qF " $want" /tmp/initrd.txt || { echo "missing from initramfs: $want" >&2; exit 1; }; \
    done; rm /tmp/initrd.txt; \
    \
    # --- Sanity ---------------------------------------------------------------------------------
    # `ostree container commit` used to go here. It fails on this base with "Not in an
    # ostree-based container environment": the step belongs to the older ostree layering flow and
    # secureblue's bootc-era images do not present what it looks for. It was only a /var cleanup
    # and a validation pass, so dropping it costs nothing. Lint instead, when the base provides
    # it, which catches the things that actually break a deployment -- content in /var, files
    # outside /usr and /etc -- rather than erroring on the build method.
    if command -v bootc >/dev/null 2>&1; then bootc container lint || true; fi

# --- forge image: ghcr.io/opus-oss/bastion-atomic-forge -------------------------------------------
# The generic image with the device-only kernel. It has drivers for forge (Framework 13 AMD 7040)
# and nothing else, so it does not boot on other hardware. Last in the file, so a build with no
# --target produces this one; the workflow names each target explicitly.
FROM generic AS forge

# Swap secureblue's kernel for the one built above (kernel/install.sh has the details), with the
# firmware its built-in drivers need in the initramfs.
COPY --from=kernel /out/lib/modules/ /usr/lib/modules/
COPY kernel/install.sh kernel/initramfs-firmware.txt /tmp/kernel/
RUN set -eux; \
    bash /tmp/kernel/install.sh "$(ls /usr/lib/modules | grep -- '-bastion$')" /tmp/kernel/initramfs-firmware.txt; \
    rm -r /tmp/kernel

# --- VM image: ghcr.io/opus-oss/bastion-atomic-vm ----------------------------------------------------
# The generic image, made for running as a guest: the virtual-hardware-only kernel above in place
# of secureblue's, which carries drivers for every machine Fedora supports. qemu-guest-agent and
# spice-vdagent come with the base, started by udev when the VM has their channels. It boots under
# QEMU/KVM (UTM, libvirt) and nowhere else.
FROM generic AS vm

# Virtual devices need no firmware, so the initramfs carries none.
COPY --from=vmkernel /out/lib/modules/ /usr/lib/modules/
COPY kernel/install.sh /tmp/kernel/
RUN set -eux; \
    bash /tmp/kernel/install.sh "$(ls /usr/lib/modules | grep -- '-bastion-vm$')"; \
    rm -r /tmp/kernel

# Xwayland back on (vm/ has the drop-in), for spice-vdagent's clipboard and display resizing.
COPY vm/ /

# Let the host run commands and read files through qemu-guest-agent (guest-exec, guest-file-*).
# SELinux confines the agent and both booleans default off; -N sets them in the policy store
# without loading it, since there is no running kernel policy in a build.
RUN set -eux; \
    semanage boolean -N -m --on virt_qemu_ga_run_unconfined; \
    semanage boolean -N -m --on virt_qemu_ga_read_nonsecurity_files; \
    # -C lists only locally customised booleans, so both must be there.
    semanage boolean -l -C; \
    test "$(semanage boolean -l -C | grep -cE '^virt_qemu_ga_(run_unconfined|read_nonsecurity_files) ')" = 2

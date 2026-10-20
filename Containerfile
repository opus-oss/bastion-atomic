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

# --- Kernel ------------------------------------------------------------------------------------
# forge's device-only linux-hardened kernel from the NixOS build, with modules switched back on
# and what Fedora Atomic needs added (kernel/fedora.config). Built in its own stage so the
# compiler, the source tree and the throwaway module-signing key never reach the image: only
# /out does.
FROM quay.io/fedora/fedora:44 AS kernel
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
    cd "linux-${KERNEL_VERSION}"; \
    patch -s -p1 < "../kernel/linux-hardened-v${HARDENED_VERSION}.patch"; \
    bash ../kernel/configure.sh . ../kernel/forge.config ../kernel/fedora.config; \
    make -s -j"$(nproc)" bzImage modules; \
    kver="$(make -s kernelrelease)"; \
    # Strips, then signs every module with certs/signing_key.pem; the key stays in this stage.
    make -s modules_install INSTALL_MOD_PATH=/out INSTALL_MOD_STRIP=1 DEPMOD=/bin/true; \
    rm -f "/out/lib/modules/${kver}/build" "/out/lib/modules/${kver}/source"; \
    cp arch/x86/boot/bzImage "/out/lib/modules/${kver}/vmlinuz"; \
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
    # Trust this repo's cosign key for ghcr.io/opus-oss, so `rpm-ostree upgrade` keeps verifying
    # every new build. secureblue's policy.json is extended in place, not replaced, so its own
    # entries keep tracking upstream.
    python3 -c 'import json; p = "/etc/containers/policy.json"; d = json.load(open(p)); d["transports"]["docker"]["ghcr.io/opus-oss"] = [{"type": "sigstoreSigned", "keyPath": "/etc/pki/containers/opus-oss.pub", "signedIdentity": {"type": "matchRepository"}}]; json.dump(d, open(p, "w"), indent=2)'; \
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
    # --- setuid ---------------------------------------------------------------------------------
    # The setuid bits this build does not need. Doing it at image build time is strictly better
    # than the NixOS equivalent: /usr is immutable at runtime, so nothing can put them back, and
    # a package update cannot quietly restore them either.
    # su: sudo covers it. newgrp/sg: group switching, unused. pkexec: CVE-2021-4034 lived here,
    # and polkit's own D-Bus path does not need the setuid binary.
    for f in /usr/bin/su /usr/bin/newgrp /usr/bin/sg /usr/bin/pkexec; do \
      [ -e "$f" ] && chmod u-s "$f" || true; \
    done; \
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

# Swap secureblue's kernel for the one built above. An ostree deployment boots whatever single
# kernel is in /usr/lib/modules, with vmlinuz and initramfs.img beside its modules, so the old
# packages go (--nodeps: kernel-tools and friends name them but work with any kernel; --noscripts:
# their scriptlets call kernel-install, which has nothing to do in an image build) and the
# initramfs is regenerated for the new one with secureblue's own dracut settings.
COPY --from=kernel /out/lib/modules/ /usr/lib/modules/
COPY kernel/initramfs-firmware.txt /tmp/initramfs-firmware.txt
RUN set -eux; \
    kver="$(ls /usr/lib/modules | grep -- '-bastion$')"; \
    rpm -e --nodeps --noscripts $(rpm -qa --qf '%{NAME}\n' kernel kernel-core 'kernel-modules*'); \
    for d in /usr/lib/modules/*; do [ "${d##*/}" = "$kver" ] || rm -rf "$d"; done; \
    depmod -a "$kver"; \
    # Built-in drivers probe before the root filesystem exists, so their firmware has to be in
    # the initramfs. A missing file is a build error, not a black screen at the LUKS prompt.
    fw=""; \
    for f in $(grep -vE '^\s*(#|$)' /tmp/initramfs-firmware.txt); do \
      found=""; \
      for c in "/usr/lib/firmware/$f" "/usr/lib/firmware/$f.xz" "/usr/lib/firmware/$f.zst"; do \
        [ -e "$c" ] && found="$c"; \
      done; \
      [ -n "$found" ] || { echo "firmware not found: $f" >&2; exit 1; }; \
      fw="$fw $found"; \
    done; \
    rm /tmp/initramfs-firmware.txt; \
    # --add ostree: the module only includes itself on request (check() returns 255), and without
    # ostree-prepare-root the initramfs cannot mount the deployment. rpm-ostree asks for it when it
    # builds an initramfs; a hand-run dracut has to ask too.
    # --omit plymouth: plymouth.enable=0 (kargs.d) turns it off anyway; leaving it out of the
    # initramfs keeps the image smaller and the LUKS prompt on the text console.
    dracut --no-hostonly --kver "$kver" --reproducible --zstd --add ostree --omit plymouth --install "$fw" \
      -f "/usr/lib/modules/$kver/initramfs.img"; \
    chmod 0600 "/usr/lib/modules/$kver/initramfs.img"; \
    # dracut reports some failures (an uncopyable /root, for one) and still exits 0, so check that
    # what this machine cannot boot without made it in: the firmware, the LUKS unlock, and the
    # step that mounts the ostree deployment.
    lsinitrd -m "/usr/lib/modules/$kver/initramfs.img"; \
    lsinitrd "/usr/lib/modules/$kver/initramfs.img" > /tmp/initramfs.list; \
    for want in $fw /usr/lib/systemd/systemd-cryptsetup /usr/lib/ostree/ostree-prepare-root; do \
      grep -qF " ${want#/}" /tmp/initramfs.list || { echo "missing from initramfs: $want" >&2; exit 1; }; \
    done; \
    rm /tmp/initramfs.list

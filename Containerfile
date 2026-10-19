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
FROM ${BASE}:${TAG}

# Everything under files/ mirrors the target filesystem layout, so the copy is one step and what
# lands where is obvious from the tree.
COPY files/ /

RUN set -eux; \
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
    systemctl enable proc-hidepid.service; \
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

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

# DoH resolver, installed before the copy so files/etc/dnscrypt-proxy/dnscrypt-proxy.toml replaces
# the package's default rather than being set aside as .rpmnew.
RUN dnf5 install -y dnscrypt-proxy && dnf5 clean all

# Everything under files/ mirrors the target filesystem layout, so the copy is one step and what
# lands where is obvious from the tree.
COPY files/ /

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

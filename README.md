<p align="center"><img src="docs/banner.svg" alt="bastion" width="100%"></p>

<p align="center">
  <a href="https://github.com/opus-oss/bastion-atomic/actions/workflows/build.yml"><img alt="build" src="https://github.com/opus-oss/bastion-atomic/actions/workflows/build.yml/badge.svg"></a>
  <img alt="signed with cosign" src="https://img.shields.io/badge/signed-cosign-d98a3d">
  <img alt="base secureblue" src="https://img.shields.io/badge/base-secureblue-353b3c">
  <img alt="Fedora Atomic" src="https://img.shields.io/badge/Fedora-Atomic-353b3c">
</p>

Hardened Fedora Atomic desktop: secureblue plus the changes in this repo. Built and signed nightly in CI; machines just pull it.

## Install

From a stock [Fedora Silverblue](https://fedoraproject.org/atomic-desktops/silverblue/download) (aarch64 on Apple Silicon) or secureblue install:

```sh
git clone https://github.com/opus-oss/bastion-atomic.git && cd bastion-atomic
run0 bash install.sh          # bastion-atomic        any machine, amd64/arm64
run0 bash install.sh vm       # bastion-atomic-vm     QEMU/KVM guest (UTM QEMU backend, libvirt), amd64/arm64
run0 bash install.sh forge    # bastion-atomic-forge  Framework 13 AMD 7040 only, amd64
```

Reboot. Coming from Silverblue, also run `ujust set-kargs-hardening`.

- Switch image: `run0 bash -c 'rpm-ostree rebase ostree-image-signed:docker://ghcr.io/opus-oss/bastion-atomic-vm:latest'`
- Update: `rpm-ostree upgrade`. Undo: `rpm-ostree rollback`.

## Features

- [x] **Minimal virt-only kernel** (`bastion-atomic-vm`): linux-hardened built from `allnoconfig`, so only virtual hardware exists in it. Modules 5,003 → 36, kernel text symbols 84,198 → 40,436, syscalls 419 → 349, kernel-hardening-checker fails 72 → 49.
- [x] **Device-only kernel** (`bastion-atomic-forge`): linux-hardened compiled for one Framework 13 AMD 7040 and nothing else.
- [x] **Verified kernel source**: sha256-pinned kernel.org tarball, linux-hardened patch checked against its release key. Compiler and module-signing key never reach the image.
- [x] **Signed from build to boot**: cosign-signed images, GitHub build-provenance attestation, signature checked on install and every update. Even the first rebase from stock Silverblue is verified.
- [x] **Persistence tripwire**: `bastion-tripwire` baselines everything that survives a reboot (`/etc`, `/var`, `/boot`, EFI boot entries, shell rc files, autostart, systemd user units, SSH keys) and flags SELinux off, unsigned origin, layered packages, tampered `/boot`, setuid outside `/usr`. Runs at boot and daily; findings become desktop notifications.
- [x] **No plaintext DNS**: dnscrypt-proxy (DoH on 443) is the only resolver; DHCP DNS ignored; port 53/5353/5355 out is rejected so nothing routes around it.
- [x] **Default-deny firewall**: nftables, all inbound dropped, no ping, no forwarding except libvirt.
- [x] **No NTP**: clock set from HTTPS `Date` headers, moved only when 3 of 5 independent pools agree.
- [x] **Survives rebases**: services enabled from `/usr`, replaced services held off, so a machine's old `/etc` can't silently turn the firewall or resolver off.
- [x] **Nightly rebuilds** pick up secureblue fixes; the build fails rather than ship if a patch to upstream stops applying.
- [x] **Verified Whonix** for libvirt (`whonix.sh`, signing key pinned by fingerprint).
- [x] Stricter than secureblue: `ptrace_scope=2`; Intel ME, `sp5100_tco`, `pcspkr`, webcam modules blocked.
- [x] Opus theme across GNOME Shell, libadwaita, GTK3, Ptyxis; first-login app installer.
- [x] **Amnesic boot**: an extra GRUB entry per deployment, "(amnesic: nothing is saved)". Disks read-only in the block layer, LUKS opened read-only, root mounted without journal replay, `/etc` and `/var` (homes included) on RAM, `/boot` unmounted, updates off. Gone at power-off. Fails closed: if the RAM layers aren't up, it powers off instead of booting writable. Boot-tested in CI (normal, amnesic, normal; nothing survives). Drives plugged in after boot stay writable.
- [ ] **USB dead-man switch** that wipes the LUKS key slots. In the NixOS build ([`modules/killswitch.nix`](https://github.com/opus-oss/bastion/blob/main/modules/killswitch.nix)); not yet ported.
- [ ] Signed qcow2 of the vm image.

Underneath is [secureblue](https://secureblue.dev/features): hardened_malloc, SELinux confinement, `run0` instead of sudo, setuid stripped, restricted user namespaces, hardening kargs and sysctls.

## Limitations

- Captive portals don't load (they need plaintext DNS).
- Inbound services (sharing, casting, remote access) need a firewall rule.
- Tracks secureblue's `latest`; upstream changes land with the next nightly.

## Layout

```
Containerfile          every build step, one target per image
.github/workflows/     nightly build, provenance attestation, cosign signature
install.sh             trusts the key, signed rebase onto an image
whonix.sh              verified Whonix install
kernel/                linux-hardened source pins, forge.config, vm/*.config
vm/                    files only the vm image gets
files/                 copied to / (etc: DNS, firewall, sysctls, modules, policy; usr: services, theme)
```

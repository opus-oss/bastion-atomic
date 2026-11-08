<p align="center"><img src="docs/banner.svg" alt="bastion" width="100%"></p>

<p align="center">
  <a href="https://github.com/opus-oss/bastion-atomic/actions/workflows/build.yml"><img alt="build" src="https://github.com/opus-oss/bastion-atomic/actions/workflows/build.yml/badge.svg"></a>
  <img alt="signed with cosign" src="https://img.shields.io/badge/signed-cosign-d98a3d">
  <img alt="base secureblue" src="https://img.shields.io/badge/base-secureblue-353b3c">
  <img alt="Fedora Atomic" src="https://img.shields.io/badge/Fedora-Atomic-353b3c">
</p>

**A hardened Fedora Atomic desktop that refuses to leak.** Built on secureblue, then locked
down further: DNS that cannot go out in plaintext, a firewall that lets nothing in, a clock that trusts no single server, and a tripwire that
catches anything trying to survive a reboot. Built and signed in CI every night. Your machine never
compiles a thing.

```
Fedora Silverblue        stock Fedora Atomic GNOME
  └─ secureblue          hardened kernel, SELinux confinement, hardened_malloc, run0, USBGuard
       └─ bastion        DoH-only DNS · nftables · HTTPS quorum clock · persistence tripwire · device kernel
```

bastion is a derived image (`FROM ghcr.io/secureblue/silverblue-main-hardened`), so every
secureblue fix lands on the next nightly build with no merge. This repo is only the delta.

---

## Install

On a fresh [secureblue](https://secureblue.dev/install) GNOME install:

```sh
git clone https://github.com/opus-oss/bastion-atomic.git
cd bastion-atomic
run0 bash install.sh
```

Reboot. Done.

- **Verified from the first pull.** The key is trusted before the rebase, so it goes straight to
  `ostree-image-signed:`. No unsigned image ever touches the disk.
- **Your way back stays put.** The secureblue deployment remains in the boot menu.
- **Updates are automatic.** Nightly builds arrive as ordinary `rpm-ostree upgrade`s, applied on
  reboot. A bad one is one `rpm-ostree rollback` away.

| Image | Kernel | Runs on |
| --- | --- | --- |
| `ghcr.io/opus-oss/bastion-atomic` | secureblue's | anything secureblue supports |
| `ghcr.io/opus-oss/bastion-atomic-forge` | device-only linux-hardened (`kernel/`) | one Framework 13 AMD 7040 |

Forge image: `run0 env IMAGE=ghcr.io/opus-oss/bastion-atomic-forge:latest bash install.sh`.

---

## What bastion adds on top of secureblue

Every row is a file in this repo. **Replaces** means a secureblue default is switched off and
bastion's goes in its place.

| | What it does | Instead of | Where |
| --- | --- | --- | --- |
| 🔒 **DNS over HTTPS only** | dnscrypt-proxy on loopback, DoH on port 443 to Quad9, Cloudflare and Mullvad. DHCP-offered DNS is ignored | Unbound DoT on 853, which hostile networks just reset. **Replaces** | `etc/dnscrypt-proxy/` `etc/NetworkManager/conf.d/` |
| 🧱 **nftables firewall** | Inbound dropped. Nothing forwarded except libvirt bridges. No ping replies. Plaintext DNS (53, 5353, 5355) rejected on the way *out*, so no app can route around the resolver | firewalld. **Replaces** | `etc/nftables/bastion.nft` |
| 🕰️ **HTTPS quorum clock** | No NTP at all. One server from each of 5 independent pools; the clock moves only when at least 3 `Date` headers agree within 2 s plus measured error | chrony with NTS. **Replaces** | `usr/lib/bastion-timesync.py` |
| 🪤 **Persistence tripwire** | `/usr` is the signed image, so anything that survives a reboot has to hide in `/etc`, `/var`, `/boot`, firmware boot entries or a home. The tripwire enforces hard rules (SELinux enforcing, lockdown, signed origin, no layered packages, `/boot` matching the deployment, no setuid outside `/usr`, `ld.so.preload` limited to hardened_malloc) and diffs the rest against your baseline. Runs after every boot and daily. Findings arrive as a desktop notification | nothing | `usr/bin/bastion-tripwire` |
| ✍️ **Signed end to end** | cosign signature on every image, verified by rpm-ostree on every pull. GitHub build-provenance attestation on top | nothing | `.github/workflows/build.yml` |
| 🧬 **Device-only kernel** *(forge image)* | linux-hardened 6.18.56. Tarball hash and patch signature checked in the build. Every driver the machine uses is built in; modules are force-signed with a key destroyed in the build stage, so nothing compiled later can ever load. The build fails if the initramfs is missing firmware, LUKS or the ostree mount | secureblue's kernel | `kernel/` |
| 🛡️ ptrace locked to admin | `kernel.yama.ptrace_scope = 2` | 1 | `etc/sysctl.d/90-bastion.conf` |
| 🚫 5 more modules blocked | `mei`, `mei-me` (Intel ME), `sp5100_tco`, `pcspkr`, and `uvcvideo`: the webcam is blocked outright, not toggled | | `etc/modprobe.d/` |
| 🖥️ Text-only boot | `plymouth.enable=0`. Plain console LUKS prompt, and a 3.4 s `plymouth-quit-wait` stall gone | Plymouth | `usr/lib/bootc/kargs.d/` |
| 🎨 Opus theme | GNOME Shell recoloured at build time (dark slate, amber `#d98a3d`), libadwaita, GTK3, Ptyxis, Text Editor, Inter + JetBrains Mono, no login logo | | `etc/dconf/` `usr/share/opus-theme/` |
| 🧅 Whonix | `whonix.sh`: fingerprint-pinned, signature-verified Whonix under libvirt | | `whonix.sh` |

Belt and braces: 17 of the 18 sysctls and 41 of the 46 blocked modules repeat secureblue's on
purpose, so they hold even if upstream changes its defaults.

---

## What secureblue already brings over stock Silverblue

The foundation. All of this is secureblue's work: see
[secureblue.dev/features](https://secureblue.dev/features) and
[its repo](https://github.com/secureblue/secureblue).

| | Stock Silverblue | secureblue |
| --- | --- | --- |
| Kernel | Fedora's | Rebuilt and signed with secureblue's key. Secure Boot via shim + MOK |
| Kernel arguments | defaults | 37 more: `lockdown=confidentiality`, `module.sig_enforce=1`, `init_on_alloc/free=1`, `mitigations=auto,nosmt`, `iommu.strict=1`, `pti=on`, `slab_debug=FZ`, `random.trust_cpu=off`, … |
| sysctls | defaults | kptr/dmesg restrict, BPF and kexec off, perf paranoid 3, no redirects or source routing |
| Kernel modules | all loadable | Big blacklist: rare protocols and filesystems, FireWire, Thunderbolt. Bluetooth and webcam off by default |
| Allocator | glibc | hardened_malloc everywhere, Flatpaks included |
| Confinement | SELinux targeted | Plus a confined browser (Trivalent), restricted socket classes, user namespaces blocked for unconfined and container domains |
| Root | sudo, su, pkexec | All removed. `run0` instead. Every setuid bit under `/usr` stripped |
| Desktop | Xwayland, thumbnailers, user extensions | All off |
| Network | open firewalld services, plain DNS, NTP | Everything closed, DoT + DNSSEC, NTS, MAC randomisation |
| Login | unlimited tries | Locked 24 h after 50 failures |
| USB | anything goes | USBGuard |
| Images | Fedora-signed | Unsigned images rejected. Flathub verified-only |

---

## Know before you go

- **Captive portals won't load.** Hotel and airport Wi-Fi login pages need plaintext DNS, and
  bastion refuses it.
- **No inbound anything.** File sharing, casting and remote access need a firewall rule first.
- **Forge image + Secure Boot.** The forge kernel's modules are signed, but `vmlinuz` isn't, so
  shim refuses it: that image boots with Secure Boot off. The generic image is fine.
- **Forge kernel is pinned** at 6.18.56. Security fixes reach it when `KERNEL_VERSION` and the
  signed patch in `kernel/` are bumped.
- **Base tracks `latest`.** secureblue changes land on the next nightly build.
- **On the roadmap:** a kill switch (LUKS keyslot wipe, USB dead-man trigger) and an amnesic boot
  entry that keeps the disk read-only and everything else in RAM.

---

## Layout

```
Containerfile          kernel build → Shell theme → generic and forge images
.github/workflows/     nightly build, push, provenance attestation, cosign signature
install.sh             trust the key, rebase secureblue onto bastion
whonix.sh              verified Whonix install
kernel/                device config, Fedora additions, linux-hardened patch + signature
files/                 copied to / as-is
  etc/                 DNS, firewall, sysctls, blocked modules, timesync, dconf, signing policy
  usr/                 tripwire, timesync, systemd units, kargs, theme
docs/                  banner
```

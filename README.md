# bastion-atomic

bastion's hardening on Fedora Atomic. It is three layers, each one an image built on the one
below:

```
Fedora Silverblue        stock Fedora Atomic GNOME
  └─ secureblue          hardened kernel, SELinux confinement, hardened_malloc, run0, USBGuard ...
       └─ bastion        this repo: DNS over HTTPS only, nftables, HTTPS time, tripwire, forge kernel
```

bastion is a derived image (`FROM ghcr.io/secureblue/silverblue-main-hardened`), not a source
fork. Every secureblue fix arrives on the next nightly build without a merge, and this repo holds
only the difference.

## Install

On a freshly installed [secureblue](https://secureblue.dev/install) (GNOME / Silverblue variant):

```
git clone https://github.com/opus-oss/bastion-atomic.git
cd bastion-atomic
run0 bash install.sh
```

It trusts this repo's signing key, then rebases straight onto the signed image
(`ostree-image-signed:`, with no unsigned first step). Reboot afterwards. The secureblue you were on stays in
the boot menu as the way back. Updates arrive nightly as normal `rpm-ostree upgrade`s.

Two images come out of the one Containerfile:

| Image | Kernel | Runs on |
| --- | --- | --- |
| `ghcr.io/opus-oss/bastion-atomic` | secureblue's | anything secureblue supports |
| `ghcr.io/opus-oss/bastion-atomic-forge` | forge's device-only linux-hardened (`kernel/`) | forge only: Framework 13 AMD 7040 |

For the forge image: `run0 env IMAGE=ghcr.io/opus-oss/bastion-atomic-forge:latest bash install.sh`.
Its kernel has drivers for that one laptop and nothing else, and it is not signed for Secure Boot
(see [Known gaps](#known-gaps)).

## Layer 1 → 2: what secureblue adds to Silverblue

All of this comes from secureblue, not from this repo. Source:
[secureblue.dev/features](https://secureblue.dev/features), and the
[secureblue repo](https://github.com/secureblue/secureblue) for the exact files.

| Area | Stock Silverblue | secureblue |
| --- | --- | --- |
| Kernel | Fedora's | Fedora's, rebuilt and signed with secureblue's key; Secure Boot via shim + MOK |
| Kernel arguments | Fedora defaults | 37 more: `lockdown=confidentiality`, `module.sig_enforce=1`, `init_on_alloc/free=1`, `mitigations=auto,nosmt`, `iommu.strict=1`, `pti=on`, `slab_debug=FZ`, `random.trust_cpu=off` ... (`kargs.d/10-secureblue.toml`) |
| sysctls | Fedora defaults | `55-hardening.conf`: kptr/dmesg restrict, BPF and kexec off, perf paranoid 3, no redirects or source routing, ptrace_scope 1 |
| Kernel modules | everything loadable | large blacklist (`modprobe.d/secureblue.conf`): rare network protocols and filesystems, FireWire, Thunderbolt; Bluetooth and webcam off by default |
| Memory allocator | glibc | hardened_malloc system-wide, including Flatpaks |
| Confinement | SELinux targeted policy | plus a confined browser (Trivalent), restricted socket classes, unprivileged user namespaces blocked for unconfined and container domains |
| Root | sudo, su, pkexec | all three removed; `run0` instead. Every setuid bit under `/usr` stripped, capabilities where needed |
| Desktop | Xwayland on, thumbnailers, user GNOME extensions | all off by default |
| Network | firewalld with open services, plain DNS, NTP | firewalld with everything closed, Unbound DoT + DNSSEC, chrony with NTS, MAC randomisation |
| Login | no lockout | locked 24 h after 50 failures |
| USB | anything | USBGuard (`ujust setup-usbguard`) |
| Images | signed by Fedora | container policy rejects unsigned images; Flathub verified-only |
| Tools | none | `ujust audit-secureblue`, a toggle for each default, LUKS FIDO2 / TPM2+PIN helpers |

## Layer 2 → 3: what bastion adds to secureblue

Everything in this table is in this repo. **Replaces** means bastion turns a secureblue default
off and puts its own in its place.

| What | Detail | secureblue has | Files |
| --- | --- | --- | --- |
| **DNS over HTTPS only** | dnscrypt-proxy on loopback, DoH on 443 to Quad9, Cloudflare and Mullvad. NetworkManager ignores DHCP DNS | Unbound, DoT on 853. **Replaced**: 853 is reset on networks bastion is used on | `etc/dnscrypt-proxy/`, `etc/NetworkManager/conf.d/zz-bastion-dns.conf`, `etc/resolv.conf` |
| **nftables firewall** | Inbound dropped, no forwarding except libvirt bridges, no ping replies. Plaintext DNS (53, 5353, 5355) rejected on the way out | firewalld, all closed, no DNS block. **Replaced** | `etc/nftables/bastion.nft`, `bastion-nftables.service` |
| **HTTPS quorum clock** | One server from each of 5 independent pools; time is taken from their HTTPS `Date` headers only when at least 3 agree within 2 s plus measured error | chrony with NTS. **Replaced** | `usr/lib/bastion-timesync.py`, `etc/bastion/timesync.json` |
| **Persistence tripwire** | `/usr` is the signed image, so anything that survives a reboot is in `/etc`, `/var`, `/boot`, firmware boot entries or a home. Checks hard rules (SELinux enforcing, lockdown, signed origin, no layered packages, `/boot` matching the deployment, no setuid outside `/usr`, `ld.so.preload` limited to hardened_malloc) and diffs everything else against a baseline. Runs after boot and daily; findings arrive as a notification | nothing | `usr/bin/bastion-tripwire`, its units |
| **Signed rebase, provenance** | `install.sh` installs the key before the first pull, so no unverified image is ever deployed. CI attaches a GitHub build-provenance attestation | nothing | `install.sh`, `.github/workflows/build.yml` |
| **forge kernel** (forge image only) | linux-hardened 6.18.56, tarball hash and patch signature checked in the build. forge's drivers built in; modules force-signed with a key thrown away in the build stage. The build fails if the initramfs lacks firmware, LUKS or the ostree mount | secureblue's Fedora-based kernel | `kernel/`, `Containerfile` |
| ptrace | `kernel.yama.ptrace_scope = 2`: admin only | 1 | `etc/sysctl.d/90-bastion.conf` |
| 5 more blocked modules | `mei`, `mei-me` (Intel ME), `sp5100_tco`, `pcspkr`, and `uvcvideo` (webcam) blocked outright instead of toggled | the other 41 in this list | `etc/modprobe.d/90-bastion-blocked.conf` |
| Text-only boot | `plymouth.enable=0`: plain console LUKS prompt, and no ~3.4 s `plymouth-quit-wait` stall | Plymouth | `usr/lib/bootc/kargs.d/20-bastion.toml` |
| Opus theme | GNOME Shell stylesheet recoloured at build time, libadwaita/GTK3/Ptyxis/Text Editor colours, Inter and JetBrains Mono, no login-screen logo | secureblue defaults | `etc/dconf/`, `usr/share/opus-theme/` |
| Whonix | `whonix.sh`: fingerprint-pinned, signature-verified Whonix install under libvirt | nothing | `whonix.sh` |

Repeated from secureblue on purpose, so they still hold if upstream changes them: 17 of the 18
sysctls in `90-bastion.conf`, and 41 of the 46 modules in `90-bastion-blocked.conf`.

## Known gaps

- **forge image and Secure Boot.** secureblue signs its kernel for its MOK key; this build signs
  the forge kernel's modules but not `vmlinuz`. shim refuses it, so the forge image only boots
  with Secure Boot off. The generic image is unaffected.
- **forge kernel is pinned** to 6.18.56. Kernel security fixes reach it only when
  `KERNEL_VERSION` and the signed patch in `kernel/` are bumped by hand.
- **Base tracks `latest`.** A secureblue change lands on the next nightly build.
- **Captive portals** (hotel, airport Wi-Fi) can't show their login page: plaintext DNS is
  rejected.
- **Not ported from NixOS bastion:** the kill switch and the amnesic boot entry. hidepid was
  ported and dropped: remounting `/proc` with `hidepid=2` stopped GDM's greeter from starting.

## Compared with NixOS bastion

| | bastion-atomic | NixOS bastion |
| --- | --- | --- |
| Builds | in CI; the laptop downloads | on the laptop, kernel included |
| Confinement | SELinux, maintained upstream | four hand-written AppArmor profiles in complain mode |
| hardened_malloc | on, opted out per app | off entirely (broke Firefox-based browsers) |
| Kernel | device-only linux-hardened, modules signed (forge) | device-only linux-hardened, no module loader |
| Secure Boot | shim + MOK on the generic image | own keys via lanzaboote, currently off |
| Kill switch, amnesic mode | not yet | yes |

## Layout

```
Containerfile          kernel build, Shell theme, then the generic and forge images
.github/workflows/     nightly build, push, provenance attestation, cosign signature
install.sh             trust the key, rebase an existing secureblue onto the image
whonix.sh              verified Whonix install
kernel/                forge's config, Fedora additions, linux-hardened patch and signature
files/                 copied to / as-is
  etc/                 DNS, firewall, sysctls, blocked modules, timesync, dconf, signing policy
  usr/                 tripwire, timesync, systemd units, kargs, theme
```

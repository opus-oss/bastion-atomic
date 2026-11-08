<p align="center"><img src="docs/banner.svg" alt="bastion" width="100%"></p>

<p align="center">
  <a href="https://github.com/opus-oss/bastion-atomic/actions/workflows/build.yml"><img alt="build" src="https://github.com/opus-oss/bastion-atomic/actions/workflows/build.yml/badge.svg"></a>
  <img alt="signed with cosign" src="https://img.shields.io/badge/signed-cosign-d98a3d">
  <img alt="base secureblue" src="https://img.shields.io/badge/base-secureblue-353b3c">
  <img alt="Fedora Atomic" src="https://img.shields.io/badge/Fedora-Atomic-353b3c">
</p>

bastion is a hardened Fedora Atomic desktop image built on top of secureblue.

- **Layers**
  - Fedora Silverblue is the stock Fedora Atomic GNOME desktop.
  - secureblue hardens Silverblue: kernel, SELinux confinement, hardened_malloc, run0, USBGuard.
  - bastion hardens secureblue further: DNS over HTTPS only, an nftables firewall, an HTTPS-based clock, a persistence tripwire and an optional device-only kernel.
- **How it is built**
  - The image is derived from `ghcr.io/secureblue/silverblue-main-hardened`, so this repo only holds the changes on top of it.
  - GitHub Actions rebuilds and signs the image every night, so secureblue's fixes arrive without a merge.
  - Nothing is compiled or layered on the installed machine.

## Install

- **Requirements**
  - A fresh [secureblue](https://secureblue.dev/install) install, GNOME (Silverblue) variant.
- **Steps**
  - Run the installer, then reboot:
    ```sh
    git clone https://github.com/opus-oss/bastion-atomic.git
    cd bastion-atomic
    run0 bash install.sh
    ```
- **What the installer does**
  - It trusts this repo's signing key first, then rebases with `ostree-image-signed:`, so an unsigned image is never deployed.
  - It leaves your secureblue deployment in the boot menu as the way back.
- **Updates**
  - New builds arrive as ordinary `rpm-ostree upgrade`s and apply on reboot.
  - `rpm-ostree rollback` returns to the previous build.
- **Images**
  - `ghcr.io/opus-oss/bastion-atomic` uses secureblue's kernel and runs on anything secureblue supports.
  - `ghcr.io/opus-oss/bastion-atomic-forge` uses a device-only linux-hardened kernel and runs on one Framework 13 AMD 7040 only.
    - Install it with `run0 env IMAGE=ghcr.io/opus-oss/bastion-atomic-forge:latest bash install.sh`.

## What bastion adds to secureblue

- **DNS over HTTPS only** (replaces secureblue's Unbound DNS-over-TLS)
  - dnscrypt-proxy runs on loopback and sends DoH over port 443 to Quad9, Cloudflare and Mullvad.
  - NetworkManager ignores DNS servers offered by DHCP.
  - DNS-over-TLS uses port 853, which some networks reset; port 443 is not blocked that way.
  - Files: `etc/dnscrypt-proxy/`, `etc/NetworkManager/conf.d/zz-bastion-dns.conf`, `etc/resolv.conf`.
- **nftables firewall** (replaces firewalld)
  - All inbound traffic is dropped, and ping is not answered.
  - Nothing is forwarded except libvirt's virtual bridges.
  - Outbound plaintext DNS (ports 53, 5353, 5355) is rejected, so no program can bypass the encrypted resolver.
  - File: `etc/nftables/bastion.nft`.
- **HTTPS quorum clock** (replaces chrony with NTS)
  - The clock is set from the `Date` headers of HTTPS servers, with no NTP.
  - One server is picked from each of 5 independent pools, and the clock moves only when at least 3 agree within 2 seconds plus their measured error.
  - Files: `usr/lib/bastion-timesync.py`, `etc/bastion/timesync.json`.
- **Persistence tripwire** (new)
  - `/usr` is the signed, read-only image, so anything that survives a reboot has to live in `/etc`, `/var`, `/boot`, the firmware boot entries or a home directory.
  - It enforces fixed rules: SELinux enforcing, kernel lockdown on, a signed image origin, no layered packages, `/boot` matching the deployment, no setuid files outside `/usr`, and `ld.so.preload` limited to hardened_malloc.
  - It compares everything else against a baseline you accept with `run0 bastion-tripwire accept`.
  - It runs after every boot and daily, and reports findings as a desktop notification.
  - File: `usr/bin/bastion-tripwire`.
- **Signed images and build provenance** (new)
  - Every image is signed with cosign, and rpm-ostree verifies the signature on every pull.
  - CI also attaches a GitHub build-provenance attestation.
  - File: `.github/workflows/build.yml`.
- **Device-only kernel** (forge image only; replaces secureblue's kernel)
  - linux-hardened 6.18.56, with the source tarball hash and the patch signature checked during the build.
  - Every driver the machine uses is built in.
  - Modules are signed with a key that is deleted at the end of the build stage, so no module built later can load.
  - The build fails if the initramfs is missing the firmware, the LUKS unlock or the ostree mount step.
  - Directory: `kernel/`.
- **Stricter ptrace**
  - `kernel.yama.ptrace_scope` is 2 (admin only); secureblue sets 1.
  - File: `etc/sysctl.d/90-bastion.conf`.
- **Five more blocked kernel modules**
  - `mei` and `mei-me` (Intel ME), `sp5100_tco`, `pcspkr`, and `uvcvideo`.
  - The webcam (`uvcvideo`) is blocked outright instead of being a toggle.
  - File: `etc/modprobe.d/90-bastion-blocked.conf`.
- **Text-only boot**
  - `plymouth.enable=0` gives a plain console LUKS prompt and removes a 3.4-second `plymouth-quit-wait` delay.
  - File: `usr/lib/bootc/kargs.d/20-bastion.toml`.
- **Opus theme**
  - GNOME Shell is recoloured at build time in dark slate with an amber accent (`#d98a3d`).
  - libadwaita, GTK3, Ptyxis and Text Editor use the same colours, with Inter and JetBrains Mono fonts.
  - The login screen shows no logo.
  - Files: `etc/dconf/`, `usr/share/opus-theme/`.
- **Whonix**
  - `whonix.sh` installs Whonix under libvirt after checking its signing key fingerprint and signatures.
- **Overlap with secureblue**
  - 17 of the 18 sysctls and 41 of the 46 blocked modules repeat secureblue's settings, so they stay in place if secureblue changes its defaults.

## What secureblue adds to Silverblue

These come from secureblue, not this repo. Sources: [secureblue.dev/features](https://secureblue.dev/features) and the [secureblue repo](https://github.com/secureblue/secureblue).

- **Kernel**
  - Fedora's kernel, rebuilt and signed with secureblue's key, booted through shim and MOK for Secure Boot.
  - 37 extra kernel arguments, including `lockdown=confidentiality`, `module.sig_enforce=1`, `init_on_alloc=1`, `init_on_free=1`, `mitigations=auto,nosmt`, `iommu.strict=1`, `pti=on`, `slab_debug=FZ` and `random.trust_cpu=off`.
  - Hardened sysctls: kernel pointer and dmesg restriction, unprivileged BPF and kexec off, perf restricted, no ICMP redirects or source routing.
  - A large module blacklist covering rare network protocols and filesystems, FireWire and Thunderbolt, with Bluetooth and the webcam off by default.
- **Memory**
  - hardened_malloc system-wide, including inside Flatpaks.
- **Confinement**
  - SELinux confines a hardened Chromium browser (Trivalent) and restricts socket classes.
  - Unprivileged user namespaces are blocked for unconfined and container domains.
- **Root access**
  - sudo, su and pkexec are removed and replaced by `run0`.
  - Every setuid bit under `/usr` is stripped, with file capabilities where a program needs them.
- **Desktop**
  - Xwayland, thumbnailers and user GNOME extensions are off by default.
- **Network**
  - firewalld with every service closed, Unbound DNS-over-TLS with DNSSEC, chrony with NTS, and MAC address randomisation.
- **Login and USB**
  - Accounts lock for 24 hours after 50 failed logins.
  - USBGuard is available through `ujust setup-usbguard`.
- **Images and apps**
  - The container policy rejects unsigned images.
  - Only verified Flathub apps are enabled.

## Limitations

- **Captive portals**
  - Hotel and airport Wi-Fi login pages do not load, because they rely on plaintext DNS.
- **Inbound connections**
  - File sharing, casting and remote access need a firewall rule added first.
- **Forge image and Secure Boot**
  - The forge kernel's modules are signed but `vmlinuz` is not, so shim refuses it and the forge image needs Secure Boot off.
  - The generic image is not affected.
- **Forge kernel updates**
  - The forge kernel is pinned to 6.18.56 and gets security fixes only when `KERNEL_VERSION` and the signed patch in `kernel/` are updated.
- **Base image**
  - The build tracks secureblue's `latest` tag, so upstream changes arrive with the next nightly build.
- **Planned**
  - A kill switch that wipes the LUKS key slots, triggered by a USB dead-man switch.
  - An amnesic boot entry with the disk read-only and all changes kept in RAM.

## Layout

```
Containerfile          kernel build, Shell theme, then the generic and forge images
.github/workflows/     nightly build, push, provenance attestation, cosign signature
install.sh             trusts the signing key and rebases secureblue onto bastion
whonix.sh              verified Whonix install
kernel/                device kernel config, Fedora additions, linux-hardened patch and signature
files/                 copied to / as-is
  etc/                 DNS, firewall, sysctls, blocked modules, timesync, dconf, signing policy
  usr/                 tripwire, timesync, systemd units, kernel arguments, theme
docs/                  banner image
```

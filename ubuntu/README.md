# bastion on Ubuntu

Bastion's hardening on Ubuntu 26.04 LTS (amd64/arm64), with Claude Desktop installed natively.

## Install

On an installed system (not the live ISO), from a minimal Ubuntu Desktop install with LUKS:

```sh
sudo apt install -y git
git clone https://github.com/opus-oss/bastion-atomic.git && cd bastion-atomic
sudo bash ubuntu/install.sh
```

Reboot. Optional unattended install: give the Ubuntu installer `https://raw.githubusercontent.com/opus-oss/bastion-atomic/main/ubuntu/autoinstall.yaml` (disk and account stay interactive).

To update: `git pull && sudo bash ubuntu/install.sh`. Packages update through unattended-upgrades.

## What it does

- [x] Minimal linux-hardened kernel in QEMU/KVM guests (UTM, libvirt): bastion-atomic-vm's virtual-hardware-only config with AppArmor, Clang kCFI, no unprivileged user namespaces; built and signed in CI, Ubuntu's kernel kept as the GRUB fallback (`BASTION_KERNEL=stock` to skip)
- [x] Kernel arguments: secureblue's set plus bastion's (lockdown, module signatures enforced, IOMMU, init_on_free, slab hardening, mitigations with SMT off)
- [x] sysctl hardening and module blocklist, shared with the Atomic images
- [x] nftables firewall: default-drop inbound, no forwarding, plaintext DNS rejected (ufw off); local exceptions in `/etc/bastion/nftables-input.nft`, one rule per line
- [x] DNS over HTTPS only (dnscrypt-proxy on 127.0.0.1:53); systemd-resolved, avahi and cups-browsed off
- [x] Clock from HTTPS Date headers with a quorum, no NTP (chrony and timesyncd off)
- [x] USBGuard: devices present at boot allowed, new ones blocked (`sudo usbguard allow-device <id>`)
- [x] AppArmor with extra profiles; Claude Desktop runs with Chromium's sandbox on
- [x] No snapd; Firefox from Mozilla's apt repo
- [x] Apport, whoopsie, ubuntu-report and core dumps off
- [x] Claude Desktop and Firefox from pinned-key signed repos, updated by unattended-upgrades
- [x] Opus theme
- [ ] Amnesic boot
- [ ] USB kill switch
- [ ] Persistence tripwire

Not portable from the Atomic images: the immutable, signed base image, hardened_malloc, and secureblue's SELinux policy.

CI (`.github/workflows/ubuntu.yml`) boots the cloud image, runs the installer twice, reboots and runs `ubuntu/tests/check.sh`.

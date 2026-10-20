# bastion-atomic

Bastion's hardening, rebuilt on Fedora Atomic instead of NixOS.

## Install

On a freshly installed [secureblue](https://secureblue.dev) (GNOME / Silverblue variant):

```
git clone https://github.com/opus-oss/bastion-atomic.git
cd bastion-atomic
run0 bash install.sh
```

It trusts this repo's signing key, then rebases onto `ghcr.io/opus-oss/bastion-atomic:latest`,
the generic image, which runs anywhere secureblue does. Reboot afterwards. The secureblue you
were on stays in the boot menu as the way back. Updates arrive nightly as normal
`rpm-ostree upgrade`s.

What changes, compared with stock secureblue:

- **Nothing gets in.** The firewall drops all inbound connections and forwards nothing (except
  for libvirt VMs), so file sharing, casting and remote access need a rule first.
- **DNS only over HTTPS** (Quad9, Cloudflare, Mullvad). Plaintext DNS is rejected, so
  captive-portal Wi-Fi (hotels, airports) cannot show its login page.
- **The clock comes from HTTPS servers**, not NTP.
- Extra kernel sysctls, blocked kernel modules, and no setuid on `su`, `newgrp`, `sg`, `pkexec`.
- The Opus GNOME theme, a text-only boot, and no logo on the login screen.
- **A persistence tripwire.** `/usr` is the signed image and read-only, so anything that survives
  a reboot lives in `/etc`, `/var`, `/boot`, the firmware boot entries or a home directory.
  `bastion-tripwire` (in the image, run as root after boot and daily) records those places, flags
  what is wrong outright (SELinux off, an unsigned origin, `/boot` files that are not what the
  deployment shipped, setuid files outside `/usr`) and reports every change since the baseline as
  a desktop notification. `run0 bastion-tripwire diff` shows them; `run0 bastion-tripwire accept`
  takes the current state as the new baseline.

`bastion-atomic-forge` is not for other machines: its kernel only has drivers for one Framework
13 AMD 7040, and it will not boot anywhere else.

## Why

The NixOS build works and is measured: a device-only kernel with no module loader (7,297 modules
to 0), 214 hardening checks against PlagueOS's 195, nftables with no forwarding, DNS only over
HTTPS, USBGuard, LUKS2, reduced setuid, hidepid. What it does not have is application
confinement: four AppArmor profiles in complain mode, written from scratch, against a browser
that is the real attack surface.

Fedora Atomic inverts that. SELinux ships comprehensive and maintained; secureblue adds hardened
kernel parameters, hardened_malloc, USBGuard and Flatpak confinement on top. The work left here
is the part nobody else does, not the part everybody does.

What is given up: the module-free kernel. Fedora Atomic keys deployments off
`/usr/lib/modules/<version>` and dracut expects a module tree, so `CONFIG_MODULES=n` is awkward
in a way it is not under NixOS. Custom kernels are fine -- uBlue derivatives ship them routinely
via image builds -- but module-free specifically is unproven there. That is the trade.

## Approach

Build an OCI image on top of secureblue, not on bare Silverblue. secureblue already does a large
share of the hardening, is maintained, and is itself a Fedora Atomic image, so layering on it
keeps this repo to the delta rather than the whole.

Images build in CI and publish to ghcr.io; installs rebase onto them. Nothing is built on the
target machine, which is the point of an image-based system and the reason this cannot be done
the way `update.sh` works on NixOS.

Two images come out of the one Containerfile:

| Image | Kernel | Runs on |
| --- | --- | --- |
| `ghcr.io/opus-oss/bastion-atomic` | secureblue's | anything secureblue supports |
| `ghcr.io/opus-oss/bastion-atomic-forge` | forge's device-only linux-hardened (`kernel/`) | forge only: Framework 13 AMD 7040 |

The forge kernel has drivers for that one laptop and nothing else, so it will not boot anywhere
else. Both are signed with the same key.

## Feature mapping

Each `hardened.*` option from the NixOS build, and where it lands here.

| bastion (NixOS) | bastion-atomic | Status |
| --- | --- | --- |
| `apparmor` | SELinux, already enforcing and comprehensive | **replaced, better** |
| `kernel` hardening params | secureblue sets most; delta in `files/` kargs | **mostly given** |
| `kernel` device-only, no modules | forge's linux-hardened config built in the image (`kernel/`), with modules on and signed by a throwaway key | **ported, modules on** |
| `attack-surface` USBGuard | secureblue ships it | **given** |
| `attack-surface` blocked modules | `modprobe.d` drop-in in the image | port |
| `attack-surface` no coredumps | `systemd/coredump.conf` drop-in | port |
| `attack-surface` DoH | dnscrypt-proxy layered, or resolved DoT | port |
| `attack-surface` hidepid | dropped: remounting `/proc` with hidepid=2 stopped GDM's greeter from starting | **not ported** |
| `attack-surface` minimalSetuid | image build strips bits; `/usr` is immutable so it sticks | port, easier here |
| `firewall` nftables | disable firewalld, drop in the existing ruleset | port, direct |
| `timesync` HTTPS time | `pkgs/timesync/bastion_timesync.py` runs as-is; ship as a systemd unit | port, direct |
| `disk` LUKS2 + disko | kickstart or manual install; `systemd-cryptenroll` for TPM | reinstall-time |
| `secureboot` lanzaboote | Fedora kernels are signed by Fedora's key; shim/MOK instead of own PKI | **simpler** |
| `killswitch` | systemd unit, no NixOS dependency | port, direct |
| `amnesic` | Atomic already has read-only `/usr`; full RAM-only root needs its own work | deferred |
| `buildtools` | toolbox/distrobox container, not a layered package | **replaced** |
| hardened_malloc | secureblue ships it, and solves the per-app problem properly | **given, better** |

Three things come out better: SELinux over hand-written AppArmor, hardened_malloc applied
per-app rather than off entirely, and setuid reduction that cannot be undone at runtime because
`/usr` is immutable.

## Carried over verbatim

These are not NixOS-specific and should move across unchanged:

- `pkgs/timesync/bastion_timesync.py` -- the sdwdate-style HTTPS clock, including the HTTP/2
  DoH client. Stdlib only, so it runs anywhere with Python.
- `whonix.sh` -- fingerprint-pinned, signature-verified Whonix install. Only the libvirt bits
  are distro-specific, and those are thin.
- The nftables ruleset from `modules/firewall.nix`, which is already plain nft syntax.

## Layout

```
Containerfile          image definition, FROM secureblue
build.yml              GitHub Actions: build and push to ghcr.io
install.sh             rebase an existing Fedora Atomic install onto the image
files/                 everything dropped into the image
  etc/modprobe.d/      blocked modules
  etc/sysctl.d/        the sysctl set from modules/kernel.nix
  etc/nftables/        the firewall ruleset
  usr/lib/systemd/     timesync and firewall units
```

## Not yet decided

- Which secureblue variant to base on (GNOME/Silverblue vs KDE/Kinoite).
- Whether to take the kernel the rest of the way to module-free, now that the device-only
  config is built with modules on.
- Whether DoH comes from layered dnscrypt-proxy or resolved's own DoT, given TCP 853 is
  RST-filtered on at least one network this machine uses -- which is why NixOS ended up on
  dnscrypt-proxy over 443.

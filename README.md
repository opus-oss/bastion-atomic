# bastion-atomic

Bastion's hardening, rebuilt on Fedora Atomic instead of NixOS.

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

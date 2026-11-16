# bastion-atomic

Hardened Fedora Atomic images layered on secureblue (`ghcr.io/secureblue/silverblue-main-hardened`),
built in GitHub Actions, signed with cosign, published to `ghcr.io/opus-oss`. Machines rebase onto
an image and update by pulling the next one; nothing is built on the machines themselves.

## Images

One `Containerfile`, one target per image:

| Target | Image | Arch | What it is |
| --- | --- | --- | --- |
| `generic` | `bastion-atomic` | amd64, arm64 | secureblue plus everything in `files/`. Runs anywhere secureblue does. |
| `forge` | `bastion-atomic-forge` | amd64 | `generic` with a device-only linux-hardened kernel for one Framework 13 AMD 7040. Boots nowhere else, VMs included (no virtio). |
| `vm` | `bastion-atomic-vm` | amd64, arm64 | `generic` with a virtual-hardware-only linux-hardened kernel (QEMU/KVM: UTM, libvirt), plus guest integration. Boots on no real hardware. |

Other stages: `kernelsrc` (fetches and verifies linux-hardened once), `kernel` (forge's kernel) and
`vmkernel` (the vm kernel, from allnoconfig plus `kernel/vm/*.config`), all in Fedora so the
compiler and the throwaway module-signing key stay out of the images, and `shelltheme`
(recolours `gnome-shell-theme.gresource`).

## Layout

- `Containerfile`: every build step, commented with the reason for it. Read it before changing
  anything; most lines exist because something broke without them.
- `files/`: copied over `/` in the image. `files/etc` becomes the image's `/etc` defaults,
  `files/usr` is immutable on the running system.
- `kernel/`: forge's kernel. `forge.config` is the device-only config from the earlier NixOS
  build, `fedora.config` is merged over it (what Fedora Atomic and secureblue need), and
  `configure.sh` fails the build if `make olddefconfig` drops any requested option. Source is a
  sha256-pinned kernel.org tarball plus the signed linux-hardened patch. `vm/common.config` and
  `vm/<arch>.config` are the vm kernel, merged over `make allnoconfig`, so anything not listed is
  not compiled. `install.sh` swaps either kernel into an image and builds its initramfs.
- `.github/workflows/build.yml`: builds each target per arch, joins arches into one manifest,
  attests, and signs with the `SIGNING_SECRET` key. Nightly at 05:00 UTC, on push to `main`, and
  test-only for pull requests.
- `install.sh [generic|vm|forge]`: switches a stock Silverblue or secureblue install to an image
  (trusts the key first, then does a signed rebase).
- `whonix.sh`: verified Whonix install for system libvirt (`run0 bash whonix.sh`).

## Working on it

- **Builds happen in CI only.** Rootless podman does not work on secureblue (unprivileged user
  namespaces are off), so test changes by pushing, or through a pull request when a change is
  risky: PRs build without publishing.
- **Verify before deploying.** Anything you claim about an image, check against the published
  image itself. For example, extract a file from a layer:
  `skopeo inspect` for the digest, then pull blobs from `ghcr.io/v2/opus-oss/<image>/blobs/<digest>`
  with an anonymous token from `https://ghcr.io/token?scope=repository:opus-oss/<image>:pull`.
- **Signatures:** `cosign verify --new-bundle-format=false --key cosign.pub ghcr.io/opus-oss/<image>:latest`.
  cosign 3 needs the flag to read the classic format CI produces.
- **Commits and PRs:** no `Co-Authored-By: Claude` trailers and no "Generated with Claude Code"
  lines. Commit as `opus-oss <304087485+opus-oss@users.noreply.github.com>`.
- **Root on a secureblue machine:** collect every privileged step into one `run0 bash -c '...'`
  for the user to run once, rather than triggering a password prompt per command. Run binaries
  through `bash`: SELinux denies `run0` a direct entrypoint into some of them (`run0 ostree ...`
  fails with exit 203).
- Never commit `cosign.key`. Ask before force-pushing, rewriting history, or turning off a security
  feature to make something work.

## Pitfalls learned the hard way

- **`/etc` is merged, `/usr` is not.** On a rebase, the machine's own `/etc` wins over the
  image's. A VM rebased from plain Silverblue kept dnsconfd and unbound, and never started
  dnscrypt-proxy or the firewall. Enable services through `/usr/lib/systemd/*/<target>.wants/`
  links, and keep the services bastion replaces from starting with
  `50-bastion-replaced.conf` drop-ins (opt back in with `/etc/bastion/enable-<unit>`).
- **Port 53:** dnscrypt-proxy is the only resolver, on `127.0.0.1:53`. unbound on the same port
  makes it crash-loop with "address already in use".
- **secureblue's updaters** (`rpm-ostreed-automatic`, `upgrade-on-boot`) run
  `verify-provenance.sh`, which only knew `ghcr.io/secureblue/*`. That blocked every update for
  weeks. The image patches it to send `ghcr.io/opus-oss/*` to `bastion-verify-provenance` (cosign
  against the pinned key), and the build fails if the patch stops applying.
- **Signed rebase from stock Silverblue:** its `policy.json` defaults to `insecureAcceptAnything`,
  and rpm-ostree refuses `ostree-image-signed:` under such a policy. `install.sh` writes a
  reject-by-default copy to `/etc` with the bootstrap marker; `bastion-policy-cleanup` removes it on
  first boot.
- **Fedora 45** has no `cosign` package, so it comes from `gcr.io/projectsigstore/cosign`, pinned by
  digest. secureblue ships `policy.json` in `/usr/share/containers` from Fedora 45 on; the build
  handles both locations.
- **forge kernel:** GRUB needs `EFI_HANDOVER_PROTOCOL`. SELinux needs `EXT4_FS_SECURITY` (`/boot` is
  ext4) and `selinux` in `CONFIG_LSM`. The root is btrfs, composefs needs EROFS, Fedora firmware is
  xz-compressed, and `MITIGATION_*` options must be set explicitly (the base was allnoconfig).
  Drivers that need firmware or another device at probe time are modules, since built-in drivers
  probe before the LUKS root exists. The initramfs needs `dracut --add ostree` and the
  `kernel/initramfs-firmware.txt` list, and the build checks both.
- **hidepid=2 breaks GDM** (its greeter's `systemd --user` cannot load `app.slice`). It was dropped.
- **Plymouth** is off through `plymouth.enable=0`. rpm-ostree did not apply a newly added
  `kargs.d` file on upgrade, so `install.sh` also sets the karg directly.
- **secureblue's umask is 077.** Anything a script creates for another user (for example
  `/var/lib/libvirt/images` for qemu) needs an explicit mode.
- **Theme:** libadwaita 1.6+ reads CSS variables (`gtk4.css`), not `@define-color`. GNOME Shell
  is recoloured in the `shelltheme` stage. Flatpak GTK3 and Electron apps need the
  `adw-gtk3-dark` Flatpak theme (from a filtered Flathub remote; filters in
  `files/usr/share/bastion/flatpak-filters`). Qt 5 KeePassXC runs frameless.
- **Bluetooth** is blocked by secureblue by default; `ujust set-bluetooth-modules on` lifts it.
- **vm kernel:** linux-hardened turns unprivileged user namespaces off, which breaks bubblewrap
  (Flatpak, oo7-daemon); `USER_NS_UNPRIVILEGED=y` leaves secureblue's SELinux policy deciding.
  Fedora's modprobe.d pulls `snd-seq` in with `snd-pcm`. x86 selects `PERF_EVENTS`
  unconditionally, so only arm64 drops it. A config change can be checked without CI: run
  `kernel/configure.sh` on an allnoconfig tree (`ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu-` for
  arm64).

## On the running system

- `bastion-tripwire` (in the image, run as root after boot and daily) compares persistence
  locations (`/etc`, `/var`, `/boot`, EFI entries, homes) against a baseline. It also flags rule
  violations: SELinux off, unsigned origin, layered packages, `/boot` files differing from their
  deployment, setuid files outside `/usr`. `run0 bastion-tripwire diff` shows findings and
  `run0 bastion-tripwire accept` re-baselines. A user timer turns findings into notifications.
- `bastion-first-login-apps` installs `files/usr/share/bastion/first-login-apps.list`, plus
  `~/.config/bastion/first-login-apps.list`, at a user's first login, along with the per-user
  Opus theme files.


## Open work

- A qcow2 of the `vm` image per arch built by bootc-image-builder (pin it by digest), published
  as an OCI artifact and signed.
- Claude Desktop: Anthropic's Linux build is an official beta for Ubuntu and Debian only. The
  community `.rpm` from aaddrick/claude-desktop-debian repackages that build. Being tested in a
  VM before anything goes into an image.
- Secure Boot with a MOK key that signs forge's and the vm image's kernels in CI (shim route; never replace the
  platform keys).

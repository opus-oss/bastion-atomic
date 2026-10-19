#!/usr/bin/env bash
# Point an existing Fedora Atomic install at this image.   sudo ./install.sh
#
# Run this on a freshly installed secureblue (or any Fedora Atomic) machine. It does not install
# an operating system and it does not touch your disks -- it tells the system to boot a different
# image from the next reboot, and leaves the one you are on in the boot menu as the way back.
#
# There is no equivalent of NixOS's update.sh here, and that is deliberate: nothing is built on
# this machine. The image is built in CI and downloaded whole, so switching is a pull, not a
# rebuild.
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "run with sudo" >&2; exit 1; }

IMAGE=${IMAGE:-ghcr.io/opus-oss/bastion-atomic:latest}

command -v rpm-ostree >/dev/null || {
  echo "This is not a Fedora Atomic system -- rpm-ostree is missing." >&2
  echo "Install secureblue first, then run this." >&2
  exit 1
}

echo "== Current deployment"
rpm-ostree status | sed 's/^/  /'

cat <<EOF

About to rebase this system onto:
  $IMAGE

Signed-image policy is used, so the pull fails if the image is not the one this repo's CI
published. Your current deployment stays in the boot menu -- if the new one misbehaves, pick the
previous entry at boot and you are back where you started.

EOF
read -r -p "Continue? [y/N] " reply
[[ ${reply,,} == y ]] || { echo "Nothing changed."; exit 0; }

echo "== Rebasing (downloads the image; several minutes)"
# ostree-image-signed: means the registry signature is verified before anything is deployed.
# The unsigned form (ostree-unverified-registry:) would work and is what most guides show; it
# also means anyone who can write to the registry can write to your laptop.
rpm-ostree rebase "ostree-image-signed:docker://$IMAGE"

cat <<'EOF'

Done. Reboot to use it.

After the reboot:
  rpm-ostree status          what you are running, and what you can roll back to
  rpm-ostree rollback        go back to the previous deployment
  rpm-ostree upgrade         pull the latest build of this image

Updates come from CI from here on: push a change to the recipe, the image rebuilds, and
`rpm-ostree upgrade` picks it up. Nothing compiles on this machine.
EOF

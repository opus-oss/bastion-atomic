#!/usr/bin/env bash
# Point an existing secureblue install at this image.   run0 bash install.sh
#
# Run this from a clone of this repo, on a freshly installed secureblue machine. It does not install
# an operating system and it does not touch your disks -- it tells the system to boot a different
# image from the next reboot, and leaves the one you are on in the boot menu as the way back.
#
# There is no equivalent of NixOS's update.sh here, and that is deliberate: nothing is built on
# this machine. The image is built in CI and downloaded whole, so switching is a pull, not a
# rebuild.
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "run with: run0 bash $0" >&2; exit 1; }
repo=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)

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
# The machine has to trust this repo's signing key before the first pull: secureblue's
# policy.json rejects every image it has no key for, which is why a bare signed rebase fails on a
# fresh install. The same three pieces the image itself ships, so after the first boot they come
# from the image and track it.
echo "== Trusting this repo's signing key"
install -m 0644 "$repo/cosign.pub" /etc/pki/containers/opus-oss.pub
install -m 0644 "$repo/files/etc/containers/registries.d/opus-oss.yaml" /etc/containers/registries.d/opus-oss.yaml
cp -n /etc/containers/policy.json /etc/containers/policy.json.before-bastion
python3 -I -c 'import json; p = "/etc/containers/policy.json"; d = json.load(open(p)); d["transports"]["docker"]["ghcr.io/opus-oss"] = [{"type": "sigstoreSigned", "keyPath": "/etc/pki/containers/opus-oss.pub", "signedIdentity": {"type": "matchRepository"}}]; json.dump(d, open(p, "w"), indent=2)'

# ostree-image-signed: means the registry signature is verified before anything is deployed.
# The unsigned form (ostree-unverified-registry:) would work and is what most guides show; it
# also means anyone who can write to the registry can write to your laptop.
rpm-ostree rebase "ostree-image-signed:docker://$IMAGE"

# The image's kargs.d asks for plymouth.enable=0, but rpm-ostree has been seen not to apply a
# newly added kargs.d file to the staged deployment, so set it directly as well. It is a no-op
# if it is already there, and carries over to later upgrades.
rpm-ostree kargs --append-if-missing=plymouth.enable=0 >/dev/null

cat <<'EOF'

Done. Reboot to use it.

The disk passphrase prompt is plain text from now on: no boot splash.

After the reboot:
  rpm-ostree status          what you are running, and what you can roll back to
  rpm-ostree rollback        go back to the previous deployment
  rpm-ostree upgrade         pull the latest build of this image

Updates come from CI from here on: push a change to the recipe, the image rebuilds, and
`rpm-ostree upgrade` picks it up. Nothing compiles on this machine.
EOF

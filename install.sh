#!/usr/bin/env bash
# Point an existing Fedora Silverblue or secureblue install at one of this repo's images.
#
#   run0 bash install.sh            generic image (bastion-atomic), any machine secureblue runs on
#   run0 bash install.sh vm         bastion-atomic-vm, QEMU/KVM guests only (UTM, libvirt)
#   run0 bash install.sh forge      bastion-atomic-forge, one Framework 13 AMD 7040 only
#
# Run this from a clone of this repo. It does not install an operating system and it does not
# touch your disks -- it tells the system to boot a different image from the next reboot, and
# leaves the one you are on in the boot menu as the way back.
#
# There is no equivalent of NixOS's update.sh here, and that is deliberate: nothing is built on
# this machine. The image is built in CI and downloaded whole, so switching is a pull, not a
# rebuild.
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "run with: run0 bash $0 [generic|vm|forge]" >&2; exit 1; }
repo=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)

case ${1:-generic} in
  generic) IMAGE=${IMAGE:-ghcr.io/opus-oss/bastion-atomic:latest} ;;
  vm)      IMAGE=${IMAGE:-ghcr.io/opus-oss/bastion-atomic-vm:latest} ;;
  forge)   IMAGE=${IMAGE:-ghcr.io/opus-oss/bastion-atomic-forge:latest} ;;
  *) echo "usage: run0 bash $0 [generic|vm|forge]" >&2; exit 1 ;;
esac
target=${1:-generic}

command -v rpm-ostree >/dev/null || {
  echo "This is not a Fedora Atomic system -- rpm-ostree is missing." >&2
  echo "Install Fedora Silverblue (or secureblue) first, then run this." >&2
  exit 1
}

# The vm and forge kernels are built for one kind of machine each and are not signed for Secure
# Boot (no MOK key yet), so refuse the combinations that cannot boot rather than leave the
# machine on a deployment that fails at the firmware.
virt=$(systemd-detect-virt --vm 2>/dev/null || true)
sb=$(mokutil --sb-state 2>/dev/null || true)
case $target in
  vm)
    [[ -n $virt && $virt != none ]] || { echo "bastion-atomic-vm only boots in a QEMU/KVM virtual machine." >&2; exit 1; }
    [[ $sb != *"SecureBoot enabled"* ]] || { echo "Secure Boot is on. Turn it off in the VM's firmware first: the vm kernel is not signed for it." >&2; exit 1; }
    ;;
  forge)
    [[ $(uname -m) == x86_64 && ( -z $virt || $virt == none ) ]] || { echo "bastion-atomic-forge only boots on the Framework 13 AMD 7040 it was built for." >&2; exit 1; }
    [[ $sb != *"SecureBoot enabled"* ]] || { echo "Secure Boot is on. Turn it off in the firmware first: the forge kernel is not signed for it." >&2; exit 1; }
    ;;
esac

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

# The machine has to trust this repo's signing key before the first pull. The same three pieces
# the image itself ships, so after the first boot they come from the image and track it.
echo "== Trusting this repo's signing key"
install -D -m 0644 "$repo/cosign.pub" /etc/pki/containers/opus-oss.pub
install -D -m 0644 "$repo/files/etc/containers/registries.d/opus-oss.yaml" /etc/containers/registries.d/opus-oss.yaml
# The policy that applies is /etc/containers/policy.json if it exists, otherwise the one in
# /usr/share/containers (read-only here; Fedora and secureblue keep it there from Fedora 45 on).
# The key goes into a copy in /etc, taken from whichever applies now.
#
# Stock Silverblue's policy accepts any image by default, and rpm-ostree refuses a signed rebase
# under such a policy ("specifies a default of `insecureAcceptAnything`; refusing usage"). That is
# why other guides rebase unsigned first. Instead the copy rejects by default, so the very first
# pull is already verified. It only has to last until the reboot: the copy is marked, and the
# image deletes it on first boot (bastion-policy-cleanup.service) once its own policy, secureblue's
# with the key added, is in place. Without that cleanup the copy would hide every later change
# secureblue makes to its policy. A copy that was already in /etc with a strict default (secureblue
# before Fedora 45) is the machine's own, and only gains the key.
if [[ -e /etc/containers/policy.json ]]; then
  [[ -e /etc/containers/policy.json.before-bastion ]] || cp /etc/containers/policy.json /etc/containers/policy.json.before-bastion
  src=/etc/containers/policy.json
else
  src=/usr/share/containers/policy.json
  touch /etc/containers/.bastion-bootstrap-policy
fi
rc=0
python3 -I - "$src" /etc/containers/policy.json <<'EOF' || rc=$?
import json, sys
src, dst = sys.argv[1:]
d = json.load(open(src))
d["transports"].setdefault("docker", {})["ghcr.io/opus-oss"] = [{"type": "sigstoreSigned", "keyPath": "/etc/pki/containers/opus-oss.pub", "signedIdentity": {"type": "matchRepository"}}]
insecure = any(r.get("type") == "insecureAcceptAnything" for r in d.get("default", []))
if insecure:
    d["default"] = [{"type": "reject"}]
json.dump(d, open(dst, "w"), indent=2)
sys.exit(3 if insecure else 0)
EOF
case $rc in
  0) ;;
  3) touch /etc/containers/.bastion-bootstrap-policy ;;
  *) exit "$rc" ;;
esac

echo "== Rebasing (downloads the image; several minutes)"
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

# Coming from stock Silverblue, secureblue's own post-install steps have not run. Its hardening
# kernel arguments are not applied by a rebase, and its kernel is signed with its own key.
if [[ ! -d /usr/libexec/secureblue ]]; then
  cat <<'EOF'

This machine was not running secureblue, so after the reboot also run:
  ujust set-kargs-hardening  secureblue's hardening kernel arguments (a rebase does not apply them)
EOF
  [[ $target == generic && $sb == *"SecureBoot enabled"* ]] && cat <<'EOF'
  ujust enroll-secureblue-secure-boot-key
                             secureblue signs its kernel with its own key. If the first boot
                             stops at a Secure Boot error, turn Secure Boot off for that boot,
                             run this, reboot, choose "Enroll MOK" (password: secureblue), then
                             turn Secure Boot back on.
EOF
fi
exit 0

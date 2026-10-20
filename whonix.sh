#!/usr/bin/env bash
# Download, verify and install Whonix for KVM.   run0 bash whonix.sh [lxqt|cli]
#
# Whonix is a gateway VM that routes everything through Tor and a workstation VM with no route
# to anything except the gateway. The isolation is the point, so this script refuses to install
# anything it cannot prove came from the Whonix project: the signing key is pinned by
# fingerprint below, and a key that does not match it is a failure, not a prompt.
#
# Deviation from the upstream instructions, on purpose: Whonix's wiki uses `qemu:///session`,
# per-user libvirt. This host runs the system libvirt daemons (ujust set-libvirt-daemons on),
# so everything here uses qemu:///system, and the disk images live under /var/lib/libvirt
# with the SELinux labels libvirt expects there.
#
# Run through bash, not directly: SELinux refuses run0 an entrypoint into most binaries.
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "run with: run0 bash $0" >&2; exit 1; }

VERSION=18.2.4.1
# Patrick Schleizer <adrelanos@whonix.org>, from whonix.org/wiki/Main/Project_Signing_Key.
# Verifying a signature against a key fetched from the same site proves only that the site is
# self-consistent. Pinning the fingerprint here is what makes the check mean anything.
FINGERPRINT=916B8D99C38EAF5E8ADC7A2A8D66066A2EEACCDA
KEY_URL=https://www.whonix.org/keys/derivative.asc
BASE=https://download.whonix.org/libvirt/$VERSION

case "${1:-lxqt}" in
  lxqt) FLAVOUR=LXQt ;;
  cli) FLAVOUR=CLI ;;
  *) echo "usage: $0 [lxqt|cli]" >&2; exit 1 ;;
esac
ARCHIVE=Whonix-$FLAVOUR-$VERSION.Intel_AMD64.qcow2.libvirt.xz

work=/var/lib/libvirt/whonix
images=/var/lib/libvirt/images
# 0711, as Fedora ships it: the qemu user has to be able to reach the disk images, and a plain
# mkdir -p under secureblue's umask 077 would make the directory root-only (virt-manager then
# fails with "Cannot access storage file ... Permission denied"). libvirt's dynamic ownership
# hands each image to qemu while its machine runs.
mkdir -p "$work"
install -d -m 0711 "$images"
chmod 0711 "$images"
cd "$work"

# A throwaway keyring, so root's own is never touched.
gpg_bin=$(command -v gpg) || { echo "gpg not found" >&2; exit 1; }
export GNUPGHOME="$work/gnupg"
rm -rf "$GNUPGHOME"
mkdir -p -m 700 "$GNUPGHOME"

echo "== Signing key"
curl -fsSL --proto '=https' --tlsv1.2 -o derivative.asc "$KEY_URL"
"$gpg_bin" --quiet --import derivative.asc
got=$("$gpg_bin" --with-colons --fingerprint | awk -F: '/^fpr:/ {print $10; exit}')
if [[ $got != "$FINGERPRINT" ]]; then
  echo "FINGERPRINT MISMATCH" >&2
  echo "  expected $FINGERPRINT" >&2
  echo "  got      $got" >&2
  echo "Refusing to continue. Either the key rotated and this script needs updating, or the" >&2
  echo "download was tampered with. Check whonix.org/wiki/Main/Project_Signing_Key." >&2
  exit 1
fi
echo "   key matches the pinned fingerprint"

echo "== Image ($ARCHIVE, about 2 GB; resumes if interrupted)"
curl -fL --proto '=https' --tlsv1.2 -C - -o "$ARCHIVE" "$BASE/$ARCHIVE"
curl -fsSL --proto '=https' --tlsv1.2 -o "$ARCHIVE.asc" "$BASE/$ARCHIVE.asc"

echo "== Signature"
# Whonix signs with a subkey, so VALIDSIG's first field is that subkey's fingerprint and the
# primary key's is the last one. Comparing the pin against the last field is both correct here
# and the right check in general: it ties the signature back to the pinned primary key however
# many signing subkeys sit under it, and keeps working when one is rotated.
primary=$("$gpg_bin" --status-fd 1 --verify "$ARCHIVE.asc" "$ARCHIVE" 2>/dev/null \
  | awk '/^\[GNUPG:\] VALIDSIG /{print $NF; exit}')
if [[ $primary != "$FINGERPRINT" ]]; then
  echo "SIGNATURE CHECK FAILED for $ARCHIVE -- not installing it." >&2
  exit 1
fi
echo "   signed by the pinned key"

echo "== Extracting (sparse)"
tar -xSf "$ARCHIVE"

# The domain XML asks the pool for a volume by the bare name Whonix-Gateway.qcow2, while the
# archive ships the flavour and version in the filename, so the images are renamed as they are
# installed. Existing ones are left alone: a re-run must not throw away a workstation that has
# already been used.
echo "== Installing disk images"
shopt -s nullglob
for img in Whonix-*.qcow2; do
  case $img in
    *Gateway*) short=Whonix-Gateway.qcow2 ;;
    *Workstation*) short=Whonix-Workstation.qcow2 ;;
    *) short=$img ;;
  esac
  if [[ -e $images/$short ]]; then
    echo "   $short already present, keeping it"
    rm -f "$img"
  else
    mv -n "$img" "$images/$short"
    chown root:root "$images/$short"
    chmod 0600 "$images/$short"
    echo "   $short"
  fi
done

# libvirt may start with no storage pools at all, and the Whonix domains reference one
# called "default" by name -- without it they fail to start with "Storage pool not found".
echo "== Storage pool"
if virsh -c qemu:///system pool-info default >/dev/null 2>&1; then
  echo "   default already defined"
else
  virsh -c qemu:///system pool-define-as default dir --target "$images" >/dev/null
  virsh -c qemu:///system pool-autostart default >/dev/null
  echo "   default -> $images"
fi
virsh -c qemu:///system pool-start default >/dev/null 2>&1 || true
virsh -c qemu:///system pool-refresh default >/dev/null 2>&1 || true

# No networks to define. Whonix 18 does not use libvirt networks: the gateway reaches clearnet
# through QEMU's own userspace stack (interface type='user') and the two machines are joined by
# a UDP socket pair on loopback (type='udp', ports 5577 and 6688). Nothing is bridged, so the
# forward chain in /etc/nftables/bastion.nft can stay shut, and the loopback pair is already
# allowed by its `iif lo accept` and `oif lo accept`.
echo "== Defining machines"
for xml in *.xml; do
  grep -q '<domain' "$xml" || continue
  virsh -c qemu:///system define "$xml" >/dev/null
  echo "   $(sed -n 's:.*<name>\(.*\)</name>.*:\1:p' "$xml" | head -1)"
done

echo
echo "Installed. Start the gateway first and give it a moment to reach Tor, then the"
echo "workstation -- the workstation has no route anywhere except through the gateway:"
echo "  virsh -c qemu:///system start Whonix-Gateway"
echo "  virsh -c qemu:///system start Whonix-Workstation"
echo
echo "Consoles: virt-viewer, or  virsh -c qemu:///system console Whonix-Gateway"

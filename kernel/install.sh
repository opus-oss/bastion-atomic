#!/usr/bin/env bash
# Swap secureblue's kernel for one built in this Containerfile:  install.sh <kver> [firmware list]
# Run by the forge and vm stages, after the built kernel's /lib/modules/<kver> has been copied into
# /usr/lib/modules.
#
# An ostree deployment boots whatever single kernel is in /usr/lib/modules, with vmlinuz and
# initramfs.img beside its modules, so the old packages go (--nodeps: kernel-tools and friends name
# them but work with any kernel; --noscripts: their scriptlets call kernel-install, which has
# nothing to do in an image build) and the initramfs is regenerated for the new one with
# secureblue's own dracut settings.
set -euxo pipefail
kver=$1
fwlist=${2:-}
[ -e "/usr/lib/modules/$kver/vmlinuz" ]

rpm -e --nodeps --noscripts $(rpm -qa --qf '%{NAME}\n' kernel kernel-core 'kernel-modules*')
for d in /usr/lib/modules/*; do [ "${d##*/}" = "$kver" ] || rm -rf "$d"; done
depmod -a "$kver"

# Built-in drivers probe before the root filesystem exists, so their firmware has to be in the
# initramfs. A missing file is a build error, not a black screen at the LUKS prompt.
fw=""
if [ -n "$fwlist" ]; then
  for f in $(grep -vE '^\s*(#|$)' "$fwlist"); do
    found=""
    for c in "/usr/lib/firmware/$f" "/usr/lib/firmware/$f.xz" "/usr/lib/firmware/$f.zst"; do
      [ -e "$c" ] && found="$c"
    done
    [ -n "$found" ] || { echo "firmware not found: $f" >&2; exit 1; }
    fw="$fw $found"
  done
fi

# --add ostree: the module only includes itself on request (check() returns 255), and without
# ostree-prepare-root the initramfs cannot mount the deployment. rpm-ostree asks for it when it
# builds an initramfs; a hand-run dracut has to ask too.
# --omit plymouth: plymouth.enable=0 (kargs.d) turns it off anyway; leaving it out of the
# initramfs keeps the image smaller and the LUKS prompt on the text console.
install=()
[ -z "$fw" ] || install=(--install "$fw")
dracut --no-hostonly --kver "$kver" --reproducible --zstd --add ostree --omit plymouth \
  "${install[@]}" -f "/usr/lib/modules/$kver/initramfs.img"
chmod 0600 "/usr/lib/modules/$kver/initramfs.img"

# dracut reports some failures (an uncopyable /root, for one) and still exits 0, so check that
# what the machine cannot boot without made it in: the firmware, the LUKS unlock, the step
# that mounts the ostree deployment, and the amnesic entry's read-only root.
lsinitrd -m "/usr/lib/modules/$kver/initramfs.img"
list=$(mktemp)
lsinitrd "/usr/lib/modules/$kver/initramfs.img" > "$list"
for want in $fw /usr/lib/systemd/systemd-cryptsetup /usr/lib/ostree/ostree-prepare-root \
    /usr/lib/systemd/system-generators/bastion-amnesic-initrd-generator /usr/libexec/bastion-amnesic-root; do
  grep -qF " ${want#/}" "$list" || { echo "missing from initramfs: $want" >&2; exit 1; }
done
rm "$list"

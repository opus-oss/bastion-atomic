#!/usr/bin/env bash
# Build the vm kernel for Ubuntu guests as a .deb:  ubuntu/kernel/build.sh <out dir>
#
# Runs in an ubuntu:26.04 container in CI (.github/workflows/ubuntu.yml), natively per arch. The
# source is the same as bastion-atomic-vm's: the kernel.org tarball and linux-hardened patch
# pinned in the Containerfile (read from there, so there is one pin), verified the same way, with
# kernel/vm/common.config, the arch fragment and kernel/vm/ubuntu*.config over allnoconfig.
# Modules are signed with a key generated for this build and thrown away with the tree.
set -euo pipefail
out=$(realpath -m "$1")
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
arg() { sed -n "s/^ARG $1=//p" "$repo/Containerfile" | head -n1; }
KERNEL_VERSION=$(arg KERNEL_VERSION) HARDENED_VERSION=$(arg HARDENED_VERSION)
KERNEL_SHA256=$(arg KERNEL_SHA256) HARDENED_KEY=$(arg HARDENED_KEY)
[[ -n $KERNEL_VERSION && -n $HARDENED_VERSION && -n $KERNEL_SHA256 && -n $HARDENED_KEY ]]

case $(dpkg --print-architecture) in
  arm64) frags=(arm64 ubuntu ubuntu-arm64) ;;
  amd64) frags=(x86_64 ubuntu) ;;
  *) echo "no vm kernel for $(dpkg --print-architecture)" >&2; exit 1 ;;
esac

work=$(mktemp -d)
cd "$work"
curl -fsSLO "https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-${KERNEL_VERSION}.tar.xz"
echo "${KERNEL_SHA256}  linux-${KERNEL_VERSION}.tar.xz" | sha256sum -c
export GNUPGHOME=$work/gnupg; install -d -m 0700 "$GNUPGHOME"
gpg --batch --quiet --import "$repo/kernel/linux-hardened-signing-key.asc"
status=$(gpg --batch --status-fd 1 --verify "$repo/kernel/linux-hardened-v${HARDENED_VERSION}.patch.sig" \
  "$repo/kernel/linux-hardened-v${HARDENED_VERSION}.patch" 2>/dev/null)
[[ $status == *"VALIDSIG ${HARDENED_KEY} "* ]] || { echo "linux-hardened patch signature bad" >&2; exit 1; }
tar -xf "linux-${KERNEL_VERSION}.tar.xz"
cd "linux-${KERNEL_VERSION}"
patch -s -p1 < "$repo/kernel/linux-hardened-v${HARDENED_VERSION}.patch"

export LLVM=1
clang --version | head -n1
make -s allnoconfig
cp .config ../allnoconfig
args=(../allnoconfig "$repo/kernel/vm/common.config")
for f in "${frags[@]}"; do args+=("$repo/kernel/vm/$f.config"); done
bash "$repo/kernel/configure.sh" . "${args[@]}"
# Package version: the kernel's plus the build time, so every build upgrades the last one.
make -s -j"$(nproc)" bindeb-pkg KDEB_PKGVERSION="${KERNEL_VERSION}-$(date -u +%Y%m%d%H%M)" \
  KDEB_SOURCENAME=linux-bastion-ubuntu
install -d "$out"
for d in ../linux-image-*.deb; do [[ $d == *-dbg_* ]] || mv "$d" "$out/"; done
ls "$out"/linux-image-*-bastion-ubuntu_*.deb >/dev/null
ls -l "$out"
rm -rf "$work"

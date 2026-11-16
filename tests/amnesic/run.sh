#!/usr/bin/env bash
# Amnesic boot test:  tests/amnesic/run.sh <vm image ref>
# Builds a qcow2 of the vm image (plus the in-guest test) with bootc-image-builder and boots it
# three times in QEMU/KVM: normal, amnesic, normal. guest-test reports on the serial console.
# Needs root (podman for bootc-image-builder, KVM) and qemu-system-x86, ovmf.
set -euo pipefail
image=$1
here=$(cd "$(dirname "$0")" && pwd)
bib=${BIB:-quay.io/centos-bootc/bootc-image-builder:latest}
out=${OUT:-$PWD/amnesic-test-out}
mkdir -p "$out"

podman pull -q "$image"
podman build -t localhost/bastion-amnesic-test:latest --build-arg "IMAGE=$image" "$here"
podman pull -q "$bib"
echo "bootc-image-builder: $(podman image inspect --format '{{.Digest}}' "$bib")"
podman run --rm --privileged --security-opt label=type:unconfined_t \
  -v "$here/config.toml:/config.toml:ro" -v "$out:/output" \
  -v /var/lib/containers/storage:/var/lib/containers/storage \
  "$bib" --type qcow2 --rootfs btrfs localhost/bastion-amnesic-test:latest
podman rmi -f localhost/bastion-amnesic-test:latest "$image" >/dev/null || true

disk=$out/qcow2/disk.qcow2
cp /usr/share/OVMF/OVMF_VARS_4M.fd "$out/vars.fd"
log=$out/serial.log
: > "$log"
qemu-system-x86_64 -machine q35,accel=kvm -cpu host -smp 2 -m 4096 \
  -drive if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.fd \
  -drive if=pflash,format=raw,file="$out/vars.fd" \
  -drive file="$disk",if=virtio,format=qcow2 \
  -nic none -display none -serial file:"$log" -monitor none &
qemu=$!

# Three boots of a desktop image; 20 minutes is several times what they take.
result=timeout
for _ in $(seq 1200); do
  if grep -q 'AMNESIC-TEST: PASS' "$log"; then result=pass; break; fi
  if grep -q 'AMNESIC-TEST: FAIL' "$log"; then result=fail; break; fi
  kill -0 "$qemu" 2>/dev/null || { result=exited; break; }
  sleep 1
done
[ "$result" != exited ] || ! grep -q 'AMNESIC-TEST: PASS' "$log" || result=pass
sleep 5
kill "$qemu" 2>/dev/null || true
grep -a 'AMNESIC-TEST' "$log" || true
echo "result: $result"
[ "$result" = pass ]

#!/usr/bin/env bash
# Checks a machine after `ubuntu/install.sh` and a reboot. Run as root; exits non-zero on any
# failure and prints every check either way. CI runs it in a booted Ubuntu cloud image.
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
fail=0
bastion_kernel=0; [[ $(uname -r) == *-bastion-ubuntu ]] && bastion_kernel=1
ok()  { printf 'ok    %s\n' "$1"; }
bad() { printf 'FAIL  %s\n' "$1"; fail=1; }
check() { local d=$1; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else bad "$d"; fi; }

# Kernel arguments: every one in 90-bastion.cfg is on the running kernel's command line.
kargs=$(sed -n 's/^GRUB_CMDLINE_LINUX_DEFAULT="\$GRUB_CMDLINE_LINUX_DEFAULT \(.*\)"$/\1/p' "$HERE/../files/etc/default/grub.d/90-bastion.cfg")
[[ -n $kargs ]] || bad "parsed kargs from 90-bastion.cfg"
for k in $kargs; do grep -qw -- "$k" /proc/cmdline || bad "karg $k"; done
ok "kargs checked ($(wc -w <<<"$kargs"))"

# sysctl: every key at its value.
while IFS='=' read -r k v; do
  k=$(xargs <<<"$k"); v=$(xargs <<<"$v")
  [[ -z $k || $k == \#* ]] && continue
  # Compiled out of the bastion kernel (kexec, perf, ...) is stronger than switched off.
  [[ $bastion_kernel == 1 && ! -e /proc/sys/${k//.//} ]] && continue
  [[ $(sysctl -n "$k" 2>/dev/null | xargs) == "$v" ]] || bad "sysctl $k = $v (is $(sysctl -n "$k" 2>&1))"
done < "$HERE/../../files/etc/sysctl.d/90-bastion.conf"
ok "sysctl checked"
if [[ -n ${EXPECT_KERNEL:-} ]]; then check "running $EXPECT_KERNEL (is $(uname -r))" test "$(uname -r)" = "$EXPECT_KERNEL"; fi
if [[ $bastion_kernel == 1 ]]; then
  check "unprivileged user namespaces off" test "$(sysctl -n kernel.unprivileged_userns_clone)" = 0
  check "AppArmor is an active LSM" grep -qw apparmor /sys/kernel/security/lsm
  check "Ubuntu's kernel kept as fallback" bash -c 'ls /boot/vmlinuz-*-generic'
  check "chrome-sandbox setuid" test -u /usr/lib/claude-desktop/chrome-sandbox
else
  check "kernel.apparmor_restrict_unprivileged_userns=1" test "$(sysctl -n kernel.apparmor_restrict_unprivileged_userns)" = 1
fi

check "modprobe dccp refused" bash -c '! modprobe dccp'
check "lockdown is confidentiality" grep -q '\[confidentiality\]' /sys/kernel/security/lockdown

check "nft table inet bastion loaded" nft list table inet bastion
check "input policy drop" bash -c 'nft list chain inet bastion input | grep -q "policy drop"'
check "plaintext DNS (tcp 9.9.9.9:53) refused" bash -c '! timeout 5 bash -c "</dev/tcp/9.9.9.9/53"'

for u in bastion-nftables bastion-dnscrypt-proxy usbguard apparmor; do
  check "$u active" systemctl is-active "$u.service"
done
check "bastion-timesync.timer active" systemctl is-active bastion-timesync.timer
check "bastion-timesync ran" bash -c 'systemctl start bastion-timesync.service && systemctl show -p Result --value bastion-timesync.service | grep -qx success'
for u in systemd-resolved chrony systemd-timesyncd dnscrypt-proxy avahi-daemon ufw nftables; do
  check "$u not running" bash -c "! systemctl is-active -q $u.service"
done
check "resolv.conf is loopback only" bash -c 'grep -E "^nameserver" /etc/resolv.conf | grep -vqE "127\.0\.0\.1|::1" && exit 1 || exit 0'
check "name resolution works (via dnscrypt-proxy)" getent ahosts kernel.org

check "snapd gone" bash -c '! command -v snap && ! dpkg -s snapd'
check "apport/whoopsie gone" bash -c '! dpkg -s apport && ! dpkg -s whoopsie'
check "firefox from Mozilla" bash -c 'apt-cache policy firefox | grep -q packages.mozilla.org && dpkg -s firefox | grep -q "^Status: install ok installed"'
check "claude-desktop installed" dpkg -s claude-desktop
exe=$(readlink -f "$(command -v claude-desktop)")
check "claude-desktop libraries resolve ($exe)" bash -c "! ldd '$exe' | grep -q 'not found'"
check "claude-desktop allowed a user namespace" bash -c "aa-status 2>/dev/null | grep -qE 'claude'"
check "AppArmor enforcing profiles" bash -c '(( $(aa-status --enforced) > 0 ))'
check "core dumps off" grep -q "Storage=none" /etc/systemd/coredump.conf.d/50-bastion.conf

exit $fail

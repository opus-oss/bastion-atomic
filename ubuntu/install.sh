#!/usr/bin/env bash
# Bastion's hardening on Ubuntu 26.04 LTS, with Claude Desktop installed natively.
#
#   sudo bash ubuntu/install.sh
#
# Run it on an installed system (not the live ISO), from a checkout of this repository. It is
# idempotent: run it again after `git pull` to apply changes. Reboot afterwards, since the kernel
# arguments and module blocklist only take effect on the next boot.
#
# Shared configuration comes from ../files, the same files the Atomic images ship, so there is one
# copy of each. Ubuntu-only pieces are in ubuntu/files.
set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "run as root: sudo bash $0" >&2; exit 1; }
. /etc/os-release
[[ $ID == ubuntu && $VERSION_ID == 26.04 ]] || { echo "Ubuntu 26.04 only (this is $PRETTY_NAME)" >&2; exit 1; }
[[ -d /run/systemd/system ]] || { echo "systemd is not running (live ISO or a container?)" >&2; exit 1; }

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SHARED=$HERE/../files
LOCAL=$HERE/files
export DEBIAN_FRONTEND=noninteractive
APT=(apt-get -y -q -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

log() { printf '\n== %s\n' "$*"; }
put() { install -D -m "${3:-0644}" "$1" "$2"; }   # put <src> <dest> [mode]
# apt-get purge fails outright on a name it does not know, so only pass what is installed.
purge_installed() {
  local p have=()
  for p in "$@"; do [[ $(dpkg-query -W -f='${Status}' "$p" 2>/dev/null) == *"ok installed" ]] && have+=("$p"); done
  (( ${#have[@]} == 0 )) || "${APT[@]}" purge "${have[@]}"
}

CLAUDE_FPR=31DDDE24DDFAB679F42D7BD2BAA929FF1A7ECACE
CLAUDE_KEY=https://downloads.claude.ai/claude-desktop/key.asc
MOZILLA_FPR=35BAA0B33E9EB396F59CA838C0BA5CE6DC6315A3
MOZILLA_KEY=https://packages.mozilla.org/apt/repo-signing-key.gpg

# Fetch a repository key, refuse it unless it is exactly one primary key with the pinned
# fingerprint, and store it dearmored for apt's Signed-By.
pinned_key() {  # pinned_key <url> <fingerprint> <keyring>
  local tmp; tmp=$(mktemp -d)
  curl -fsSL --proto '=https' --tlsv1.2 "$1" -o "$tmp/key"
  local fprs
  fprs=$(gpg --homedir "$tmp" --batch --show-keys --with-colons "$tmp/key" 2>/dev/null |
         awk -F: '$1=="pub"{p=1;next} $1=="fpr"&&p{print $10;p=0}')
  if [[ $fprs != "$2" ]]; then
    echo "$1 holds [$fprs], expected exactly $2" >&2; rm -rf "$tmp"; exit 1
  fi
  gpg --homedir "$tmp" --batch --yes --dearmor -o "$3.new" "$tmp/key"
  chmod 0644 "$3.new"; mv "$3.new" "$3"; rm -rf "$tmp"
  echo "$(basename "$3"): $2 matches the pin"
}

# --- Packages ------------------------------------------------------------------------------------
log "Base packages"
"${APT[@]}" update
"${APT[@]}" install curl gnupg ca-certificates nftables dnscrypt-proxy usbguard \
  apparmor apparmor-utils apparmor-profiles-extra unattended-upgrades python3 \
  fonts-inter fonts-jetbrains-mono dconf-cli
if [[ $(systemd-detect-virt) != none ]]; then
  # Clipboard, display resizing and host commands for UTM/libvirt guests.
  "${APT[@]}" install qemu-guest-agent spice-vdagent
fi

# --- Snap out, Firefox from Mozilla -----------------------------------------------------------------
# All of these are Recommends of ubuntu-desktop-minimal, so purging them leaves the desktop
# metapackage (and autoremove) alone.
log "Removing snapd"
if command -v snap >/dev/null; then
  # Apps first, then the runtimes they use, snapd last: snap refuses to remove a base in use.
  for _ in 1 2 3 4 5; do
    left=$(snap list 2>/dev/null | awk 'NR>1 && $1!="snapd" {print $1}')
    [[ -z $left ]] && break
    for s in $left; do snap remove --purge "$s" >/dev/null 2>&1 || true; done
  done
  snap remove --purge snapd >/dev/null 2>&1 || true
fi
put "$LOCAL/etc/apt/preferences.d/bastion" /etc/apt/preferences.d/bastion
purge_installed snapd
# Ubuntu's firefox is a transitional package that installs the snap; Mozilla's is kept on a re-run.
[[ $(dpkg-query -W -f='${Version}' firefox 2>/dev/null) == *snap* ]] && purge_installed firefox
rm -rf /snap /var/snap /var/lib/snapd /var/cache/snapd

log "Telemetry and crash reporters out"
purge_installed apport apport-gtk apport-core-dump-handler whoopsie ubuntu-report \
  popularity-contest kerneloops
command -v pro >/dev/null && pro config set apt_news=false >/dev/null 2>&1 || true
systemctl disable --now motd-news.timer 2>/dev/null || true

log "Repositories: Mozilla, Anthropic"
install -d -m 0755 /etc/apt/keyrings
pinned_key "$MOZILLA_KEY" "$MOZILLA_FPR" /etc/apt/keyrings/bastion-mozilla.gpg
pinned_key "$CLAUDE_KEY" "$CLAUDE_FPR" /etc/apt/keyrings/bastion-claude-desktop.gpg
put "$LOCAL/etc/apt/sources.list.d/bastion-mozilla.sources" /etc/apt/sources.list.d/bastion-mozilla.sources
put "$LOCAL/etc/apt/sources.list.d/bastion-claude-desktop.sources" /etc/apt/sources.list.d/bastion-claude-desktop.sources
put "$LOCAL/etc/apt/apt.conf.d/52bastion-unattended" /etc/apt/apt.conf.d/52bastion-unattended
"${APT[@]}" update
"${APT[@]}" install firefox claude-desktop
# Captured first: `| grep -q` under pipefail fails when grep exits before apt-cache is done writing.
policy=$(apt-cache policy firefox)
[[ $policy == *packages.mozilla.org* ]] || { echo "firefox is not from Mozilla:"; echo "$policy"; exit 1; } >&2

# --- Kernel: sysctl, modules, arguments ----------------------------------------------------------
log "sysctl, module blocklist, kernel arguments"
put "$SHARED/etc/sysctl.d/90-bastion.conf" /etc/sysctl.d/90-bastion.conf
put "$SHARED/etc/modprobe.d/90-bastion-blocked.conf" /etc/modprobe.d/90-bastion-blocked.conf
# -e: keys the running kernel lacks (the bastion kernel compiles out kexec, perf, ...) are skipped.
sysctl -e -q --system
put "$LOCAL/etc/default/grub.d/90-bastion.cfg" /etc/default/grub.d/90-bastion.cfg
update-grub
# The blocklist has to be in the initramfs too, or a module loaded there escapes it.
if command -v dracut >/dev/null; then dracut -q --force --regenerate-all; else update-initramfs -u -k all; fi

# --- Kernel: the minimal linux-hardened vm kernel -------------------------------------------------
# bastion-atomic-vm's kernel (kernel/vm), built for Ubuntu in CI as a .deb, cosign-signed with this
# repo's key and published as the ubuntu-kernel release. Virtual hardware only, so only on a
# QEMU/KVM guest. Ubuntu's kernel stays installed as the fallback entry in GRUB.
# BASTION_KERNEL=stock skips it; BASTION_KERNEL_DEB=<file> installs a local build (CI).
install_bastion_kernel() {
  local virt arch tmp deb kver
  virt=$(systemd-detect-virt 2>/dev/null || true)
  if [[ ${BASTION_KERNEL:-} == stock ]]; then log "Kernel: keeping Ubuntu's (BASTION_KERNEL=stock)"; return; fi
  case $virt in kvm|qemu) ;; *) log "Kernel: not a QEMU/KVM guest ($virt), keeping Ubuntu's"; return ;; esac
  log "Kernel: linux-hardened, virtual hardware only"
  arch=$(dpkg --print-architecture)
  tmp=$(mktemp -d)
  if [[ -n ${BASTION_KERNEL_DEB:-} ]]; then
    deb=$tmp/$(basename "$BASTION_KERNEL_DEB"); cp "$BASTION_KERNEL_DEB" "$deb"
  else
    local api=https://api.github.com/repos/opus-oss/bastion-atomic/releases/tags/ubuntu-kernel url
    if ! url=$(curl -fsSL "$api" | python3 -c 'import json,sys
for a in json.load(sys.stdin)["assets"]:
    if a["name"].startswith("linux-image-") and a["name"].endswith("_'"$arch"'.deb"): print(a["browser_download_url"])'); then
      echo "no published kernel yet; keeping Ubuntu's" >&2; rm -rf "$tmp"; return
    fi
    [[ -n $url && $url != *$'\n'* ]] || { echo "expected one $arch kernel in the release, got: $url" >&2; exit 1; }
    deb=$tmp/$(basename "$url")
    curl -fsSL --proto '=https' "$url" -o "$deb"
    curl -fsSL --proto '=https' "$url.sig" -o "$tmp/sig.b64"
    base64 -d "$tmp/sig.b64" > "$tmp/sig"
    openssl dgst -sha256 -verify "$HERE/../cosign.pub" -signature "$tmp/sig" "$deb" >/dev/null ||
      { echo "$(basename "$deb"): signature does not verify against cosign.pub" >&2; exit 1; }
    echo "$(basename "$deb"): signature good (cosign.pub)"
  fi
  kver=$(dpkg-deb -f "$deb" Package); kver=${kver#linux-image-}
  "${APT[@]}" install "$deb"
  [[ -e /boot/initrd.img-$kver ]] || dracut -q --force --kver "$kver"
  # Chromium's sandbox needs a user namespace, which this kernel does not give unprivileged
  # processes, or its setuid helper. Electron apps ship the helper; make sure Claude Desktop's is.
  local sb
  for sb in /usr/lib/claude-desktop/chrome-sandbox; do
    [[ -e $sb ]] && { dpkg-statoverride --list "$sb" >/dev/null || dpkg-statoverride --update --add root root 4755 "$sb"; }
  done
  cat > /etc/default/grub.d/91-bastion-kernel.cfg <<CFG
# Boot the bastion kernel by default (written by ubuntu/install.sh). Ubuntu's kernel is still in
# the menu: hold Shift (BIOS) or press Esc (UEFI) at boot to pick it.
GRUB_DISABLE_SUBMENU=y
GRUB_DEFAULT="Ubuntu, with Linux $kver"
CFG
  update-grub
  grep -qF "menuentry 'Ubuntu, with Linux $kver'" /boot/grub/grub.cfg ||
    { echo "no GRUB entry for $kver; remove /etc/default/grub.d/91-bastion-kernel.cfg" >&2; exit 1; }
  rm -rf "$tmp"
}
install_bastion_kernel

log "No core dumps"
put "$LOCAL/etc/systemd/coredump.conf.d/50-bastion.conf" /etc/systemd/coredump.conf.d/50-bastion.conf
put "$LOCAL/etc/security/limits.d/50-bastion-nocore.conf" /etc/security/limits.d/50-bastion-nocore.conf

# --- Firewall ------------------------------------------------------------------------------------
# Bastion's ruleset unchanged: default-drop input, no forwarding except libvirt's bridges, and
# plaintext DNS rejected so nothing can route around the encrypted resolver.
log "Firewall (nftables, ufw off)"
put "$SHARED/etc/nftables/bastion.nft" /etc/nftables/bastion.nft
put "$SHARED/usr/lib/systemd/system/bastion-nftables.service" /etc/systemd/system/bastion-nftables.service
command -v ufw >/dev/null && ufw disable >/dev/null 2>&1 || true
# nftables.service loads /etc/nftables.conf, which starts with `flush ruleset`.
systemctl mask ufw.service nftables.service 2>/dev/null || true
systemctl daemon-reload
systemctl enable --now bastion-nftables.service
systemctl reload bastion-nftables.service

# --- DNS -----------------------------------------------------------------------------------------
# dnscrypt-proxy on loopback is the only resolver. systemd-resolved and avahi go: resolved would
# forward to whatever DHCP offered over plaintext port 53, mDNS is rejected by the firewall anyway.
log "DNS over HTTPS (dnscrypt-proxy on 127.0.0.1:53)"
put "$SHARED/etc/dnscrypt-proxy/dnscrypt-proxy.toml" /etc/bastion/dnscrypt-proxy.toml
put "$LOCAL/etc/systemd/system/bastion-dnscrypt-proxy.service" /etc/systemd/system/bastion-dnscrypt-proxy.service
systemctl disable --now dnscrypt-proxy.service dnscrypt-proxy.socket dnscrypt-proxy-resolvconf.service 2>/dev/null || true
systemctl mask dnscrypt-proxy.service dnscrypt-proxy.socket dnscrypt-proxy-resolvconf.service
systemctl disable --now systemd-resolved-monitor.socket systemd-resolved-varlink.socket systemd-resolved.service avahi-daemon.service avahi-daemon.socket cups-browsed.service 2>/dev/null || true
systemctl mask systemd-resolved-monitor.socket systemd-resolved-varlink.socket systemd-resolved.service avahi-daemon.service avahi-daemon.socket cups-browsed.service
if [[ -d /etc/NetworkManager/conf.d ]]; then
  put "$SHARED/etc/NetworkManager/conf.d/zz-bastion-dns.conf" /etc/NetworkManager/conf.d/zz-bastion-dns.conf
fi
rm -f /etc/resolv.conf
put "$SHARED/etc/resolv.conf" /etc/resolv.conf
systemctl daemon-reload
systemctl enable bastion-dnscrypt-proxy.service
systemctl restart bastion-dnscrypt-proxy.service
systemctl reload NetworkManager.service 2>/dev/null || true

# --- Clock ---------------------------------------------------------------------------------------
# No NTP (Ubuntu runs chrony from 25.10 on). The clock comes from HTTPS Date headers with a quorum.
log "Clock from HTTPS (no NTP)"
put "$SHARED/usr/lib/bastion-timesync.py" /usr/local/lib/bastion/bastion-timesync.py
put "$SHARED/etc/bastion/timesync.json" /etc/bastion/timesync.json
sed 's|/usr/lib/bastion-timesync.py|/usr/local/lib/bastion/bastion-timesync.py|' \
  "$SHARED/usr/lib/systemd/system/bastion-timesync.service" > /etc/systemd/system/bastion-timesync.service
put "$SHARED/usr/lib/systemd/system/bastion-timesync.timer" /etc/systemd/system/bastion-timesync.timer
systemctl disable --now chrony.service systemd-timesyncd.service 2>/dev/null || true
systemctl mask chrony.service systemd-timesyncd.service
systemctl daemon-reload
systemctl enable --now bastion-timesync.timer

# --- USBGuard ------------------------------------------------------------------------------------
# Devices present at boot are allowed (in a VM those are the virtual keyboard and tablet, so a
# changed VM config can't lock you out); anything plugged in later is blocked unless rules.conf
# allows it. Allow one with: sudo usbguard allow-device -p <id>
log "USBGuard"
conf=/etc/usbguard/usbguard-daemon.conf
sed -i -E 's/^PresentDevicePolicy=.*/PresentDevicePolicy=allow/; s/^ImplicitPolicyTarget=.*/ImplicitPolicyTarget=block/; s/^InsertedDevicePolicy=.*/InsertedDevicePolicy=apply-policy/' "$conf"
if [[ ! -s /etc/usbguard/rules.conf ]]; then
  usbguard generate-policy > /etc/usbguard/rules.conf
  chmod 0600 /etc/usbguard/rules.conf
fi
systemctl enable usbguard.service
systemctl restart usbguard.service

# --- AppArmor ------------------------------------------------------------------------------------
log "AppArmor (extra profiles, Claude Desktop's sandbox)"
systemctl enable apparmor.service
# Only if nothing else (the package, or Ubuntu's apparmor) already gives it a profile: two
# profiles attaching to the same path is an error.
if grep -rlsq --exclude=bastion-claude-desktop '/usr/lib/claude-desktop' /etc/apparmor.d; then
  rm -f /etc/apparmor.d/bastion-claude-desktop
else
  put "$LOCAL/etc/apparmor.d/bastion-claude-desktop" /etc/apparmor.d/bastion-claude-desktop
  apparmor_parser -r -W /etc/apparmor.d/bastion-claude-desktop
fi
systemctl reload apparmor.service

# --- Opus theme ----------------------------------------------------------------------------------
log "Opus theme"
cp -rT "$SHARED/usr/share/opus-theme" /usr/local/share/opus-theme
put "$SHARED/usr/share/backgrounds/opus/opus.svg" /usr/share/backgrounds/opus/opus.svg
put "$SHARED/usr/share/gtksourceview-5/styles/opus-dark.xml" /usr/share/gtksourceview-5/styles/opus-dark.xml
# adw-gtk3 is not packaged for Ubuntu; Yaru follows the dark colour scheme by itself.
sed '/^gtk-theme=/d' "$SHARED/etc/dconf/db/local.d/50-opus" | install -D -m 0644 /dev/stdin /etc/dconf/db/local.d/50-opus
install -d -m 0755 /etc/dconf/profile
[[ -s /etc/dconf/profile/user ]] || printf 'user-db:user\nsystem-db:local\n' > /etc/dconf/profile/user
grep -qx 'system-db:local' /etc/dconf/profile/user || echo 'system-db:local' >> /etc/dconf/profile/user
dconf update
# Per-user files: in /etc/skel for new users, and for the user running sudo if they have none.
theme_user() {  # theme_user <home> [user]: copies only what the user does not have yet
  local f run=()
  [[ -n ${2:-} ]] && run=(runuser -u "$2" --)
  for f in "gtk4.css:.config/gtk-4.0/gtk.css" "gtk.css:.config/gtk-3.0/gtk.css" \
           "opus.palette:.local/share/org.gnome.Ptyxis/palettes/opus.palette"; do
    [[ -e $1/${f#*:} ]] || "${run[@]}" install -D -m 0644 "/usr/local/share/opus-theme/${f%%:*}" "$1/${f#*:}"
  done
}
theme_user /etc/skel
if [[ -n ${SUDO_USER:-} && $SUDO_USER != root ]]; then
  theme_user "$(getent passwd "$SUDO_USER" | cut -d: -f6)" "$SUDO_USER"
fi

log "Done. Reboot to boot with the kernel, its arguments and the module blocklist."

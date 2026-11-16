#!/bin/bash
# Amnesic boot, initramfs half: with bastion.amnesic on the kernel command line, the disk is
# mounted read-only under a RAM layer before ostree-prepare-root sees it, so everything the
# session writes (/etc, /var, homes) lands in RAM. The real system's half is
# /usr/lib/systemd/system-generators/bastion-amnesic-generator.

# Only when asked for (dracut.conf.d/90-bastion-amnesic.conf does).
check() { return 255; }

depends() { echo systemd; }

installkernel() {
    # Built in on bastion's own kernels; modules on secureblue's. Missing ones are skipped.
    hostonly='' instmods overlay btrfs ext4 xfs
}

install() {
    inst_script "$moddir/bastion-amnesic-initrd-generator" \
        "$systemdutildir/system-generators/bastion-amnesic-initrd-generator"
    inst_script "$moddir/bastion-amnesic-root" /usr/libexec/bastion-amnesic-root
    inst_multiple blkid blockdev mount mountpoint mkdir chmod readlink basename cut systemd-escape
}

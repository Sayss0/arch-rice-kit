#!/usr/bin/env bash
# VM test phase 2b: my fake old-PC GUID had a trailing newline (test bug, sbctl
# writes it without one) -> fix it, enroll the restored keys + Microsoft's.
exec > >(tee /dev/ttyS0 /root/phase2b.log) 2>&1
set -uo pipefail
SRV=http://10.0.2.2:8080
trap 'curl -s -T /root/phase2b.log $SRV/phase2b.log >/dev/null; sync; systemctl poweroff' EXIT
mount -o subvol=@ /dev/vda2 /mnt && mount -o subvol=@home /dev/vda2 /mnt/home && mount /dev/vda1 /mnt/boot/efi
echo "shell.json numeric owner: $(stat -c %u:%g /mnt/home/sayss/.config/caelestia/shell.json)"
printf '%s' "$(tr -d '[:space:]' < /mnt/var/lib/sbctl/GUID)" > /mnt/var/lib/sbctl/GUID
arch-chroot /mnt sbctl enroll-keys --microsoft --yes-this-might-brick-my-machine
echo "--- after enrolling:"; arch-chroot /mnt sbctl status
umount -R /mnt
echo "=== PHASE2B DONE ==="

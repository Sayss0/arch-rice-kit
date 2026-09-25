#!/usr/bin/env bash
# VM test phase 2c: apply the NEW default-kernel pin block exactly as chroot-setup.sh
# has it, regenerate grub.cfg, and show which kernel the top entry boots.
exec > >(tee /dev/ttyS0 /root/phase2c.log) 2>&1
set -uo pipefail
SRV=http://10.0.2.2:8080
trap 'curl -s -T /root/phase2c.log $SRV/phase2c.log >/dev/null; sync; systemctl poweroff' EXIT
mount -o subvol=@ /dev/vda2 /mnt && mount -o subvol=@home /dev/vda2 /mnt/home && mount /dev/vda1 /mnt/boot/efi
curl -fsS $SRV/grubtop-step.sh -o /mnt/root/grubtop-step.sh
arch-chroot /mnt bash /root/grubtop-step.sh && rm -f /mnt/root/grubtop-step.sh
arch-chroot /mnt grub-mkconfig -o /boot/grub/grub.cfg 2>&1 | tail -4
echo "--- top-level entries:"; grep -E "^(menuentry|submenu) " /mnt/boot/grub/grub.cfg | cut -c1-90
K=$(grep -m1 -P '^\s+linux\s' /mnt/boot/grub/grub.cfg | awk '{print $2}')
[[ $K == */vmlinuz-linux ]] && echo "PASS  default entry boots $K" || echo "FAIL  default entry boots $K"
grep -q 'Windows 11' /mnt/boot/grub/grub.cfg && echo "PASS  Windows 11 entry present" || echo "FAIL  no Windows 11 entry"
umount -R /mnt
echo "=== PHASE2C DONE ==="

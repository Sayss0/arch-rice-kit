#!/usr/bin/env bash
# VM test phase 2 (runs in the live ISO after the install test):
#  - enrolls the RESTORED sbctl keys (+ Microsoft's) into the VM firmware, the way
#    sayss's desktop has them, so the next boot runs with Secure Boot ENFORCED
#  - TEST IMAGE ONLY: kernel output + a boot report on the serial port
exec > >(tee /dev/ttyS0 /root/phase2.log) 2>&1
set -uo pipefail
SRV=http://10.0.2.2:8080
trap 'curl -s -T /root/phase2.log $SRV/phase2.log >/dev/null; sync; systemctl poweroff' EXIT
mount -o subvol=@ /dev/vda2 /mnt && mount -o subvol=@home /dev/vda2 /mnt/home && mount /dev/vda1 /mnt/boot/efi

# re-test the FIXED shell.json step (runs as root, reads the root-only old-PC backup)
curl -fsS $SRV/shelljson-step.sh -o /mnt/root/shelljson-step.sh
arch-chroot /mnt bash /root/shelljson-step.sh
W=$(arch-chroot /mnt python3 -c 'import json;print(json.load(open("/home/sayss/.config/caelestia/shell.json"))["services"]["weatherLocation"])')
O=$(stat -c %U /mnt/home/sayss/.config/caelestia/shell.json)
if [[ $W == 41.0,29.0 && $O == sayss ]]; then echo "PASS  fixed shell.json step (weather=$W owner=$O)"
else echo "FAIL  fixed shell.json step (weather=$W owner=$O)"; fi
rm -f /mnt/root/shelljson-step.sh

echo "--- before enrolling:"; arch-chroot /mnt sbctl status
arch-chroot /mnt sbctl enroll-keys --microsoft --yes-this-might-brick-my-machine
echo "--- after enrolling:"; arch-chroot /mnt sbctl status
arch-chroot /mnt sbctl verify

# test-only: serial console + a one-shot boot report
sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT="\(.*\)"/GRUB_CMDLINE_LINUX_DEFAULT="\1 console=tty0 console=ttyS0,115200"/' /mnt/etc/default/grub
arch-chroot /mnt grub-mkconfig -o /boot/grub/grub.cfg >/dev/null 2>&1
cat > /mnt/usr/local/bin/rice-boot-report <<'EOF'
#!/bin/bash
{
  echo "=== BOOT REPORT $(date -Is) ==="
  echo "kernel: $(uname -r)"
  echo "SecureBoot efivar byte: $(od -An -t u1 /sys/firmware/efi/efivars/SecureBoot-8be4df61-93ca-11d2-aa0d-00e098032b8c 2>/dev/null | awk '{print $NF}')"
  sbctl status 2>&1
  echo "system state: $(systemctl is-system-running)"
  echo "--- failed units:"; systemctl --failed --no-legend --plain
  for s in sddm NetworkManager dnscrypt-proxy zapret bluetooth; do echo "$s: $(systemctl is-active $s)"; done
  echo "=== END BOOT REPORT ==="
} > /dev/ttyS0 2>&1
EOF
chmod 755 /mnt/usr/local/bin/rice-boot-report
cat > /mnt/etc/systemd/system/rice-boot-report.service <<'EOF'
[Unit]
Description=VM test boot report
After=graphical.target
[Service]
Type=oneshot
ExecStartPre=/usr/bin/sleep 20
ExecStart=/usr/local/bin/rice-boot-report
[Install]
WantedBy=graphical.target
EOF
arch-chroot /mnt systemctl enable rice-boot-report.service
umount -R /mnt
echo "=== PHASE2 PREP DONE ==="

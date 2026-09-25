#!/usr/bin/env bash
# VM test phase R: installer RE-RUN safety (exact code extracted from install.sh / oldlinux-backup.sh)
exec > >(tee /dev/ttyS0 /root/phaseR.log) 2>&1
set -uo pipefail
SRV=http://10.0.2.2:8080
trap 'curl -s -T /root/phaseR.log $SRV/phaseR.log >/dev/null; sync; systemctl poweroff' EXIT
USERNAME=sayss
curl -fsS $SRV/probe_arch.fn -o /root/probe_arch.fn && source /root/probe_arch.fn
curl -fsS $SRV/oldlinux-backup.sh -o /root/oldlinux-backup.sh
# 1) an interrupted run: partition already formatted by the installer, nothing installed yet
mkfs.btrfs -f -q -L ArchLinux /dev/vdb && mount /dev/vdb /mnt && btrfs subvolume create /mnt/@ >/dev/null && btrfs subvolume create /mnt/@home >/dev/null && umount /mnt
probe_arch /dev/vdb
[[ $PROBE_DESC == unfinished* && $PROBE_ROOT == /@ ]] && echo "PASS  unfinished run recognised ($PROBE_DESC)" || echo "FAIL  unfinished run: desc='$PROBE_DESC' root='$PROBE_ROOT'"
# 2) a finished rice install is still an Arch install
probe_arch /dev/vda2
[[ $PROBE_DESC == "old Arch Linux install (with user sayss)" && $PROBE_ROOT == /@ && $PROBE_HOME == /@home/sayss ]] && echo "PASS  finished install recognised" || echo "FAIL  finished install: '$PROBE_DESC' '$PROBE_ROOT' '$PROBE_HOME'"
# 3) re-running over it carries the ORIGINAL old-PC backup forward
rm -rf /tmp/ob; mkdir -p /tmp/ob
bash /root/oldlinux-backup.sh /dev/vda2 /@ /@home/sayss /tmp/ob /nonexistent
tar -tf /tmp/ob/old-etc.tar | grep -q 'etc/mkinitcpio.conf' && tar -xOf /tmp/ob/old-etc.tar etc/mkinitcpio.conf | grep -q 'nvidia_drm' \
  && [[ -f /tmp/ob/sbctl/var_lib_sbctl/keys/db/db.pem ]] \
  && echo "PASS  original backup carried forward (old mkinitcpio + SB keys)" || echo "FAIL  carry-forward"
findmnt /tmp/oldlinux-mnt >/dev/null && echo "FAIL  backup left the old partition mounted" || echo "PASS  old partition unmounted again"
echo "=== PHASER DONE ==="

#!/usr/bin/env bash
# VM test driver — runs automatically in the Arch live ISO (script= boot param).
# 1) builds a disk that looks like the main PC: shared ESP (+ fake Windows boot
#    manager), an OLD Arch btrfs (with sbctl keys, nvidia mkinitcpio, desktop
#    hypr files behind the ~/.config/hypr symlink), an MSR and a Windows NTFS
# 2) fingerprints Windows + the ESP's Microsoft files
# 3) runs the real install.sh (non-interactive knobs)
# 4) verifies the result, uploads logs to the host, powers off
exec > >(tee /dev/ttyS0 /root/driver.log) 2>&1
set -uo pipefail
SRV=http://10.0.2.2:8080
DISK=/dev/vda
put() { curl -s -T "$1" "$SRV/${2:-$(basename "$1")}" >/dev/null || true; }
finish() { echo "=== DRIVER END $(date -Is) ==="; put /root/driver.log; put /root/rice-install.log; sync; sleep 2; systemctl poweroff; }
trap finish EXIT
echo "=== DRIVER START $(date -Is) ==="
systemctl is-system-running --wait >/dev/null 2>&1 || true

# ------------------------------------------------------ fake desktop disk --
if ! blkid ${DISK}3 >/dev/null 2>&1; then
  echo "--- building fake main-PC disk"
  sgdisk --zap-all $DISK >/dev/null
  sgdisk -n1:0:+1G  -t1:ef00 -c1:"EFI system partition" \
         -n2:0:+60G -t2:8300 -c2:"" \
         -n3:0:+16M -t3:0c01 -c3:"Microsoft reserved partition" \
         -n4:0:+6G  -t4:0700 -c4:"Basic data partition" $DISK >/dev/null
  partprobe $DISK; udevadm settle
  mkfs.fat -F32 -n EFI ${DISK}1 >/dev/null
  mkntfs -Q -L Windows ${DISK}4 >/dev/null
  mkdir -p /tmp/w && mount -t ntfs-3g ${DISK}4 /tmp/w && mkdir -p /tmp/w/Windows/System32 \
    && head -c 5M /dev/urandom > /tmp/w/Windows/System32/ntoskrnl.exe && echo "League" > /tmp/w/games.txt; umount /tmp/w
  mkdir -p /tmp/e && mount ${DISK}1 /tmp/e
  mkdir -p /tmp/e/EFI/Microsoft/Boot /tmp/e/EFI/BOOT /tmp/e/grub
  head -c 1500K /dev/urandom > /tmp/e/EFI/Microsoft/Boot/bootmgfw.efi
  head -c 800K  /dev/urandom > /tmp/e/EFI/Microsoft/Boot/BCD
  head -c 900K  /dev/urandom > /tmp/e/EFI/BOOT/BOOTX64.EFI          # the OLD arch grub (fallback path)
  head -c 12M   /dev/urandom > /tmp/e/vmlinuz-linux-lts             # old kernel living on the ESP
  echo "old grub.cfg" > /tmp/e/grub/grub.cfg
  umount /tmp/e
  mkfs.btrfs -f -q ${DISK}2
  mkdir -p /tmp/o && mount ${DISK}2 /tmp/o
  btrfs subvolume create /tmp/o/@ >/dev/null; btrfs subvolume create /tmp/o/@home >/dev/null
  R=/tmp/o/@; Hm=/tmp/o/@home/sayss
  mkdir -p $R/etc $R/var/lib/sbctl/keys/{PK,KEK,db} $R/opt/zapret/ipset
  touch $R/etc/arch-release
  printf 'MODULES=(nvidia nvidia_modeset nvidia_uvm nvidia_drm)\nHOOKS=(base udev autodetect)\n' > $R/etc/mkinitcpio.conf
  echo 'NFQWS_ENABLE=1  # OLD-DESKTOP-ZAPRET' > $R/opt/zapret/config
  for k in PK KEK db; do
    openssl req -new -x509 -newkey rsa:2048 -nodes -sha256 -days 3650 -subj "/CN=Test $k/" \
      -keyout $R/var/lib/sbctl/keys/$k/$k.key -out $R/var/lib/sbctl/keys/$k/$k.pem 2>/dev/null
  done
  cat /proc/sys/kernel/random/uuid > $R/var/lib/sbctl/GUID
  mkdir -p $Hm/.rices/hypr-caelestia $Hm/.config/caelestia $Hm/.config/someapp $Hm/.config/matugen/templates/sddm
  ln -s /home/sayss/.rices/hypr-caelestia $Hm/.config/hypr
  echo 'monitor=DP-1,1920x1080@165.0,0x0,1.0,bitdepth,10  # OLD-DESKTOP-MONITOR' > $Hm/.rices/hypr-caelestia/monitors.conf
  curl -s $SRV/desktop-hypr-user.lua -o $Hm/.config/caelestia/hypr-user.lua
  echo '-- OLD-DESKTOP-HYPRUSER' >> $Hm/.config/caelestia/hypr-user.lua
  echo '{"services": {"weatherLocation": "41.0,29.0"}}' > $Hm/.config/caelestia/shell.json
  echo 'HideVirtualKeyboard="false" # OLD-DESKTOP-SDDM' > $Hm/.config/matugen/templates/sddm/theme.conf
  echo "plan" > $Hm/dual-boot-league-plan.md
  echo "keep me" > $Hm/.config/someapp/settings.ini
  head -c 80M /dev/urandom > $Hm/.config/someapp/huge.bin              # > 50 MB: must be skipped
  chown -R 1000:1000 $Hm
  umount /tmp/o
  echo "--- fake disk ready"; lsblk -o NAME,SIZE,FSTYPE,PARTTYPENAME,LABEL $DISK
fi

sha_win() { sha256sum ${DISK}4 | cut -c1-16; }
sha_ms()  { mkdir -p /tmp/e2; mount -o ro ${DISK}1 /tmp/e2; (cd /tmp/e2 && sha256sum EFI/Microsoft/Boot/* vmlinuz-linux-lts grub/grub.cfg | sha256sum | cut -c1-16); umount /tmp/e2; }
WIN_BEFORE=$(sha_win); MS_BEFORE=$(sha_ms); MSR_BEFORE=$(sha256sum ${DISK}3 | cut -c1-16)
echo "fingerprints before: windows=$WIN_BEFORE esp-ms=$MS_BEFORE msr=$MSR_BEFORE"

# ------------------------------------------------------------ the install --
curl -fsS $SRV/install.sh -o /root/install.sh
T0=$(date +%s)
RICE_KIT_URL=$SRV RICE_TARGET=${DISK}2 RICE_PASSWORD=test123 RICE_ASSUME_YES=1 \
  RICE_HOSTNAME=Sayss RICE_FORCE_NVIDIA=1 bash /root/install.sh
RC=$?
echo "=== install.sh exit=$RC after $(( ($(date +%s)-T0)/60 )) min ==="

# ---------------------------------------------------------------- verify --
PASS=0; FAIL=0
chk() { if eval "$2" >/dev/null 2>&1; then echo "PASS  $1"; PASS=$((PASS+1)); else echo "FAIL  $1"; FAIL=$((FAIL+1)); fi; }
chk "Windows NTFS partition unchanged"      '[[ $(sha_win) == "$WIN_BEFORE" ]]'
chk "MSR partition unchanged"               '[[ $(sha256sum ${DISK}3 | cut -c1-16) == "$MSR_BEFORE" ]]'
chk "ESP: Microsoft files + old files kept" '[[ $(sha_ms) == "$MS_BEFORE" ]]'
mount -o subvol=@ ${DISK}2 /mnt && mount -o subvol=@home ${DISK}2 /mnt/home && mount ${DISK}1 /mnt/boot/efi
H=/mnt/home/sayss
chk "ESP: new GRUB + fallback + backup"     '[[ -f /mnt/boot/efi/EFI/GRUB/grubx64.efi && -f /mnt/boot/efi/EFI/BOOT/BOOTX64.EFI && -n $(ls /mnt/boot/efi/EFI/BOOT/BOOTX64.EFI.before-rice-*) ]]'
chk "hostname Sayss"                         'grep -qx Sayss /mnt/etc/hostname'
chk "user sayss uid 1000"                    'grep -q "^sayss:x:1000:" /mnt/etc/passwd'
chk "sudo NOPASSWD temp file removed"        '[[ ! -e /mnt/etc/sudoers.d/99-rice-install ]]'
chk "password file removed"                  '[[ ! -e /mnt/root/.rice-pw ]]'
chk "grub.cfg: Arch + Windows + theme"       'grep -q "menuentry .Arch Linux" /mnt/boot/grub/grub.cfg && grep -q "Windows 11" /mnt/boot/grub/grub.cfg && grep -q themes/greenhouse /mnt/boot/grub/grub.cfg'
chk "kernels: linux + linux-lts"             '[[ -f /mnt/boot/vmlinuz-linux && -f /mnt/boot/vmlinuz-linux-lts ]]'
chk "nvidia-open-dkms built for both"        'ls /mnt/usr/lib/modules/*/updates/dkms/nvidia.ko* 2>/dev/null | wc -l | grep -qE "^[2-9]"'
chk "initramfs MODULES from old PC"          'grep -q "^MODULES=(nvidia nvidia_modeset nvidia_uvm nvidia_drm)" /mnt/etc/mkinitcpio.conf'
chk "caelestia-shell 2.3.0 installed"        'arch-chroot /mnt pacman -Q caelestia-shell | grep -q " 2.3.0"'
chk "caelestia links libcava.so.1"           'objdump -p /mnt/usr/lib/qt6/qml/Caelestia/lib/libcaelestia-services.so | grep -q "NEEDED.*libcava.so.1"'
chk "quickshell (repo) installed"            'arch-chroot /mnt pacman -Q quickshell'
chk "caelestia-cli 1.1.0 (laptop version)"   'arch-chroot /mnt pacman -Q caelestia-cli | grep -q " 1.1.0"'
chk "AUR apps: paru, zen, spotify, informant" 'arch-chroot /mnt pacman -Q paru zen-browser-bin spotify informant'
chk "home rice: shell.json + quickshell tree" '[[ -f $H/.config/caelestia/shell.json && -f $H/.config/quickshell/caelestia/shell.qml ]]'
chk "wallpapers unpacked"                    '[[ $(ls $H/Pictures/wallpapers | wc -l) -gt 3 ]]'
chk "home owned by sayss"                    '[[ $(stat -c %u $H/.config/caelestia/shell.json) == 1000 ]]'
chk "override: monitors from old PC"         'grep -q OLD-DESKTOP-MONITOR $H/.rices/hypr-caelestia/monitors.conf'
chk "override: hypr-user.lua from old PC"    'grep -q OLD-DESKTOP-HYPRUSER $H/.config/caelestia/hypr-user.lua'
chk "override: sddm template from old PC"    'grep -q OLD-DESKTOP-SDDM $H/.config/matugen/templates/sddm/theme.conf'
chk "override: Tools.qml = desktop (no dGPU dot)" '! grep -q gpuStatus $H/.config/quickshell/caelestia/modules/bar/popouts/Tools.qml'
chk "shell.json: battery off + weather from old PC" 'python3 -c "import json;d=json.load(open(\"$H/.config/caelestia/shell.json\"));assert d[\"dashboard\"][\"performance\"][\"showBattery\"] is False and d[\"general\"][\"idle\"][\"timeouts\"]==[] and d[\"services\"][\"weatherLocation\"]==\"41.0,29.0\" and [e for e in d[\"bar\"][\"statusIcons\"] if e.get(\"id\")==\"battery\"][0][\"enabled\"] is False"'
chk "kb-turkish watcher off (tr-only)"       '[[ ! -e $H/.config/systemd/user/default.target.wants/kb-turkish.service ]]'
chk "no logins shipped (gh hosts / claude creds / ssh)" '[[ ! -e $H/.ssh && ! -e $H/.claude/.credentials.json ]]'
chk "old Linux backup kept (root-only)"      '[[ -f $H/old-linux-backup/old-etc.tar && $(stat -c %a $H/old-linux-backup) == 700 ]]'
chk "old backup has settings, skips >50MB"   'tar -tf $H/old-linux-backup/old-home.tar | grep -q someapp/settings.ini && ! tar -tf $H/old-linux-backup/old-home.tar | grep -q huge.bin'
chk "old notes kept (dual-boot plan)"        'tar -tf $H/old-linux-backup/old-home.tar | grep -q dual-boot-league-plan.md'
chk "Secure Boot keys restored"              '[[ -f /mnt/var/lib/sbctl/keys/db/db.pem ]]'
chk "GRUB + kernel signed with those keys"   'arch-chroot /mnt sbctl verify 2>&1 | grep -E "grubx64.efi|vmlinuz-linux" | grep -qv "not signed"'
chk "plymouth: greenhouse + shutdown wiring" 'grep -q Theme=greenhouse /mnt/etc/plymouth/plymouthd.conf && [[ -f /mnt/etc/systemd/system/plymouth-poweroff.service.d/greenhouse-hold.conf ]]'
chk "sddm theme + enabled"                   '[[ -d /mnt/usr/share/sddm/themes/simple_sddm_2 && -L /mnt/etc/systemd/system/display-manager.service ]]'
chk "services: NM, dnscrypt, zapret, bluetooth" 'for s in NetworkManager dnscrypt-proxy zapret bluetooth; do arch-chroot /mnt systemctl is-enabled $s | grep -q enabled || exit 1; done'
chk "laptop-only units NOT enabled"          '! arch-chroot /mnt systemctl is-enabled greenhouse-fb-plant nvidia-powerd 2>/dev/null | grep -q enabled'
chk "Windows fence NOT copied"               '[[ ! -e /mnt/etc/modprobe.d/99-fence-windows.conf && ! -e /mnt/etc/udev/rules.d/99-hide-windows.rules ]]'
chk "snapper root + home"                    '[[ -f /mnt/etc/snapper/configs/root && -f /mnt/etc/snapper/configs/home ]]'
chk "zram + dnscrypt resolv.conf"            'grep -q zstd /mnt/etc/systemd/zram-generator.conf && grep -q 127.0.0.1 /mnt/etc/resolv.conf'
chk "report written"                         '[[ -f $H/RICE-INSTALL-REPORT.txt ]]'
echo "--- report:"; cat $H/RICE-INSTALL-REPORT.txt 2>/dev/null
echo "--- efibootmgr:"; efibootmgr 2>/dev/null | head
echo "=== RESULT: $PASS passed, $FAIL failed ==="
cp /mnt/var/log/rice-install.log /root/rice-install.log 2>/dev/null
umount -R /mnt

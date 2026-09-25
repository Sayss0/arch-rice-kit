#!/usr/bin/env bash
# chroot-setup.sh — runs INSIDE the freshly installed system (arch-chroot),
# started by install.sh. Sets up the user, the rice, the AUR packages, GRUB,
# Secure Boot signing, snapshots and services.
#
# Critical steps (user, initramfs, boot loader) abort on failure.  Everything
# else is best-effort: failures are collected into ~/RICE-INSTALL-REPORT.txt
# so one broken AUR package can never leave the PC unbootable.
set -Eeuo pipefail
K=/var/tmp/rice-kit
C=$K/core
# shellcheck disable=SC1091
source "$K/answers.env"
U=$USERNAME
H=/home/$U
REPORT=()
step() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
ok()   { printf '\033[32m  ✓ %s\033[0m\n' "$*"; }
note() { REPORT+=("$*"); printf '\033[33m  ! %s\033[0m\n' "$*"; }
asuser() { sudo -u "$U" -H "$@"; }
NOPASS=/etc/sudoers.d/99-rice-install
cleanup() { rm -f "$NOPASS" /root/.rice-pw; }
trap cleanup EXIT
trap 'echo "chroot-setup failed at line $LINENO"' ERR

# --------------------------------------------------------------- basics --
step "Basics: language, time zone, name"
locale-gen >/dev/null
ln -sf /usr/share/zoneinfo/Europe/Istanbul /etc/localtime
hwclock --systohc 2>/dev/null || true
echo "$HOSTNAME_NEW" > /etc/hostname
ok "en_US.UTF-8, Europe/Istanbul, Turkish keyboard, name $HOSTNAME_NEW"

step "User $U"
getent group seat >/dev/null || groupadd -r seat
id "$U" >/dev/null 2>&1 || useradd -m -u 1000 -U -G wheel,input,render,video,seat -s /bin/bash "$U"
chpasswd < /root/.rice-pw
rm -f /root/.rice-pw
install -m440 /dev/stdin /etc/sudoers.d/10-wheel <<< '%wheel ALL=(ALL:ALL) ALL'
install -m440 /dev/stdin "$NOPASS" <<< "$U ALL=(ALL:ALL) NOPASSWD: ALL"   # removed at the end
visudo -cq || { echo "sudoers check failed"; exit 1; }
ok "user $U (uid $(id -u "$U")) with sudo"

if [[ -s $K/asdeps.txt ]]; then
  xargs -a "$K/asdeps.txt" pacman -D --asdeps >/dev/null 2>&1 || note "could not mark some packages as dependencies (harmless)"
fi

# ------------------------------------------------------------ home rice --
step "Rice: home folder (configs, scripts, themes, wallpapers)"
tar --zstd --numeric-owner -xpf "$K/home-rice.tar.zst" -C "$H"
tar --numeric-owner -xpf "$K/wallpapers.tar" -C "$H"
chown -R "$U:$U" "$H"
ok "home rice unpacked"

if [[ $PROFILE == desktop ]]; then
  step "This PC's own hardware settings (monitor, keyboard/mouse, widgets)"
  for f in .config/hypr/monitors.conf .config/hypr/monitors.lua .config/caelestia/hypr-user.lua \
           .config/quickshell/caelestia/modules/bar/popouts/Tools.qml \
           .config/matugen/templates/sddm/theme.conf; do
    src=$K/oldlinux/home-overrides/$f; from="this PC's old Linux"
    [[ -f $src ]] || { src=$C/overrides/desktop/$f; from="the brain's desktop export"; }
    if [[ -f $src ]]; then
      install -o "$U" -g "$U" -m644 -D "$src" "$H/$f"
      ok "$f  (from $from)"
    fi
  done
  # shell.json: keep the laptop's rice, set only the hardware keys to the desktop's values
  old=$K/oldlinux/home-overrides/.config/caelestia/shell.json
  [[ -f $old ]] || old=$C/overrides/desktop/shell.json.desktop-export
  asuser python3 - "$H/.config/caelestia/shell.json" "$old" <<'PY'
import json, sys
path, oldp = sys.argv[1], sys.argv[2]
d = json.load(open(path))
try:
    old = json.load(open(oldp))
except Exception:
    old = {}
for e in d.get("bar", {}).get("statusIcons", []):
    if isinstance(e, dict) and e.get("id") == "battery":
        e["enabled"] = False
d.setdefault("dashboard", {}).setdefault("performance", {})["showBattery"] = False
d.setdefault("general", {}).setdefault("idle", {})["timeouts"] = []
w = old.get("services", {}).get("weatherLocation")
if w:
    d.setdefault("services", {})["weatherLocation"] = w
json.dump(d, open(path, "w"), indent=4)
print("  shell.json: battery widgets off, battery-only idle rule removed")
PY
  # the us,tr keyboard watcher only makes sense with the laptop's two-layout setup
  if grep -qE 'kb_layout[[:space:]]*=[[:space:]]*"tr"' "$H/.config/caelestia/hypr-user.lua"; then
    rm -f "$H/.config/systemd/user/default.target.wants/kb-turkish.service"
    ok "Turkish-only keyboard: layout watcher switched off"
  fi
fi

# ------------------------------------------------------------ initramfs --
step "Boot image (initramfs) for this GPU"
MODS=
if (( HAS_NVIDIA )) && [[ -f $K/oldlinux/old-etc.tar ]]; then
  MODS=$(tar -xOf "$K/oldlinux/old-etc.tar" etc/mkinitcpio.conf 2>/dev/null \
         | sed -n 's/^MODULES=(\(.*nvidia.*\))/\1/p' | head -1 || true)
  [[ -n $MODS ]] && ok "using this PC's own proven MODULES=($MODS)"
fi
if [[ -z $MODS ]]; then
  if (( HAS_NVIDIA && HAS_INTEL )); then MODS="i915"               # hybrid laptop: panel on Intel
  elif (( HAS_NVIDIA )); then MODS="nvidia nvidia_modeset nvidia_uvm nvidia_drm"
  elif (( HAS_INTEL )); then MODS="i915"
  elif (( HAS_AMD )); then MODS="amdgpu"
  fi
fi
sed -i -e "s/^MODULES=.*/MODULES=($MODS)/" \
       -e 's/^HOOKS=.*/HOOKS=(base udev plymouth autodetect microcode modconf keyboard keymap consolefont block filesystems fsck grub-btrfs-overlayfs)/' \
       /etc/mkinitcpio.conf
grep -E '^(MODULES|HOOKS)=' /etc/mkinitcpio.conf
mkinitcpio -P
ok "initramfs built"

# ------------------------------------------------------------ AUR stack --
step "AUR apps (this laptop's exact versions)"
mkdir -p "$K/aur"
tar -xf "$K/aur-pkgs.tar" -C "$K/aur"
mapfile -t PKGFILES < <(find "$K/aur" -name '*.pkg.tar.zst' ! -name 'informant-*' | sort)
AUR_FAILED=()
if ! pacman -U --noconfirm --needed "${PKGFILES[@]}"; then
  note "installing the AUR apps in one go failed — retrying one by one"
  pending=("${PKGFILES[@]}")
  for _ in 1 2 3; do
    next=()
    for f in "${pending[@]}"; do pacman -U --noconfirm --needed "$f" >/dev/null 2>&1 || next+=("$f"); done
    (( ${#next[@]} == ${#pending[@]} )) && break
    pending=("${next[@]}")
    (( ${#pending[@]} )) || break
  done
  for f in "${pending[@]}"; do
    n=$(basename "$f"); n=${n%-*-*-*}; AUR_FAILED+=("$n")
  done
fi
ok "$(( ${#PKGFILES[@]} - ${#AUR_FAILED[@]} )) of ${#PKGFILES[@]} AUR apps installed from the kit"

step "Shell stack: libcava 1.0.0 + caelestia-shell 2.3.0 built for THIS system"
BUILD=/var/tmp/rice-build
rm -rf "$BUILD"; mkdir -p "$BUILD"; cp -a "$C/vendor/." "$BUILD/"; chown -R "$U:$U" "$BUILD"
SHELL_OK=1
for pkg in libcava caelestia-shell; do
  if asuser bash -c "cd '$BUILD/$pkg' && makepkg -sf --noconfirm --needed" >"$BUILD/$pkg.log" 2>&1; then
    pacman -U --noconfirm "$BUILD/$pkg"/"$pkg"-[0-9]*.pkg.tar.zst >/dev/null
    ok "$pkg built and installed"
  else
    SHELL_OK=0
    note "$pkg failed to build — see $BUILD/$pkg.log (the desktop would come up without its bar)"
    tail -20 "$BUILD/$pkg.log"
  fi
done
if (( SHELL_OK )); then
  objdump -p /usr/lib/qt6/qml/Caelestia/lib/libcaelestia-services.so 2>/dev/null | grep -q 'NEEDED.*libcava.so' \
    && ok "caelestia links $(objdump -p /usr/lib/qt6/qml/Caelestia/lib/libcaelestia-services.so | awk '/NEEDED.*libcava/{print $2}') (matches the installed libcava)"
fi

step "Rebuilding any app whose libraries moved on since the laptop built it"
REBUILD=("${AUR_FAILED[@]}")
while read -r _ name; do REBUILD+=("$name"); done < <(checkrebuild 2>/dev/null | awk '$1=="foreign"' || true)
mapfile -t REBUILD < <(printf '%s\n' "${REBUILD[@]}" | grep -vxE 'caelestia-shell|libcava|quickshell-git|informant|' | sort -u)
if (( ${#REBUILD[@]} )); then
  echo "  rebuilding from the AUR: ${REBUILD[*]}"
  for p in "${REBUILD[@]}"; do
    asuser paru -S --noconfirm --skipreview --rebuild "$p" >/dev/null 2>&1 \
      && ok "$p rebuilt" || note "$p could not be installed/rebuilt (run later:  paru -S $p)"
  done
else
  ok "nothing needs rebuilding"
fi

# ------------------------------------------------- plymouth shutdown art --
step "Boot/shutdown splash wiring"
W=$C/plymouth-wiring/desktop
for u in poweroff halt kexec reboot; do
  d=/etc/systemd/system/plymouth-$u.service.d
  install -d -m755 "$d"
  install -m644 "$W/after-user-session.conf" "$d/after-user-session.conf"
  install -m644 "$W/greenhouse-hold.conf" "$d/greenhouse-hold.conf"
  if [[ $u == reboot ]]; then install -m644 "$W/greenhouse-mode.reboot.conf" "$d/greenhouse-mode.conf"
  else install -m644 "$W/greenhouse-mode.shutdown.conf" "$d/greenhouse-mode.conf"; fi
done
ok "greenhouse splash on boot, reboot and shutdown"

# ------------------------------------------------------------------ GRUB --
step "Boot menu (GRUB) — Windows stays reachable"
if (( HAS_NVIDIA )); then CMDLINE="loglevel=3 quiet splash nvidia_drm.modeset=1 zswap.enabled=0"
else CMDLINE="loglevel=3 quiet splash zswap.enabled=0"; fi
sed -i "s|^GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT=\"$CMDLINE\"|" /etc/default/grub
if [[ -f /boot/efi/EFI/Microsoft/Boot/bootmgfw.efi ]]; then
  cat > /etc/grub.d/40_custom <<EOF
#!/bin/sh
exec tail -n +3 \$0
menuentry "Windows 11" --class windows {
    insmod part_gpt
    insmod fat
    insmod chain
    search --no-floppy --fs-uuid --set=root $ESP_UUID
    chainloader /EFI/Microsoft/Boot/bootmgfw.efi
}
EOF
  chmod 755 /etc/grub.d/40_custom
  ok "Windows 11 entry added (chainloads Windows' own boot manager)"
fi
# Every module GRUB needs is built INTO the loader and shim-lock is off: that is
# what lets it run with Secure Boot ON once it's signed (the desktop's proven fix).
WANTMODS="all_video boot btrfs cat chain configfile echo efifwsetup efinet ext2 fat font gettext gfxmenu
gfxterm gfxterm_background gzio halt help iso9660 jpeg keystatus loadenv loopback linux ls lsefi lsefimmap
lsefisystab memdisk minicmd normal ntfs part_gpt part_msdos password_pbkdf2 png probe reboot regexp search
search_fs_file search_fs_uuid search_label serial sleep smbios squash4 test tpm true video xfs zstd"
GMODS=
for m in $WANTMODS; do [[ -f /usr/lib/grub/x86_64-efi/$m.mod ]] && GMODS+="$m "; done
if [[ -f /boot/efi/EFI/BOOT/BOOTX64.EFI ]]; then
  cp /boot/efi/EFI/BOOT/BOOTX64.EFI "/boot/efi/EFI/BOOT/BOOTX64.EFI.before-rice-$(date +%Y%m%d)"
  ok "old fallback loader backed up as EFI/BOOT/BOOTX64.EFI.before-rice-$(date +%Y%m%d)"
fi
grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB \
             --modules="$GMODS" --disable-shim-lock
grub-install --target=x86_64-efi --efi-directory=/boot/efi --removable \
             --modules="$GMODS" --disable-shim-lock
/usr/local/sbin/greenhouse-grub-repatch || note "greenhouse GRUB check reported a warning (see log above)"
grub-mkconfig -o /boot/grub/grub.cfg
grep -q "menuentry 'Arch Linux'" /boot/grub/grub.cfg || { echo "grub.cfg has no Arch entry"; exit 1; }
ok "GRUB installed ($(grep -c '^menuentry' /boot/grub/grub.cfg) top-level entries)"

# ----------------------------------------------------------- Secure Boot --
step "Secure Boot keys"
SB_KEYS=
for s in "$K/oldlinux/sbctl/var_lib_sbctl" "$K/oldlinux/sbctl/usr_share_secureboot"; do
  [[ -d $s/keys ]] && { SB_KEYS=$s; break; }
done
if [[ -n $SB_KEYS ]]; then
  rm -rf /var/lib/sbctl && cp -a "$SB_KEYS" /var/lib/sbctl
  rm -f /var/lib/sbctl/files.json          # old file list pointed at the OLD install's paths
  for f in /boot/efi/EFI/GRUB/grubx64.efi /boot/efi/EFI/BOOT/BOOTX64.EFI /boot/vmlinuz-linux /boot/vmlinuz-linux-lts; do
    [[ -f $f ]] && { sbctl sign -s "$f" >/dev/null && ok "signed $f" || note "could not sign $f"; }
  done
  sbctl verify 2>&1 | sed 's/^/    /' || true
  note "Secure Boot: this PC's own keys were restored and the new boot files are signed — you can turn Secure Boot back ON in the BIOS (needed for League/Vanguard)."
else
  note "Secure Boot: no old keys were found. Keep Secure Boot OFF for now; to turn it on later follow the README section 'Secure Boot'."
fi

# ------------------------------------------------------------ snapshots --
step "Snapshots (snapper)"
mkdir -p /var/tmp/snapper-keep
mv /etc/snapper/configs/root /etc/snapper/configs/home /var/tmp/snapper-keep/ 2>/dev/null || true
sed -i 's/^SNAPPER_CONFIGS=.*/SNAPPER_CONFIGS=""/' /etc/conf.d/snapper
if snapper --no-dbus -c root create-config / && snapper --no-dbus -c home create-config /home; then
  cp /var/tmp/snapper-keep/root /var/tmp/snapper-keep/home /etc/snapper/configs/ 2>/dev/null || true
  sed -i 's/^SNAPPER_CONFIGS=.*/SNAPPER_CONFIGS="root home"/' /etc/conf.d/snapper
  ok "snapper: root + home (same limits as the laptop)"
else
  note "snapper setup failed (snapshots off; everything else works)"
fi

# ------------------------------------------------------------- services --
step "Services"
while read -r s; do
  case $s in
    greenhouse-*|mkinitcpio-generate-shutdown-ramfs*) continue ;;              # laptop-only boot hacks
    nvidia-powerd.service) [[ $PROFILE == laptop ]] && (( HAS_NVIDIA )) || continue ;;
    nvidia-*) (( HAS_NVIDIA )) || continue ;;
  esac
  systemctl enable "$s" >/dev/null 2>&1 || note "could not enable $s"
done < "$C/lists/services-system.txt"
systemctl enable sddm NetworkManager >/dev/null 2>&1
ok "$(systemctl list-unit-files --state=enabled --no-legend | wc -l) units enabled"

# ------------------------------------------------------- GitHub + brain --
step "GitHub login + Claude's brain"
if [[ -f $K/gh-hosts.yml ]]; then
  install -o "$U" -g "$U" -m600 -D "$K/gh-hosts.yml" "$H/.config/gh/hosts.yml"
  MEMDIR=$H/.claude/projects/-home-sayss/memory
  if [[ ! -d $MEMDIR/.git ]]; then
    asuser mkdir -p "$(dirname "$MEMDIR")"
    asuser git clone -q https://github.com/Sayss0/claude-brain.git "$MEMDIR" \
      && ok "brain cloned into ~/.claude/projects/-home-sayss/memory" \
      || note "brain clone failed — later run: git clone https://github.com/Sayss0/claude-brain.git ~/.claude/projects/-home-sayss/memory"
  fi
else
  note "GitHub isn't logged in on the new system — run  gh auth login  once, then clone the brain (README)"
fi
if asuser bash -c 'curl -fsSL https://claude.ai/install.sh | bash' >/var/tmp/claude-install.log 2>&1; then
  ok "Claude Code installed (run  claude  and log in)"
else
  note "Claude Code install failed — later run:  curl -fsSL https://claude.ai/install.sh | bash"
fi

# -------------------------------------------------------------- flatpak --
step "Flatpak apps"
if [[ -s $C/lists/flatpaks.txt ]]; then
  flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo >/dev/null 2>&1 || true
  while read -r app; do
    [[ -n $app ]] || continue
    flatpak install -y --noninteractive flathub "$app" >/dev/null 2>&1 && ok "$app" || note "flatpak $app failed (later: flatpak install flathub $app)"
  done < "$C/lists/flatpaks.txt"
fi

# ------------------------------------------------------ informant (last) --
step "Arch news gate (informant) — installed last on purpose"
inf=$(find "$K/aur" -name 'informant-*.pkg.tar.zst' | head -1)
if [[ -n $inf ]] && pacman -U --noconfirm --needed "$inf" >/dev/null 2>&1; then
  informant read --all >/dev/null 2>&1 || true
  ok "informant installed, current news marked read"
fi

# --------------------------------------------------------------- finish --
step "Cleaning up"
rm -f "$NOPASS"
BK=$H/old-linux-backup
if [[ -d $K/oldlinux ]]; then
  mkdir -p "$BK"; cp -a "$K/oldlinux/." "$BK/"; chown -R root:root "$BK"; chmod 700 "$BK"
  ok "old Linux backup kept in $BK (root-only; sudo ls it)"
fi
cp -a "$C" "$H/.local/share/rice-kit-core" 2>/dev/null && chown -R "$U:$U" "$H/.local/share/rice-kit-core" || true
rm -rf "$K/aur" "$K"/*.tar "$K"/*.tar.zst "$BUILD"/*/src "$BUILD"/*/pkg "$K/oldlinux" "$K/gh-hosts.yml"

{
  echo "Rice install report — $(date -Is) — kit $KIT_TAG"
  echo
  if (( ${#REPORT[@]} )); then printf ' • %s\n' "${REPORT[@]}"; else echo " • everything went fine"; fi
  echo
  echo "Full log: /var/log/rice-install.log"
} > "$H/RICE-INSTALL-REPORT.txt"
chown "$U:$U" "$H/RICE-INSTALL-REPORT.txt"
echo; cat "$H/RICE-INSTALL-REPORT.txt"

#!/usr/bin/env bash
# build-kit.sh — build the arch-rice-kit release assets from THIS laptop (no root).
#
# Output (in ~/arch-rice-kit/out):
#   install.sh           the live-USB installer (downloaded first, run as root)
#   kit-core.tar.zst     lists, chroot stage, system rice, vendored shell builds, overrides
#   aur-pkgs.tar         this laptop's AUR packages as exact package files
#   home-rice.tar.zst    ~ rice: configs, scripts, themes, fonts — NO logins/keys/caches
#   wallpapers.tar       ~/Pictures/wallpapers
#   SHA256SUMS
set -Eeuo pipefail

KIT=/home/sayss/arch-rice-kit
SRC=$KIT/src
B=$KIT/build
OUT=$KIT/out
CORE=$B/core
MEM=/home/sayss/.claude/projects/-home-sayss/memory
TAG=${TAG:?set TAG=rice-YYYY-MM-DD}

say() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }

rm -rf "$CORE" "$OUT"
mkdir -p "$CORE"/{lists,aur,vendor,overrides/desktop,plymouth-wiring} "$OUT"

# ----------------------------------------------------------------- lists --
say "package + service lists"
PACDB=$B/pacdb                       # fresh sync db (fakeroot pacman -Sy --disable-sandbox)
pacman -Sl --dbpath "$PACDB" | awk '{print $2}' | sort -u > "$B/repo-available.txt"
[ "$(wc -l < "$B/repo-available.txt")" -gt 10000 ] || { echo "repo db looks empty"; exit 1; }
{
  pacman -Qqne | sed 's/$/ explicit/'
  pacman -Qqnd | sed 's/$/ dep/'
} | sort -u | while read -r name why; do
  if grep -qxF "$name" "$B/repo-available.txt"; then echo "$name $why"; else echo "DROPPED (not in repos today): $name" >&2; fi
done > "$CORE/lists/pkg-native.txt"
pacman -Qm > "$CORE/lists/pkg-foreign-versions.txt"
pacman -Qqme > "$CORE/lists/pkg-foreign-explicit.txt"
systemctl list-unit-files --state=enabled --no-legend --no-pager | awk '{print $1}' \
  | grep -vE '^(getty@|autovt@|display-manager|dbus-org)' > "$CORE/lists/services-system.txt"
flatpak list --app --columns=application 2>/dev/null > "$CORE/lists/flatpaks.txt" || true
cp "$B/aur-inventory.json" "$CORE/lists/" 2>/dev/null || true
{
  echo "source_host=$(cat /etc/hostname)"
  echo "built=$(date -Is)"
  echo "tag=$TAG"
  echo "kernel=$(uname -r)"
  for p in caelestia-shell caelestia-cli quickshell-git libcava hyprland qt6-base python pacman; do
    echo "pkg.$p=$(pacman -Q "$p" 2>/dev/null | cut -d' ' -f2)"
  done
  echo "scheme=$(python3 -c 'import json;d=json.load(open("/home/sayss/.local/state/caelestia/scheme.json"));print(d.get("name"),d.get("flavour"),d.get("mode"))' 2>/dev/null)"
} > "$CORE/lists/meta.txt"
wc -l "$CORE"/lists/*.txt

# ------------------------------------------------------------- AUR pkgs --
say "AUR packages -> exact package files"
# Built fresh on the target instead: caelestia-shell (pinned 2.3.0, vendored below),
# libcava (vendored 1.0.0), quickshell-git (target uses extra/quickshell), debug pkgs.
SKIP_AUR='^(caelestia-shell|caelestia-shell-debug|libcava|quickshell-git)$'
: > "$CORE/lists/aur-shipped.txt"
for p in $(pacman -Qqm); do
  [[ $p =~ $SKIP_AUR ]] && continue
  v=$(pacman -Q "$p" | cut -d' ' -f2)
  orig=$(find ~/.cache/yay ~/.cache/paru ~/.cache/manual-builds -maxdepth 3 \
           \( -name "$p-$v-x86_64.pkg.tar.zst" -o -name "$p-$v-any.pkg.tar.zst" \) 2>/dev/null | head -1 || true)
  if [ -n "$orig" ]; then
    cp "$orig" "$CORE/aur/" ; echo "$p $v cached" >> "$CORE/lists/aur-shipped.txt"
  elif python3 "$SRC/mkpkg-from-installed.py" "$p" "$CORE/aur" >/dev/null; then
    echo "$p $v rebuilt-from-installed" >> "$CORE/lists/aur-shipped.txt"
  else
    echo "$p $v FAILED (target builds it from AUR)" >> "$CORE/lists/aur-shipped.txt"
  fi
done
grep -c . "$CORE/lists/aur-shipped.txt"; grep FAILED "$CORE/lists/aur-shipped.txt" || true
# the package files go in their own asset (big); core keeps only the list
mv "$CORE/aur" "$B/aur-out"; mkdir -p "$CORE/aur"
tar -C "$B/aur-out" -cf "$OUT/aur-pkgs.tar" .
rm -rf "$B/aur-out"

# ---------------------------------------------------------------- vendor --
say "vendored builds: caelestia-shell 2.3.0 + libcava 1.0.0"
mkdir -p "$CORE/vendor/caelestia-shell" "$CORE/vendor/libcava"
sed 's/'"'"'quickshell-git'"'"'/'"'"'quickshell'"'"'/' ~/.cache/manual-builds/caelestia-shell/PKGBUILD \
  > "$CORE/vendor/caelestia-shell/PKGBUILD"
grep -q "'quickshell' " "$CORE/vendor/caelestia-shell/PKGBUILD" || { echo "depends patch failed"; exit 1; }
cp ~/.cache/manual-builds/caelestia-shell/caelestia-shell-v2.3.0.tar.gz "$CORE/vendor/caelestia-shell/"
( cd "$CORE/vendor/caelestia-shell" && makepkg --verifysource >/dev/null )
cp "$B/vendor/libcava/PKGBUILD" "$B/vendor/libcava/libcava-1.0.0.tar.gz" "$CORE/vendor/libcava/"
( cd "$CORE/vendor/libcava" && makepkg --verifysource >/dev/null )
rm -rf "$CORE"/vendor/*/src

# ----------------------------------------------------------- system rice --
say "system rice files"
# Generic, machine-neutral system files. Laptop-only boot-seam hacks (weston
# greeter, fb plants, shutdown-hold, shutdown-ramfs mask, retain-splash), the
# Windows fence (keyed to the LAPTOP's NTFS UUIDs), fan curves and SSH host keys
# are deliberately NOT here.
SYS=(
  /etc/NetworkManager/conf.d/dns.conf
  /etc/X11/xorg.conf.d/00-keyboard.conf
  /etc/conf.d/snapper
  /etc/default/grub
  /etc/default/grub-btrfs/config
  /etc/dnscrypt-proxy
  /etc/grub.d/09_greenhouse_background
  /etc/hosts
  /etc/locale.conf
  /etc/locale.gen
  /etc/nftables.conf
  /etc/pacman.conf
  /etc/pacman.d/hooks/95-grub.hook
  /etc/pacman.d/hooks/greenhouse-grub.hook
  /etc/pipewire/pipewire.conf.d/10-audiorelay.conf
  /etc/plymouth/plymouthd.conf
  /etc/resolv.conf
  /etc/sddm.conf
  /etc/security/faillock.conf
  /etc/snapper/configs/root
  /etc/snapper/configs/home
  /etc/systemd/system/dnscrypt-proxy.service.d/restart.conf
  /etc/systemd/system/grub-btrfsd.service.d/override.conf
  /etc/systemd/system/user@.service.d/oomd.conf
  /etc/systemd/zram-generator.conf
  /etc/vconsole.conf
  /etc/xdg/reflector/reflector.conf
  /etc/modprobe.d/nvidia.conf
  /etc/modprobe.d/blacklist-nouveau.conf
  /opt/zapret/config
  /opt/zapret/ipset/zapret-hosts-user.txt
  /usr/local/sbin/greenhouse-grub-repatch
  /usr/local/sbin/greenhouse-plymouth-mode
  /usr/share/plymouth/themes/greenhouse
  /usr/share/sddm/themes/simple_sddm_2
  /boot/grub/themes/greenhouse
)
for f in "${SYS[@]}"; do [ -e "$f" ] || { echo "missing system file: $f"; exit 1; }; done
# numeric owners kept: the sddm theme dir is uid 1000 (sayss) on purpose — the
# theme-extras script rewrites theme.conf in it without root.
tar --numeric-owner -C / --exclude='*.bak*' --exclude='*.pink-backup' \
    -cf "$CORE/system-rice.tar" "${SYS[@]#/}"
tar -tf "$CORE/system-rice.tar" | wc -l

# ------------------------------------------------ desktop machine-locals --
say "desktop overrides (from the brain's desktop export) + plymouth wiring"
EXP=$MEM/state/look-export-Sayss/files
for f in .config/hypr/monitors.conf .config/hypr/monitors.lua .config/caelestia/hypr-user.lua \
         .config/quickshell/caelestia/modules/bar/popouts/Tools.qml \
         .config/matugen/templates/sddm/theme.conf; do
  install -Dm644 "$EXP/$f" "$CORE/overrides/desktop/$f"
done
cp "$EXP/.config/caelestia/shell.json" "$CORE/overrides/desktop/shell.json.desktop-export"
cp -r "$MEM/transfer-to-laptop/2026-08-10-shutdown-splash/drop-ins" "$CORE/plymouth-wiring/desktop"
find "$CORE/overrides" "$CORE/plymouth-wiring" -type f | sed "s|$CORE/||"

# --------------------------------------------------------------- scripts --
say "scripts"
install -m755 "$SRC/chroot-setup.sh" "$CORE/chroot-setup.sh"
install -m755 "$SRC/oldlinux-backup.sh" "$CORE/oldlinux-backup.sh"
install -m644 "$SRC/homelist.py" "$CORE/homelist.py"
install -m755 "$SRC/install.sh" "$OUT/install.sh"
sed -i "s/^KIT_TAG=.*/KIT_TAG=$TAG/" "$OUT/install.sh"
bash -n "$OUT/install.sh" "$CORE/chroot-setup.sh" "$CORE/oldlinux-backup.sh"

# ------------------------------------------------------------- home rice --
say "home rice (no logins / keys / caches)"
cd /home/sayss
python3 "$SRC/homelist.py" > "$B/home.list" 2> "$B/home.skipped"; cat "$B/home.skipped"
tar --null --no-recursion --numeric-owner -T "$B/home.list" -cf - 2>/dev/null \
  | zstd -q -T0 -12 -o "$OUT/home-rice.tar.zst"
python3 "$SRC/homelist.py" --wallpapers > "$B/wall.list"
tar --null --no-recursion --numeric-owner -T "$B/wall.list" -cf "$OUT/wallpapers.tar" 2>/dev/null

# ------------------------------------------------------------------ core --
say "kit-core"
tar -C "$B" --numeric-owner -cf - core | zstd -q -T0 -12 -o "$OUT/kit-core.tar.zst"

# ------------------------------------------ split anything near GitHub's 2 GiB cap --
cd "$OUT"
for f in *; do
  if [ "$(stat -c %s "$f")" -gt $((1900*1024*1024)) ]; then
    split -b 1900M -d -a 2 "$f" "$f.part" && rm "$f"
  fi
done
sha256sum * > SHA256SUMS
say "done"; ls -la "$OUT"; du -sh "$OUT"

#!/usr/bin/env bash
# =============================================================================
#  install.sh  —  put sayss's Arch Linux + rice on THIS computer, next to Windows
#
#  Run it from the Arch Linux live USB, as root:        bash install.sh
#
#  What it does
#    1. finds your OLD Linux partition (it must really contain Arch Linux)
#    2. backs up the old Linux's settings + Secure Boot keys (into RAM)
#    3. erases ONLY that partition and installs Arch + every app + the rice
#    4. adds the Linux boot loader to the EFI partition (Windows' files stay)
#
#  What it NEVER touches
#    Windows (NTFS / BitLocker) partitions, other disks, the USB stick, and the
#    existing files on the EFI partition (it only ADDS files there, and keeps a
#    backup of the one fallback loader file it replaces).
#
#  Test-only knobs (never needed for a real install):
#    RICE_KIT_URL  RICE_TARGET  RICE_PASSWORD  RICE_ASSUME_YES  RICE_HOSTNAME  RICE_FORCE_NVIDIA
# =============================================================================
set -Eeuo pipefail

KIT_TAG=rice-UNSET
REPO=Sayss0/arch-rice-kit
USERNAME=sayss
LOG=/root/rice-install.log
CORE_TMP=/tmp/rice-core          # small kit part, in RAM (needed before formatting)
OLDBAK=/tmp/oldlinux             # old Linux backup, in RAM until the new disk is ready
KITDIR=/mnt/var/tmp/rice-kit     # big kit parts, on the NEW Linux partition
MIN_GIB=40

# ------------------------------------------------------------------ helpers --
if [[ -t 1 ]]; then B=$'\e[1m'; R=$'\e[31m'; G=$'\e[32m'; Y=$'\e[33m'; C=$'\e[36m'; N=$'\e[0m'
else B= R= G= Y= C= N=; fi
say()  { printf '%s\n' "${C}${B}==> $*${N}"; }
ok()   { printf '%s\n' "${G}  ✓ $*${N}"; }
warn() { printf '%s\n' "${Y}  ! $*${N}"; }
die()  { printf '\n%s\n' "${R}${B}STOPPED: $*${N}"; exit 1; }
FORMATTED=0
on_err() {
  local rc=$? line=${BASH_LINENO[0]}
  printf '\n%s\n' "${R}${B}Something failed (line $line, exit $rc).${N}"
  if [[ $FORMATTED == 0 ]]; then
    printf '%s\n' "${G}Nothing on your disks was changed yet — Windows and the old Linux are untouched.${N}"
  else
    printf '%s\n' "${Y}The old Linux partition was already erased, but Windows was never touched.${N}"
    printf '%s\n' "${Y}You can simply run  bash install.sh  again — it starts over cleanly.${N}"
  fi
  printf '%s\n' "Full log: $LOG   (take a photo of the last lines if you need help)"
}
trap on_err ERR
trap 'sleep 0.3' EXIT            # let the log pipe flush the last lines to the screen

ask() {  # ask "prompt" default  -> REPLY
  local p=$1 d=${2:-}
  if [[ -n ${RICE_ASSUME_YES:-} ]]; then REPLY=$d; return; fi
  read -r -p "${B}$p${N} ${d:+[$d] }" REPLY || true
  REPLY=${REPLY:-$d}
}

exec > >(tee -a "$LOG") 2>&1
echo "===== rice install started $(date -Is) — kit $KIT_TAG ====="

cat <<EOF

${B}  sayss's Arch rice installer${N}   (kit ${KIT_TAG})
  This puts the laptop's Linux + rice on this PC. Windows is never touched.
  It asks a few questions first, then runs on its own (30-90 minutes).

EOF

# ---------------------------------------------------------------- preflight --
say "Checking this computer"
[[ $EUID -eq 0 ]] || die "run it as root (the live USB is already root)."
[[ -d /run/archiso ]] || die "this only runs from the Arch Linux live USB, not from an installed system."
[[ -d /sys/firmware/efi/efivars ]] || die "the PC started the USB in old BIOS/CSM mode.
Reboot, open the boot menu (F8 on ASUS) and pick the USB entry whose name starts with 'UEFI:'."
ok "running from the live USB in UEFI mode"

mount -o remount,size=2G /run/archiso/cowspace 2>/dev/null || true
if ! curl -fsS --max-time 15 -o /dev/null https://archlinux.org; then
  die "no internet. Plug in the ethernet cable (wifi: run  iwctl  first), then run  bash install.sh  again."
fi
ok "internet works"
timedatectl set-ntp true 2>/dev/null || true

say "Waiting for the package keyring (first minute after boot only)"
for _ in $(seq 1 90); do
  st=$(systemctl show -p SubState --value pacman-init.service 2>/dev/null || echo exited)
  [[ $st == exited || $st == dead || $st == failed ]] && break
  sleep 2
done
pacman -Sy --noconfirm --needed archlinux-keyring >/dev/null 2>&1 || warn "keyring refresh failed (usually harmless)"
ok "keyring ready"

# --------------------------------------------------------- get the small kit --
fetch() {  # fetch <asset-name> <dest-dir>
  local name=$1 dest=$2
  mkdir -p "$dest"
  if [[ -n ${RICE_KIT_URL:-} ]]; then
    curl -fsS --retry 3 -o "$dest/$name" "$RICE_KIT_URL/$name"
  else
    gh release download "$KIT_TAG" -R "$REPO" -p "$name" -D "$dest" --clobber
  fi
}
if [[ -z ${RICE_KIT_URL:-} ]]; then
  command -v gh >/dev/null || pacman -S --noconfirm --needed github-cli >/dev/null
  gh auth status >/dev/null 2>&1 || die "GitHub isn't logged in yet. Run:  gh auth login   then  bash install.sh  again."
fi
say "Downloading the small part of the kit"
rm -rf "$CORE_TMP"; mkdir -p "$CORE_TMP"
fetch SHA256SUMS "$CORE_TMP"
fetch kit-core.tar.zst "$CORE_TMP"
( cd "$CORE_TMP" && grep ' kit-core.tar.zst$' SHA256SUMS | sha256sum -c --quiet ) \
  || die "the kit download is damaged (checksum mismatch). Run  bash install.sh  again."
tar -xf "$CORE_TMP/kit-core.tar.zst" -C "$CORE_TMP"
CORE=$CORE_TMP/core
ok "kit $KIT_TAG downloaded and verified"

# ----------------------------------------------------------------- hardware --
say "Looking at the hardware"
CPU_VENDOR=$(awk -F': ' '/^vendor_id/{print $2; exit}' /proc/cpuinfo)
case $CPU_VENDOR in
  AuthenticAMD) UCODE=amd-ucode ;;
  GenuineIntel) UCODE=intel-ucode ;;
  *) UCODE= ;;
esac
GPU_IDS=$(lspci -nmm 2>/dev/null | awk -F'"' '$2 ~ /^03/ {print $4}' | sort -u | tr '\n' ' ')
HAS_NVIDIA=0; HAS_AMD=0; HAS_INTEL=0
[[ $GPU_IDS == *10de* ]] && HAS_NVIDIA=1
[[ $GPU_IDS == *1002* ]] && HAS_AMD=1
[[ $GPU_IDS == *8086* ]] && HAS_INTEL=1
[[ -n ${RICE_FORCE_NVIDIA:-} ]] && { HAS_NVIDIA=1; HAS_INTEL=0; }   # VM test only: exercise the NVIDIA path
PROFILE=desktop
compgen -G '/sys/class/power_supply/BAT*' >/dev/null && PROFILE=laptop
ok "CPU: ${CPU_VENDOR:-unknown}   GPU: $( ((HAS_NVIDIA)) && printf 'NVIDIA ')$( ((HAS_AMD)) && printf 'AMD ')$( ((HAS_INTEL)) && printf 'Intel ')  → ${PROFILE} settings"

# ------------------------------------------------------------ disk survey --
say "Looking at the disks"
LIVE_DISK=$(lsblk -no PKNAME "$(findmnt -no SOURCE /run/archiso/bootmnt 2>/dev/null || echo /nonexistent)" 2>/dev/null | head -1 || true)
SURVEY=$(python3 - "$LIVE_DISK" <<'PY'
import json, subprocess, sys
live = sys.argv[1]
ESP  = 'c12a7328-f81f-11d2-ba4b-00a0c93ec93b'
MSR  = 'e3c9e316-0b5c-4db8-817d-f92df00215ae'
WRE  = 'de94bba4-06d1-4d40-a16a-bfd50179d6ac'
LINUXFS = {'btrfs', 'ext4', 'ext3', 'xfs', 'f2fs'}
WINFS = {'ntfs', 'BitLocker', 'refs', 'exfat'}
out = json.loads(subprocess.run(['lsblk', '-J', '-b', '-p', '-o',
      'NAME,TYPE,SIZE,FSTYPE,PARTTYPE,LABEL,PARTLABEL,MOUNTPOINTS,UUID,PTTYPE,MODEL,TRAN'],
      capture_output=True, text=True, check=True).stdout)
for d in out['blockdevices']:
    if d['type'] != 'disk' or d['name'].endswith(live or '\0') or d['name'].startswith(('/dev/zram', '/dev/loop', '/dev/sr')):
        continue
    if live and d['name'] == '/dev/' + live:
        continue
    print('DISK', d['name'], d['size'], d.get('pttype') or '-', (d.get('model') or '-').replace(' ', '_'), d.get('tran') or '-')
    for p in d.get('children') or []:
        if p['type'] != 'part':
            continue
        pt = (p.get('parttype') or '').lower(); fs = p.get('fstype') or ''
        if pt == ESP and fs == 'vfat':             kind = 'esp'
        elif fs in WINFS or pt in (MSR, WRE):       kind = 'windows'
        elif fs in LINUXFS:                         kind = 'linux'
        elif fs == 'swap':                          kind = 'swap'
        else:                                       kind = 'other'
        mnt = ','.join(m for m in (p.get('mountpoints') or []) if m) or '-'
        print('PART', p['name'], d['name'], p['size'], kind, fs or '-', p.get('uuid') or '-', mnt,
              (p.get('label') or p.get('partlabel') or '-').replace(' ', '_'))
PY
)
echo "$SURVEY" | sed 's/^/    /'

human() { numfmt --to=iec-i --suffix=B "$1" 2>/dev/null || echo "$1 bytes"; }

# which Linux partitions really hold an Arch install?
probe_arch() {  # probe_arch /dev/x  -> sets PROBE_ROOT PROBE_HOME PROBE_DESC (empty = not Arch)
  local dev=$1 m=/tmp/probe-${1##*/} fs
  PROBE_ROOT= PROBE_HOME= PROBE_DESC=
  fs=$(lsblk -no FSTYPE "$dev")
  mkdir -p "$m"
  if [[ $fs == btrfs ]]; then mount -o ro,subvolid=5 "$dev" "$m" 2>/dev/null || return 0
  else mount -o ro "$dev" "$m" 2>/dev/null || return 0; fi
  local r
  for r in "$m/@" "$m" "$m/@root" "$m/root" "$m"/*; do
    if [[ -f $r/etc/arch-release ]]; then PROBE_ROOT=${r#"$m"}; break; fi
  done
  if [[ -n $PROBE_ROOT || -f $m/etc/arch-release ]]; then
    local h
    for h in "$m/@home/$USERNAME" "$m$PROBE_ROOT/home/$USERNAME" "$m/home/$USERNAME"; do
      [[ -d $h ]] && { PROBE_HOME=${h#"$m"}; break; }
    done
    PROBE_DESC="old Arch Linux install${PROBE_HOME:+ (with user $USERNAME)}"
  elif [[ $fs == btrfs && $(lsblk -no LABEL "$dev") == ArchLinux && -d $m/@ ]]; then
    PROBE_ROOT=/@; [[ -d $m/@home/$USERNAME ]] && PROBE_HOME=/@home/$USERNAME
    PROBE_DESC="unfinished install from an earlier run of this installer"
  fi
  umount "$m" 2>/dev/null || true
  rmdir "$m" 2>/dev/null || true
}

declare -A DESC ROOTSUB HOMESUB
CANDS=()
while read -r tag name disk size kind fs uuid mnt label; do
  [[ $tag == PART && $kind == linux ]] || continue
  (( size >= MIN_GIB * 1073741824 )) || continue
  [[ $mnt == - ]] || continue
  echo "$SURVEY" | grep -q "^PART [^ ]* $disk [0-9]* esp " || continue   # needs an EFI partition on the same disk
  probe_arch "$name"
  if [[ -n $PROBE_DESC ]]; then
    CANDS+=("$name"); DESC[$name]=$PROBE_DESC; ROOTSUB[$name]=$PROBE_ROOT; HOMESUB[$name]=$PROBE_HOME
  fi
done <<< "$SURVEY"

# ----------------------------------------------------------- pick target --
TARGET= NEWPART=0
if [[ -n ${RICE_TARGET:-} ]]; then
  for c in "${CANDS[@]}"; do [[ $c == "$RICE_TARGET" ]] && TARGET=$c; done
  [[ -n $TARGET ]] || die "RICE_TARGET=$RICE_TARGET is not a verified old-Arch partition."
elif (( ${#CANDS[@]} == 0 )); then
  cat <<EOF

${Y}${B}No old Arch Linux partition was found on this computer.${N}
  (The installer only ever erases a partition that verifiably contains an old
   Arch install, so it can never wipe Windows or a data drive by mistake.)

  Nothing was changed. Take a photo of the disk list above and ask Claude
  for help (from Windows) — the fix is to point this installer at free space.
EOF
  exit 1
else
  echo
  echo "${B}Here is what is on this computer:${N}"
  while read -r tag name disk size kind fs uuid mnt label; do
    # DISK lines are: DISK name size pttype model tran  (so size lands in $disk, model in $kind)
    [[ $tag == PART ]] || { [[ $tag == DISK ]] && printf '\n  %sDisk %s%s  (%s, %s)\n' "$B" "$name" "$N" "$(human "$disk")" "$kind"; continue; }
    case $kind in
      esp)     what="EFI boot partition (shared with Windows)  → kept, Linux only ADDS its boot files" ;;
      windows) what="Windows ($fs)                              → ${G}NEVER touched${N}" ;;
      linux)   if [[ -n ${DESC[$name]:-} ]]; then what="${DESC[$name]}  → ${R}${B}ERASE: the new Linux goes here${N}"
               else what="Linux data ($fs), not an OS            → not touched"; fi ;;
      *)       what="$fs                                        → not touched" ;;
    esac
    printf '    %-18s %10s   %s\n' "${name#/dev/}" "$(human "$size")" "$what"
  done <<< "$SURVEY"
  echo
  if (( ${#CANDS[@]} == 1 )); then
    SUGGEST=${CANDS[0]#/dev/}
  else
    SUGGEST=
    warn "More than one old Arch install was found — pick the right one."
  fi
  while :; do
    ask "Type the name of the partition to ERASE and install onto (e.g. ${SUGGEST:-nvme0n1p2}):" ""
    for c in "${CANDS[@]}"; do [[ ${c#/dev/} == "${REPLY#/dev/}" ]] && TARGET=$c; done
    [[ -n $TARGET ]] && break
    warn "'$REPLY' is not one of the old-Arch partitions listed above. Type it exactly, e.g. ${SUGGEST:-nvme0n1p2}"
  done
fi

# ---- hard guards on the chosen target (belt and braces) ----
TGT_TYPE=$(lsblk -dno TYPE "$TARGET")
TGT_FS=$(lsblk -dno FSTYPE "$TARGET")
TGT_PT=$(lsblk -dno PARTTYPE "$TARGET" | tr 'A-Z' 'a-z')
TGT_DISK=/dev/$(lsblk -dno PKNAME "$TARGET")
[[ $TGT_TYPE == part ]] || die "$TARGET is not a partition."
[[ $TGT_FS =~ ^(btrfs|ext4|ext3|xfs|f2fs)$ ]] || die "$TARGET is $TGT_FS, not a Linux filesystem — refusing."
[[ $TGT_PT != c12a7328-f81f-11d2-ba4b-00a0c93ec93b && $TGT_PT != e3c9e316-0b5c-4db8-817d-f92df00215ae && $TGT_PT != de94bba4-06d1-4d40-a16a-bfd50179d6ac ]] \
  || die "$TARGET has a Windows/EFI partition type — refusing."
if wipefs --noheadings --output TYPE "$TARGET" 2>/dev/null | grep -qiE 'ntfs|vfat|bitlocker|exfat'; then
  die "$TARGET carries a Windows/FAT signature — refusing."
fi
findmnt -S "$TARGET" >/dev/null && die "$TARGET is mounted — refusing."
[[ -n $LIVE_DISK && $TGT_DISK == /dev/$LIVE_DISK ]] && die "$TARGET is on the USB stick — refusing."

# EFI partition on the same disk: prefer the one that holds Windows' boot manager
ESP_DEV=
for e in $(echo "$SURVEY" | awk -v d="$TGT_DISK" '$1=="PART" && $3==d && $5=="esp" {print $2}'); do
  m=/tmp/probe-esp; mkdir -p $m
  if mount -o ro "$e" $m 2>/dev/null; then
    if [[ -f $m/EFI/Microsoft/Boot/bootmgfw.efi ]]; then ESP_DEV=$e; umount $m; break; fi
    [[ -z $ESP_DEV ]] && ESP_DEV=$e
    umount $m
  fi
done
[[ -n $ESP_DEV ]] || die "no usable EFI partition on $TGT_DISK."
ESP_UUID=$(lsblk -dno UUID "$ESP_DEV")
ok "target: $TARGET ($(human "$(lsblk -bdno SIZE "$TARGET")"), ${DESC[$TARGET]})"
ok "boot files go to the EFI partition $ESP_DEV (nothing there is deleted)"

# ------------------------------------------------------------- questions --
say "Two questions, then it runs by itself"
DEF_HOST=Sayss; [[ $PROFILE == laptop ]] && DEF_HOST=Sayss_linux
if [[ -n ${RICE_HOSTNAME:-} ]]; then HOSTNAME_NEW=$RICE_HOSTNAME
else ask "Computer name:" "$DEF_HOST"; HOSTNAME_NEW=$REPLY; fi
[[ $HOSTNAME_NEW =~ ^[A-Za-z0-9_-]{1,63}$ ]] || die "computer name may only use letters, numbers, - and _"

if [[ -n ${RICE_PASSWORD:-} ]]; then PW=$RICE_PASSWORD
else
  while :; do
    read -r -s -p "${B}Password for user '$USERNAME' (also used for sudo):${N} " PW; echo
    read -r -s -p "${B}Type it again:${N} " PW2; echo
    [[ -n $PW && $PW == "$PW2" ]] && break
    warn "The two passwords were empty or different — try again."
  done
  unset PW2
fi

echo
echo "${B}Last check before anything is changed:${N}"
echo "    ERASE   ${R}$TARGET${N}  — ${DESC[$TARGET]}"
echo "    keep    everything else on every disk (Windows included)"
echo "    add     Linux boot files to $ESP_DEV"
echo "    name    $HOSTNAME_NEW    user $USERNAME    settings: $PROFILE"
echo
if [[ -z ${RICE_ASSUME_YES:-} ]]; then
  read -r -p "${B}Type ERASE (in capitals) to start, anything else to cancel:${N} " REPLY
  [[ $REPLY == ERASE ]] || { echo "Cancelled — nothing was changed."; exit 0; }
fi

# ------------------------------------------------------ back up old Linux --
say "Backing up the old Linux's settings before erasing it"
if [[ -f $OLDBAK/old-etc.tar ]]; then
  ok "reusing the backup made earlier in this session ($(du -sh "$OLDBAK" | cut -f1))"
else
  rm -rf "$OLDBAK"; mkdir -p "$OLDBAK"
  bash "$CORE/oldlinux-backup.sh" "$TARGET" "${ROOTSUB[$TARGET]}" "${HOMESUB[$TARGET]}" "$OLDBAK" "$CORE" \
    || die "the backup of the old Linux failed — nothing was erased."
  ok "backup ready ($(du -sh "$OLDBAK" | cut -f1) in memory)"
fi

# ----------------------------------------------------------- format + mount --
say "Erasing $TARGET and creating the new Linux filesystem"
umount -R /mnt 2>/dev/null || true
FORMATTED=1
wipefs -a -q "$TARGET"
mkfs.btrfs -f -q -L ArchLinux "$TARGET"
udevadm settle
mount "$TARGET" /mnt
btrfs subvolume create /mnt/@ >/dev/null
btrfs subvolume create /mnt/@home >/dev/null
umount /mnt
MOPT=noatime,compress=zstd:1,space_cache=v2,discard=async
mount -o "$MOPT,subvol=@" "$TARGET" /mnt
mkdir -p /mnt/home /mnt/boot/efi
mount -o "$MOPT,subvol=@home" "$TARGET" /mnt/home
mount "$ESP_DEV" /mnt/boot/efi
ok "new filesystem mounted (the EFI partition was NOT formatted)"

# ---------------------------------------------------------- get the big kit --
say "Downloading the rest of the kit (≈2 GB) onto the new partition"
mkdir -p "$KITDIR"
cp "$CORE_TMP/SHA256SUMS" "$KITDIR/"
for f in $(awk '{print $2}' "$KITDIR/SHA256SUMS" | grep -vE '^(install\.sh|kit-core\.tar\.zst)$'); do
  fetch "$f" "$KITDIR"
done
( cd "$KITDIR" && grep -vE ' (install\.sh|kit-core\.tar\.zst)$' SHA256SUMS | sha256sum -c --quiet ) \
  || die "a kit file is damaged (checksum mismatch). Run  bash install.sh  again."
for base in $(ls "$KITDIR" | sed -n 's/\.part00$//p'); do
  cat "$KITDIR/$base".part?? > "$KITDIR/$base" && rm -f "$KITDIR/$base".part??
done
cp -a "$CORE" "$KITDIR/core"
ok "kit verified"

# -------------------------------------------------------------- packages --
say "Choosing packages for this hardware"
cp /etc/pacman.conf /tmp/pacman.rice.conf
sed -i -e 's/^#\?ParallelDownloads.*/ParallelDownloads = 10/' /tmp/pacman.rice.conf
grep -q '^\[multilib\]' /tmp/pacman.rice.conf || printf '\n[multilib]\nInclude = /etc/pacman.d/mirrorlist\n' >> /tmp/pacman.rice.conf
pacman -Sy --config /tmp/pacman.rice.conf >/dev/null
pacman -Slq --config /tmp/pacman.rice.conf | sort -u > /tmp/avail.txt
declare -A WANT
while read -r name why; do WANT[$name]=$why; done < "$CORE/lists/pkg-native.txt"
drop() { local p; for p; do unset "WANT[$p]"; done; }
add()  { local p; for p; do WANT[$p]=explicit; done; }
drop intel-ucode amd-ucode; [[ -n $UCODE ]] && add "$UCODE"
if (( HAS_NVIDIA )); then
  drop nvidia-open nvidia
  add nvidia-open-dkms nvidia-utils lib32-nvidia-utils libva-nvidia-driver egl-wayland dkms
  add linux-lts linux-lts-headers                  # safe fallback kernel (the desktop always had it)
else
  drop nvidia-open nvidia-open-dkms nvidia-utils lib32-nvidia-utils libva-nvidia-driver nvidia-settings
fi
(( HAS_INTEL )) || drop intel-media-driver vulkan-intel libva-intel-driver
(( HAS_AMD )) && add vulkan-radeon lib32-vulkan-radeon
add base linux linux-headers linux-firmware btrfs-progs grub efibootmgr sbctl \
    quickshell github-cli git base-devel autoconf-archive meson cmake ninja qt6-shadertools
PKGS=(); DEPS=(); MISSING=()
for p in "${!WANT[@]}"; do
  if grep -qxF "$p" /tmp/avail.txt; then PKGS+=("$p"); [[ ${WANT[$p]} == dep ]] && DEPS+=("$p")
  else MISSING+=("$p"); fi
done
(( ${#MISSING[@]} )) && warn "not in the repos anymore, skipped: ${MISSING[*]}"
ok "${#PKGS[@]} packages (+ the AUR ones later)"

say "Installing Arch + all apps (the long part: downloads a few GB)"
pacstrap -C /tmp/pacman.rice.conf -K /mnt "${PKGS[@]}"
printf '%s\n' "${DEPS[@]}" > "$KITDIR/asdeps.txt"
ok "packages installed"

genfstab -U /mnt >> /mnt/etc/fstab
ok "fstab written"

# --------------------------------------------------- hand over to chroot --
say "Configuring the new system"
tar --numeric-owner -xpf "$CORE/system-rice.tar" -C /mnt
(( HAS_NVIDIA )) || rm -f /mnt/etc/modprobe.d/nvidia.conf /mnt/etc/modprobe.d/blacklist-nouveau.conf
install -d -m700 /mnt/root
if [[ -f /root/.config/gh/hosts.yml ]]; then            # reuse the GitHub login from this USB session
  install -Dm600 /root/.config/gh/hosts.yml "$KITDIR/gh-hosts.yml"
fi
cp -a "$OLDBAK" "$KITDIR/oldlinux"
umask 077
printf '%s:%s\n' "$USERNAME" "$PW" > /mnt/root/.rice-pw
printf 'root:%s\n' "$PW" >> /mnt/root/.rice-pw
unset PW
umask 022
cat > "$KITDIR/answers.env" <<EOF
USERNAME=$USERNAME
HOSTNAME_NEW=$HOSTNAME_NEW
PROFILE=$PROFILE
HAS_NVIDIA=$HAS_NVIDIA
HAS_AMD=$HAS_AMD
HAS_INTEL=$HAS_INTEL
ESP_UUID=$ESP_UUID
KIT_TAG=$KIT_TAG
EOF
cp "$LOG" "$KITDIR/install-live.log" 2>/dev/null || true
arch-chroot /mnt bash /var/tmp/rice-kit/core/chroot-setup.sh
rm -f /mnt/root/.rice-pw

# ------------------------------------------------------------------ finish --
cp "$LOG" /mnt/var/log/rice-install.log 2>/dev/null || true
sync
umount -R /mnt || warn "could not unmount everything (harmless)"
cat <<EOF

${G}${B}  All done.${N}
  • Take the USB stick out, then type:  ${B}reboot${N}
  • The GRUB menu shows "Arch Linux" (default) and "Windows 11".
  • Log in as ${B}$USERNAME${N} with the password you chose.
  • A report of anything that needs a look is in ~/RICE-INSTALL-REPORT.txt
EOF

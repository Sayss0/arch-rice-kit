#!/usr/bin/env bash
# oldlinux-backup.sh <dev> <root-subpath> <home-subpath> <outdir> <coredir>
#
# Runs from the live USB right BEFORE the old Linux partition is erased.
# Mounts it READ-ONLY and copies into RAM (<outdir>, a tmpfs):
#   sbctl/                 Secure Boot keys  -> restored into the new system
#   old-etc.tar            the whole old /etc (hardware tweaks, fstab, grub, ...)
#   old-opt-zapret.tar     the Discord DPI-bypass config
#   old-home.tar           the old user's settings (same no-logins/no-cache rules as the kit)
#   home-overrides/        this machine's own hardware-specific rice files
#                          (monitor, keyboard/mouse, dGPU widget, sddm template, shell.json)
# The old partition is never written to.
set -Eeuo pipefail
dev=$1 rootsub=$2 homesub=$3 out=$4 core=$5
USERNAME=sayss
m=/tmp/oldlinux-mnt
mkdir -p "$m" "$out"
if [[ $(lsblk -no FSTYPE "$dev") == btrfs ]]; then mount -o ro,subvolid=5 "$dev" "$m"
else mount -o ro "$dev" "$m"; fi
trap 'umount "$m" 2>/dev/null || true' EXIT

R=$m$rootsub
H=
[[ -n $homesub && -d $m$homesub ]] && H=$m$homesub

# A previous run of this installer already put the REAL old-Linux backup on this
# partition — carry that forward instead of backing up a half-installed system.
for prev in "$R/var/tmp/rice-kit/oldlinux" ${H:+"$H/old-linux-backup"}; do
  if [[ -f $prev/old-etc.tar ]]; then
    cp -a "$prev/." "$out/"
    echo "  carried forward the old-Linux backup from the earlier run"
    exit 0
  fi
done

# 1. Secure Boot keys (sbctl; old versions used /usr/share/secureboot)
for d in var/lib/sbctl usr/share/secureboot; do
  if [[ -d $R/$d ]]; then
    mkdir -p "$out/sbctl"
    cp -a "$R/$d" "$out/sbctl/${d//\//_}"
    echo "  saved Secure Boot keys from /$d"
  fi
done

# 2. system settings
if [[ -d $R/etc ]]; then
  tar -C "$R" -cf "$out/old-etc.tar" etc 2>/dev/null || [[ -s $out/old-etc.tar ]]
else
  tar -cf "$out/old-etc.tar" --files-from /dev/null      # nothing to save (unfinished earlier run)
fi
if [[ -d $R/opt/zapret ]]; then
  tar -C "$R" -cf "$out/old-opt-zapret.tar" opt/zapret/config opt/zapret/ipset 2>/dev/null || true
fi
[[ -d $R/etc ]] && echo "  saved /etc ($(du -sh "$out/old-etc.tar" | cut -f1))"

# 3. user settings
if [[ -n $H ]]; then
  HOME=$H python3 "$core/homelist.py" --oldhome > "$out/.homelist" 2> "$out/home-skipped.txt" || true
  need=$(HOME=$H python3 - "$out/.homelist" <<'PY'
import os, sys
home = os.environ["HOME"]; tot = 0
for rel in open(sys.argv[1]).read().split("\0"):
    p = os.path.join(home, rel)
    if rel and os.path.isfile(p) and not os.path.islink(p):
        tot += os.path.getsize(p)
print(tot // 1024)
PY
)
  free=$(df --output=avail -k "$out" | tail -1)
  if (( need + 524288 < free )); then
    tar --null --no-recursion -C "$H" -T "$out/.homelist" -cf "$out/old-home.tar" 2>/dev/null \
      || [[ -s $out/old-home.tar ]]
    echo "  saved the old user's settings ($(du -sh "$out/old-home.tar" | cut -f1))"
  else
    echo "  ! not enough memory to back up the old user's settings ($((need/1024)) MB) — skipped"
  fi
  rm -f "$out/.homelist"

  # 4. this machine's own hardware-specific rice files. Absolute symlinks
  #    (~/.config/hypr -> /home/sayss/.rices/...) are resolved INSIDE the old partition.
  python3 - "$H" "$out/home-overrides" "$USERNAME" <<'PY'
import os, shutil, sys
home, dest, user = sys.argv[1], sys.argv[2], sys.argv[3]
FILES = [
    ".config/hypr/monitors.conf", ".config/hypr/monitors.lua",
    ".config/caelestia/hypr-user.lua",
    ".config/quickshell/caelestia/modules/bar/popouts/Tools.qml",
    ".config/matugen/templates/sddm/theme.conf",
    ".config/caelestia/shell.json",
]
def resolve(rel):
    cur = home
    for part in rel.split("/"):
        cur = os.path.join(cur, part)
        for _ in range(8):
            if not os.path.islink(cur):
                break
            t = os.readlink(cur)
            if t.startswith(f"/home/{user}/"):
                cur = os.path.join(home, t[len(f"/home/{user}/"):])
            elif t.startswith("/"):
                return None                     # points outside the home: ignore
            else:
                cur = os.path.normpath(os.path.join(os.path.dirname(cur), t))
    return cur
for rel in FILES:
    src = resolve(rel)
    if src and os.path.isfile(src):
        os.makedirs(os.path.dirname(os.path.join(dest, rel)), exist_ok=True)
        shutil.copy2(src, os.path.join(dest, rel))
        print(f"  kept this PC's own {rel}")
PY
else
  echo "  ! no /home/$USERNAME found on the old partition — only system settings saved"
fi
chmod -R go-rwx "$out"

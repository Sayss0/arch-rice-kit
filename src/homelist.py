#!/usr/bin/env python3
"""Print (NUL-separated, relative to $HOME) every path that belongs in the
home-rice archive: the look, settings, scripts and app configs — but NO logins,
tokens, keys, browser profiles, caches, toolchains or game data.

usage: homelist.py > list.nul          (report of skipped big items -> stderr)
       homelist.py --wallpapers > list.nul   (only ~/Pictures/wallpapers)
"""
import os, sys, fnmatch

HOME = os.path.expanduser("~")
BIG = 200 * 1024 * 1024          # single files above this are skipped + reported

# Top-level things that ARE the rice / app settings.
INCLUDE = [
    ".bashrc", ".bash_profile", ".bash_logout", ".gitconfig", ".face",
    "keybinds.md", "python-linux-mastery.md",
    ".config", ".local/bin", ".local/share", ".local/state",
    ".rices", ".icons", ".themes", ".dotfiles", ".vscode/argv.json",
    "Pictures/kurukuru.gif",
    ".claude/CLAUDE.md", ".claude/commands", ".claude/gitleaks.toml", ".claude/hooks",
    ".claude/no-leak.sh", ".claude/output-styles", ".claude/plugins",
    ".claude/settings.json", ".claude/skills", ".claude/statusline.sh",
]

# Exact paths (relative to HOME) that are dropped with everything under them.
EXCLUDE_PATHS = {
    # logins / tokens / private keys
    ".config/gh/hosts.yml", ".config/pulse/cookie", ".config/libaccounts-glib",
    ".config/discord", ".config/legcord", ".config/spotify", ".config/Todoist",
    ".config/ZapZap", ".config/session",
    # browser profiles (cookies + saved logins)
    ".config/opera-gx", ".config/google-chrome", ".config/mozilla",
    ".config/chromium", ".config/BraveSoftware", ".config/zen",
    # machine-specific hardware configs that must not travel
    ".config/coolercontrol",
    # caches / state that is per-machine or regenerated
    ".local/share/Trash", ".local/share/keyrings", ".local/share/claude",
    ".local/share/uv", ".local/share/mise", ".local/share/atuin",
    ".local/share/zoxide", ".local/share/baloo", ".local/share/gvfs-metadata",
    ".local/share/kactivitymanagerd", ".local/share/recently-used.xbel",
    ".local/share/ZapZap", ".local/share/Steam", ".local/share/PandoraLauncher",
    ".local/share/warp-terminal", ".local/share/zed", ".local/share/nvim",
    ".local/share/fish", ".local/share/audiorelay", ".local/share/remoteview",
    ".local/share/qtposition-geoclue2", ".local/share/sddm", ".local/share/systemd",
    ".local/share/hyprland", ".local/share/krita.log", ".local/share/krita-sysinfo.log",
    ".local/share/user-places.xbel.bak", ".local/share/user-places.xbel.tbcache",
    ".local/share/flatpak",
    ".local/state/claude", ".local/state/nvim", ".local/state/lesshst",
    ".local/state/paru", ".local/state/pnpm", ".local/state/wireplumber",
    ".local/state/VSCodium", ".local/state/live-wallpaper.log",
    ".local/state/quickshell/.venv",
    ".local/bin/claude",           # symlink into ~/.local/share/claude (reinstalled fresh)
}

# VS Code / VSCodium: keep only the user's own settings, never their token stores.
EDITOR_KEEP = {
    ".config/Code": {"User/settings.json", "User/keybindings.json", "User/snippets"},
    ".config/VSCodium": {"User/settings.json", "User/keybindings.json", "User/snippets"},
}

# Directory / file NAMES dropped anywhere (Electron/Chromium session + cache internals).
EXCLUDE_NAMES = {
    "Cache", "Code Cache", "GPUCache", "DawnCache", "DawnGraphiteCache", "DawnWebGPUCache",
    "Service Worker", "Local Storage", "Session Storage", "IndexedDB", "databases",
    "blob_storage", "Network", "Crashpad", "Shared Dictionary", "SharedStorage",
    "WebStorage", "VideoDecodeStats", "CachedData", "CachedProfilesData", "sessionData",
    "partitions", "Cookies", "Cookies-journal", "Login Data", "Login Data-journal",
    "Web Data", "Web Data-journal", "Local State", "Trust Tokens", "Trust Tokens-journal",
    "History", "History-journal", "Favicons", "Favicons-journal", "TransportSecurity",
    "Network Persistent State", "QuotaManager", "QuotaManager-journal",
    "globalStorage", "workspaceStorage", "logs", "__pycache__", ".venv", "node_modules",
    "shell-snapshots", ".credentials.json",
}
EXCLUDE_GLOBS = ["*.log", "*.log.old", "core.*", "*.pyc"]


def excluded(rel, name):
    if rel in EXCLUDE_PATHS:
        return True
    if name in EXCLUDE_NAMES and not (name == "logs" and "/.git/" in f"/{rel}"):
        return True
    return any(fnmatch.fnmatch(name, g) for g in EXCLUDE_GLOBS)


def editor_keep(rel):
    """None = not an editor dir; True/False = keep/skip inside an editor dir."""
    for root, keep in EDITOR_KEEP.items():
        if rel == root:
            return True
        if rel.startswith(root + "/"):
            sub = rel[len(root) + 1:]
            return any(sub == k or sub.startswith(k + "/") or k.startswith(sub + "/") for k in keep)
    return None


def walk(rel, out, skipped):
    full = os.path.join(HOME, rel)
    name = os.path.basename(rel)
    if excluded(rel, name):
        return
    ek = editor_keep(rel)
    if ek is False:
        return
    if os.path.islink(full) or not os.path.isdir(full):
        if not os.path.lexists(full):
            return
        if not os.path.islink(full):
            try:
                size = os.path.getsize(full)
            except OSError:
                return
            if size > BIG:
                skipped.append((size, rel)); return
            if not os.access(full, os.R_OK):
                skipped.append((-1, rel)); return
        out.append(rel)
        return
    out.append(rel)                           # the directory itself (keeps empty dirs + modes)
    try:
        entries = sorted(os.listdir(full))
    except PermissionError:
        skipped.append((-1, rel)); return
    for e in entries:
        walk(f"{rel}/{e}", out, skipped)


def main():
    global BIG
    out, skipped = [], []
    roots = ["Pictures/wallpapers"] if "--wallpapers" in sys.argv else list(INCLUDE)
    if "--oldhome" in sys.argv:
        # backing up the OLD Linux before it is erased: also keep loose notes/scripts
        # (e.g. dual-boot-league-plan.md, SECURE-BOOT-RECOVERY.txt) and the GRUB backup,
        # but hold it to RAM-friendly sizes.
        BIG = 50 * 1024 * 1024
        for e in sorted(os.listdir(HOME)):
            if not os.path.isdir(os.path.join(HOME, e)) and e.endswith((".md", ".txt", ".sh", ".conf", ".json")):
                roots.append(e)
        roots += ["grub-efi-backup", ".claude/projects/-home-sayss/memory/state"]
    for r in roots:
        if os.path.lexists(os.path.join(HOME, r)):
            walk(r, out, skipped)
    sys.stdout.write("\0".join(out) + "\0")
    for size, rel in skipped:
        print(f"SKIPPED {'unreadable' if size < 0 else f'{size/1048576:.0f}MB'}: {rel}", file=sys.stderr)


if __name__ == "__main__":
    main()

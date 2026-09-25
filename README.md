# arch-rice-kit (private)

Installer that puts **sayss's laptop Arch Linux + rice** onto the **main PC**,
replacing only its old Linux partition. Windows is never touched.

- **Use it:** follow the phone guide (claude.ai artifact linked in the brain) or
  `transfer-to-desktop/2026-09-25-full-install-kit/README.md` in `Sayss0/claude-brain`.
- **Short version** (from the official Arch ISO, as root):
  ```bash
  loadkeys trq
  pacman -Sy --noconfirm github-cli && gh auth login
  gh release download rice-2026-09-25 -R Sayss0/arch-rice-kit -p install.sh
  bash install.sh
  ```

## Release `rice-2026-09-25`

| asset | what |
|---|---|
| `install.sh` | live-USB installer (disk guards, old-Linux backup, pacstrap, hand-off) |
| `kit-core.tar.zst` | lists, `chroot-setup.sh`, system rice, vendored caelestia-shell 2.3.0 + libcava 1.0.0, desktop overrides |
| `aur-pkgs.tar` | the laptop's 70 AUR packages as exact package files |
| `home-rice.tar.zst` | `~` rice: configs, scripts, themes, fonts — no logins, keys or caches |
| `wallpapers.tar` | `~/Pictures/wallpapers` |
| `SHA256SUMS` | checksums (the installer verifies them) |

## Rebuild (on the laptop)

```bash
TAG=rice-YYYY-MM-DD bash ~/arch-rice-kit/src/build-kit.sh   # writes ~/arch-rice-kit/out
```
`src/` here is a copy of the build + install scripts; `test/` is the QEMU harness
(fake main-PC disk: ESP + old Arch btrfs + MSR + NTFS) used to verify a release.

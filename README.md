# Debian Worktop

A high-performance Debian Trixie (13) system that runs entirely from RAM, with a clean two-system design for easy upgrades and package management.

---

## Architecture

```
Single disk, two systems:

┌──────────────────────────────────────────────────────────────┐
│  p1  EFI           512 MiB  FAT32                            │
│  p2  WORKTOP_BOOT    4 GiB  ext4   squashfs + kernels + GRUB │
│  p3  WORKTOP_ROOT    N GiB  ext4   BASE SYSTEM               │
│  p4  PERSIST        rest    LUKS2  overlay persistence       │
└──────────────────────────────────────────────────────────────┘
```

### BASE SYSTEM  (p3, WORKTOP_ROOT)

A normal, fully installed Debian. This is where you manage packages and configuration. You boot into this system to:
- Install or remove packages with `apt`
- Edit configuration files
- Add custom repos or PPAs
- Apply any system changes

When you are done making changes, run `sudo update-worktop` from here to publish them to the live system.

### LIVE / TORAM SYSTEM  (p2, WORKTOP_BOOT)

On each boot, the squashfs on the BOOT partition is copied entirely into RAM. Everything — every file read, every process — runs at memory speed. There is no further disk I/O during normal use.

Changes you make while in the live system are saved to the LUKS-encrypted PERSIST partition and restored on next boot.

---

## Everyday workflow

```
1. Boot into BASE SYSTEM
   ↓
2. Make your changes
   sudo apt install neovim htop
   sudo apt install linux-image-6.x.x-xanmod  (or any kernel)
   sudo apt upgrade
   (any changes you want)
   ↓
3. Publish to live system
   sudo update-worktop
   ↓
4. Reboot → select "Debian Worktop (TORAM LIVE)" in GRUB
   ↓
5. Running at full RAM speed with your changes baked in
```

That's it. No chroots, no package lists to maintain, no special commands for installing software. You use the base system exactly like a normal Debian machine.

---

## Building the ISO

### Host dependencies

```bash
apt-get install mmdebstrap xorriso squashfs-tools mtools \
    grub-efi-amd64-bin dosfstools isolinux syslinux-common
```

### Build

```bash
chmod +x Debian-toram.sh
sudo ./Debian-toram.sh
# ISO written to: ./worktop-build/debian-worktop-13-live.iso
```

### Configuration (top of script)

| Variable | Default | Description |
|----------|---------|-------------|
| `LIVE_USER` | `ebram` | Default username |
| `SQUASHFS_COMP_LEVEL` | `19` | zstd compression level (1–22) |

#### Compression level guide

| Level | Build time | Squashfs size | RAM used | Recommended for |
|-------|-----------|--------------|----------|-----------------|
| 1 | ~2 min | largest | most | CI / testing only |
| 9 | ~5 min | medium | moderate | low-RAM machines |
| 19 | ~15 min | small | least | **daily use (default)** |
| 22 | ~40 min | marginally smaller | — | rarely worth it |

Higher compression = smaller file loaded into RAM on every boot = both less RAM consumed and faster boot. The compression cost is paid once, when building or updating.

---

## Writing to USB

```bash
sudo dd if=worktop-build/debian-worktop-13-live.iso \
        of=/dev/sdX bs=4M status=progress oflag=sync
```

---

## Installing to disk

Boot the ISO, open a terminal:

```bash
sudo install-worktop
```

You will be asked for:
1. Target disk (e.g. `/dev/sda`, `/dev/nvme0n1`)
2. `YES` confirmation
3. ROOT partition size in GB (default: 20)
4. A LUKS password for the PERSIST partition

The installer creates both systems and configures GRUB automatically.

---

## First boot after installation

GRUB shows two entries:

```
Debian GNU/Linux               ← BASE SYSTEM  (use this to manage packages)
Debian Worktop (TORAM LIVE)    ← LIVE SYSTEM  (runs from RAM)
```

**Boot the BASE SYSTEM first.** Then:

```bash
# Change default passwords
passwd
sudo passwd root

# Install anything you want
sudo apt update && sudo apt upgrade
sudo apt install your-packages

# Publish changes to the live system
sudo update-worktop

# Reboot into the live system
sudo reboot
```

---

## Default credentials

| Account | Password |
|---------|---------|
| `root` | `worktop` |
| `ebram` | `worktop` |

Change both on first boot.

---

## Installing and updating packages

### In the base system (permanent — survives all future updates)

Boot into the base system and use `apt` normally:

```bash
sudo apt install htop neovim tmux
sudo apt install linux-xanmod-x64v3   # custom kernel, see below
sudo apt upgrade
```

Then rebuild the live squashfs:

```bash
sudo update-worktop
```

### Example: XanMod kernel

```bash
# Boot into BASE SYSTEM, then:

# 1. Add the XanMod repo
wget -qO - https://dl.xanmod.org/archive.key \
    | gpg --dearmor \
    | sudo tee /usr/share/keyrings/xanmod-archive-keyring.gpg > /dev/null

echo "deb [signed-by=/usr/share/keyrings/xanmod-archive-keyring.gpg] \
    http://deb.xanmod.org releases main" \
    | sudo tee /etc/apt/sources.list.d/xanmod.list

sudo apt update

# 2. Check your CPU level (x64v1/v2/v3/v4)
#    v1 = any x86-64
#    v2 = AVX/AVX2 (most CPUs since ~2013)
#    v3 = AVX2 + AVX512 (Haswell / Zen3+)
#    v4 = AVX512-heavy (Skylake-X / Zen4)
grep -m1 flags /proc/cpuinfo | grep -c avx512   # 0=v2, 1+=v3 or v4

# 3. Install
sudo apt install linux-xanmod-x64v3

# 4. Publish to live system
sudo update-worktop
# → reboot → both kernels appear in GRUB under "Debian Worktop (TORAM LIVE)"
```

Because the XanMod repo and package are installed in the base system, every future `sudo apt upgrade && sudo update-worktop` will also upgrade the XanMod kernel automatically.

### In the live system (temporary — wiped on next update-worktop)

If you just want to try something without making it permanent, you can `apt install` directly in the live system. Changes are saved to PERSIST and survive reboots — but the next time you run `update-worktop` from the base system, the overlay is wiped and the change is lost.

Use the live system for:
- Testing a package before committing to it
- Session-only tools you don't want permanently
- Anything you want to undo cleanly

---

## update-worktop

Run from the **BASE SYSTEM** only.

```bash
sudo update-worktop
```

What it does:

| Step | Action |
|------|--------|
| 1 | `mksquashfs /` → `/boot/live/filesystem.squashfs.new` |
| 2 | Atomic `mv` replaces the live squashfs (power-safe) |
| 3 | Copies all `/boot/vmlinuz-*` to `/boot/live/kernels/` |
| 4 | Updates GRUB entries |
| 5 | Wipes PERSIST overlay (required — old overlay doesn't match new base) |
| 6 | Prompts to reboot |

**Why is the overlay wiped?**
The overlay stores the diff between the squashfs and your live changes. After the squashfs is rebuilt from a different base, the old diff no longer applies cleanly — it references file paths and versions from the old system. Wiping it gives the live system a clean start on the new base.

**How long does it take?**
Mostly the `mksquashfs` compression step. At level 19 on 8 cores: roughly 10–20 minutes depending on how much is installed. This runs in the base system — the live system is untouched and the old squashfs remains valid until the atomic swap at the end.

---

## Persistence (live system only)

Changes made in the live/toram system are saved to the LUKS-encrypted PERSIST partition and restored on every boot.

| Event | Action |
|-------|--------|
| Boot | LUKS unlocked, saved state rsync'd into live overlay |
| Every 5 min | Overlay saved to PERSIST (background) |
| Shutdown | Final sync + luksClose |

### LUKS password prompt

The prompt appears on **tty12** so it never conflicts with the login screen.

If the screen looks blank after the toram copy:
```
Press Ctrl+Alt+F12
```
Type your LUKS password and press Enter. Nothing appears while typing — normal.

### Monitoring

```bash
tail -f /var/log/worktop-sync.log     # watch sync activity
systemctl status worktop-sync.service  # service status
sudo worktop-sync-engine --sync        # force save right now
```

---

## Troubleshooting

### "You are running inside the live/toram system"

`update-worktop` detected an active overlayfs and refused to run.  
Boot into **Debian GNU/Linux** (the base system entry in GRUB), not the Toram Live entry.

### Live system not reflecting changes after update-worktop

Make sure you rebooted into the TORAM LIVE entry after `update-worktop` finished. The running live session is a RAM snapshot — it does not hot-reload.

### Persistence not working

Check the sync log:
```bash
tail -50 /var/log/worktop-sync.log
```

Force a manual save:
```bash
sudo worktop-sync-engine --sync
```

### Wipe persistence (start fresh in live system)

Boot the base system:
```bash
sudo cryptsetup luksOpen /dev/disk/by-partlabel/PERSIST worktop-persist
sudo mount /dev/mapper/worktop-persist /mnt
sudo rm -rf /mnt/upper/*
sudo umount /mnt
sudo cryptsetup luksClose worktop-persist
```
Reboot into TORAM LIVE — it starts clean.

---

## Custom scripts reference

| Script | Runs on | Purpose |
|--------|---------|---------|
| `install-worktop` | Live ISO | Partition disk, clone both systems, install GRUB |
| `update-worktop` | BASE system | Squash `/` → rebuild live squashfs |
| `worktop-sync-engine` | Live system | Manage PERSIST overlay (called by systemd) |

---

## Architecture notes

**Why squash `/` directly instead of using a chroot?**
The base system IS the source of truth. Squashing it directly means what you test in the base system is exactly what runs in the live system — no translation layer, no config files to maintain, no risk of the two systems drifting apart.

**Why keep the base system at all?**
The live system runs from an immutable squashfs. You cannot persist package installs through initramfs or GRUB — they need to be baked into the squashfs. The base system is a stable Debian environment to do that baking in, using normal tools (`apt`, `dpkg`, `make install`, etc.).

**Why drop VFS caches after restore?**
When the overlay's upper directory is populated by rsync while the overlay is already mounted, the kernel's dentry cache still holds stale "not found" entries cached from before the files arrived. Dropping caches forces a re-validation so restored files become visible immediately.

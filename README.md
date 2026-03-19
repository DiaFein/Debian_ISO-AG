# Debian Worktop ISO Builder
### `Debian-toram-v3.sh` — Version 3 (Stable)

A single-script builder that produces a minimal **Debian Trixie (13)** GNOME Live ISO with:
- **Toram mode** — the entire squashfs is loaded into RAM at boot for maximum I/O performance
- **Encrypted persistence** — your overlay changes survive reboots via a LUKS2-encrypted partition
- **Fast clone installer** — installs the live system to a real disk in minutes using `unsquashfs`
- **Self-updating** — `update-worktop` regenerates the squashfs and GRUB entries in-place

---

## Requirements

### Host System
Run on a **Debian/Ubuntu host** with the following packages installed:

```bash
sudo apt install mmdebstrap xorriso squashfs-tools mtools \
     grub-efi-amd64-bin grub-pc-bin dosfstools isolinux syslinux-common
```

### Hardware (Target Machine)
| Component | Minimum | Recommended |
|-----------|---------|-------------|
| RAM | 4 GB | 8 GB+ (squashfs is ~1.3 GB loaded into RAM) |
| Disk | 25 GB | 40 GB+ |
| Boot | UEFI or Legacy BIOS | UEFI |
| Architecture | x86_64 | x86_64 |

---

## Building the ISO

```bash
sudo bash Debian-toram-v3.sh
```

The build takes 10–30 minutes depending on your internet speed and CPU. The finished ISO is written to:

```
./worktop-build/debian-worktop-13-live.iso
```

Write it to a USB drive:

```bash
sudo dd if=./worktop-build/debian-worktop-13-live.iso of=/dev/sdX bs=4M status=progress && sync
```

---

## Disk Layout (After Install)

`install-worktop` creates four GPT partitions automatically:

```
┌──────────────┬─────────────────┬──────────┬──────────┐
│  Partition   │  Label          │  Size    │  Use     │
├──────────────┼─────────────────┼──────────┼──────────┤
│  /dev/sdX1   │  ESP (FAT32)    │  512 MiB │  EFI     │
│  /dev/sdX2   │  WORKTOP_BOOT   │  ~4 GB   │  /boot   │
│  /dev/sdX3   │  WORKTOP_ROOT   │  Custom  │  /       │
│  /dev/sdX4   │  PERSIST        │  Rest    │  LUKS2   │
└──────────────┴─────────────────┴──────────┴──────────┘
```

The PERSIST partition (`/dev/sdX4`) is encrypted with **LUKS2** and formatted ext4 inside.
It is managed entirely by `worktop-sync.service` — never mounted automatically at boot via crypttab.

---

## Installing to Disk

Boot the live ISO, open a terminal, and run:

```bash
sudo install-worktop
```

You will be prompted for:
1. Target disk (e.g. `/dev/sda`)
2. Confirmation (`YES` to proceed — **erases all data**)
3. Root partition size in GB (default: 20)
4. A LUKS passphrase for the PERSIST partition (set twice)

> **NVMe disks** (`/dev/nvme0n1` etc.) are detected automatically and partition names are suffixed with `p1`, `p2`, etc.

---

## Boot Modes

After installation, GRUB offers two entries:

### 1. Debian Worktop (TORAM LIVE) ← Use this for daily use
The squashfs is loaded into RAM. Persistence is **active** — the sync engine unlocks the LUKS
partition and restores your overlay on boot, and saves it on shutdown/reboot.

### 2. Standard Debian Root Boot
Boots directly into the installed root filesystem. Fast and stable but **persistence is disabled**
— the overlay sync engine does not run without a live environment.

> Always use the **TORAM LIVE** entry for day-to-day use if you want changes to persist.

---

## How Persistence Works

```
Boot
 └─ worktop-sync.service starts
     └─ Prompts for LUKS passphrase on /dev/console
     └─ Unlocks PERSIST → mounts to /mnt/worktop-persist
     └─ rsync: /mnt/worktop-persist/upper/ → live overlay (rw/)
     └─ Display manager starts

Running
 └─ worktop-sync-periodic.timer fires every 5 minutes
     └─ rsync: live overlay (rw/) → /mnt/worktop-persist/upper/

Shutdown / Reboot
 └─ worktop-sync.service stops
     └─ Final rsync: live overlay → /mnt/worktop-persist/upper/
     └─ umount /mnt/worktop-persist
     └─ cryptsetup luksClose worktop-persist  ← clean LUKS teardown
```

The overlay path (`rw/` directory) is captured into `/run/worktop-overlay-path` at restore time
so the save path can find it even if the overlay has already been torn down by live-boot during reboot.

---

## Updating the System

While booted into the TORAM LIVE entry, run:

```bash
sudo update-worktop
```

This will:
1. Prompt for your LUKS passphrase to wipe the old persistent overlay (prevents stale-overlay conflicts)
2. Rebuild `filesystem.squashfs` from the live root using zstd compression
3. Copy the new kernel and initrd into `/boot/live/kernels/`
4. Regenerate GRUB entries via `/etc/grub.d/41_worktop`
5. Run `update-grub`

After reboot the new squashfs is loaded into RAM from the updated boot partition.

---

## Default Credentials

| Account | Password |
|---------|----------|
| `ebram` (live user) | `worktop` |
| `root` | `worktop` |

> Change these immediately after installation with `passwd`.

---

## Included Software

| Category | Package |
|----------|---------|
| Desktop | GNOME Core, GNOME Terminal |
| Browser | Firefox ESR |
| Disk tools | parted, cryptsetup |
| Utilities | rsync, curl, wget, vim, sudo |
| Live system | live-boot, live-config, live-config-systemd |
| Bootloader | grub-efi-amd64, grub-pc |

---

## Troubleshooting

### LUKS password rejected at boot console
Caused by the raw kernel console sending `CR+LF` instead of `LF` on Enter. The script uses
`stty sane` before reading and strips residual `\r` from the password string. If this still
occurs, verify the ISO was rebuilt from **v3** of the script.

### Screen stuck at `=== Worktop Persistence ===`
The LUKS prompt is waiting for keyboard input. Type your passphrase and press Enter.
Characters will not be echoed — that is expected, echo is disabled during password entry.

### System hangs at LUKS prompt on boot (not the Worktop prompt)
You have an old installation where `/etc/crypttab` contains `luks` without `noauto`.
This causes systemd-cryptsetup to attempt a second unlock at initramfs stage.
Fix it in a recovery shell:

```bash
# chroot into installed root, then:
sed -i 's/none luks,/none luks,noauto,/' /etc/crypttab
update-initramfs -u
```

### Changes not saved after reboot
Confirm you are booting the **TORAM LIVE** GRUB entry — the standard root boot does not
activate the sync engine. Check service status in the live session:

```bash
systemctl status worktop-sync.service
journalctl -u worktop-sync.service
```

### `install-worktop` fails with "Cannot find filesystem.squashfs"
The installer looks for the squashfs on the live medium at `/run/live/medium/live/`.
Ensure you booted from the correct ISO and the USB is still mounted.

---

## File Reference

| Path | Description |
|------|-------------|
| `/usr/local/bin/install-worktop` | Fast clone installer |
| `/usr/local/bin/update-worktop` | Rebuilds squashfs + GRUB entries |
| `/usr/local/bin/worktop-sync-engine` | Overlay ↔ PERSIST rsync engine |
| `/etc/systemd/system/worktop-sync.service` | Restore on boot / save on stop |
| `/etc/systemd/system/worktop-sync-periodic.timer` | 5-minute periodic save timer |
| `/etc/grub.d/41_worktop` | GRUB submenu generated by update-worktop |
| `/run/worktop-overlay-path` | Runtime: captured overlay path (tmpfs, not persistent) |
| `/run/worktop-no-sync` | Runtime: flag set by update-worktop to skip final save |
| `/boot/live/filesystem.squashfs` | Squashfs loaded into RAM at boot |
| `/boot/live/kernels/<version>/` | Kernel + initrd per installed kernel version |

---

## Version History

| Version | Changes |
|---------|---------|
| v1 | Initial build — toram ISO, GNOME, installer |
| v2 | Added encrypted LUKS persistence, sync engine, periodic timer |
| v3 (current) | Fixed invisible console password prompt (`stty sane`, `\r` strip); fixed double LUKS unlock at boot (`noauto` in crypttab); fixed reboot race condition (overlay path state file, `Before=umount.target`); added clean LUKS teardown on shutdown/reboot (`ExecStopPost`) |

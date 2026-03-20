#!/bin/bash
# Debian Worktop ISO Builder (Trixie/13) - V23 (Final Boot & Syntax Fix)
# Creates a minimal GNOME Live ISO with 'Toram' High Performance Mode + Installer

set -euo pipefail

# --- Configuration ---
WORK_DIR="$(pwd)/worktop-build"
CHROOT_DIR="${WORK_DIR}/chroot"
IMAGE_DIR="${WORK_DIR}/image"
ISO_NAME="debian-worktop-13-live.iso"
DEBIAN_CODENAME="trixie"
MIRROR="http://deb.debian.org/debian/"
LIVE_USER="ebram"


# --- Cleanup Trap ---
cleanup() {
    echo "Cleaning up mounts..."
    sync
    umount -lf "$CHROOT_DIR/dev" 2>/dev/null || true
    umount -lf "$CHROOT_DIR/proc" 2>/dev/null || true
    umount -lf "$CHROOT_DIR/sys" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

# Check HOST dependencies
DEPENDENCIES=(mmdebstrap xorriso mksquashfs mtools grub-mkstandalone mkfs.vfat truncate)
for cmd in "${DEPENDENCIES[@]}"; do
    if ! command -v "$cmd" &> /dev/null; then
        echo "Error: $cmd is required on your host system."
        exit 1
    fi
done

[[ "$EUID" -ne 0 ]] && { echo "Please run as root."; exit 1; }

echo "=== Starting Debian Worktop ISO Build (V23) ==="
mkdir -p "$WORK_DIR" "$IMAGE_DIR/live" "$IMAGE_DIR/isolinux" "$IMAGE_DIR/boot/grub"

# 1. Bootstrap Debian Trixie
if [ ! -d "$CHROOT_DIR" ]; then
    echo "--> Bootstrapping Debian $DEBIAN_CODENAME..."
    PACKAGES=(
        live-boot live-config live-config-systemd
        systemd-sysv network-manager gnome-core gnome-terminal
        firefox-esr parted cryptsetup rsync curl wget vim sudo
        grub-efi-amd64-bin grub-pc-bin 
        dosfstools mtools squashfs-tools bc file isolinux syslinux-common
    )
    mmdebstrap --include="$(IFS=,; echo "${PACKAGES[*]}")" \
        "$DEBIAN_CODENAME" "$CHROOT_DIR" "$MIRROR"
fi

# 2. Configure Chroot & Install Backports Kernel
echo "--> Configuring Chroot & Kernel..."
mount --bind /dev "$CHROOT_DIR/dev"
mount --bind /proc "$CHROOT_DIR/proc"
mount --bind /sys "$CHROOT_DIR/sys"

chroot "$CHROOT_DIR" /bin/bash <<EOF
export DEBIAN_FRONTEND=noninteractive
echo "debian-worktop" > /etc/hostname
echo "deb $MIRROR ${DEBIAN_CODENAME}-backports main contrib non-free non-free-firmware" > /etc/apt/sources.list.d/backports.list || true
apt-get update
apt-get install -y -t ${DEBIAN_CODENAME}-backports linux-image-amd64 || apt-get install -y linux-image-amd64
apt-get install -y locales
echo "en_US.UTF-8 UTF-8" > /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/default/locale
echo "root:worktop" | chpasswd
if ! id "$LIVE_USER" &>/dev/null; then
    useradd -m -s /bin/bash "$LIVE_USER"
    echo "${LIVE_USER}:worktop" | chpasswd
    usermod -aG sudo "$LIVE_USER"
fi
mkdir -p /etc/initramfs-tools/conf.d
echo "FORCE_LOAD_MODULES=yes" > /etc/initramfs-tools/conf.d/modules
EOF

# --- 3. Inject Custom Scripts ---

# --- A. Sync Engine ---
cat > "$CHROOT_DIR/usr/local/bin/worktop-sync-engine" << 'SCRIPT'
#!/bin/bash
PERSIST_MOUNT="/mnt/worktop-persist"
LOG() { echo "[worktop-sync] $*" | tee -a /var/log/worktop-sync.log 2>/dev/null || true; }

# On save path (shutdown/reboot), read the overlay path captured at boot-time restore.
# The overlay may already be gone by the time ExecStop runs, so we must not rediscover it.
if [[ "${1:-}" != "--restore" ]] && [[ -f /run/worktop-overlay-path ]]; then
    UPPER_DIR=$(cat /run/worktop-overlay-path)
    LOG "Save path: using captured overlay path: $UPPER_DIR"
else
    # Dynamically detect the real overlayfs upperdir for root filesystem.
    # Debian Trixie live-boot uses overlayfs (upperdir=.../upper), NOT aufs (rw branch).
    # Hardcoding /run/live/overlay/rw is wrong on any modern Debian — always read from mounts.
    UPPER_DIR=$(findmnt -n -o OPTIONS / 2>/dev/null | tr ',' '\n' | grep '^upperdir=' | cut -d= -f2 | head -n1)
    LOG "Restore path: detected overlayfs upperdir: '${UPPER_DIR}'"

    # Fallback: try known live-boot paths in order (overlayfs first, then aufs legacy)
    if [[ -z "$UPPER_DIR" ]] || [[ ! -d "$UPPER_DIR" ]]; then
        for candidate in \
                /run/live/overlay/upper \
                /lib/live/mount/overlay/upper \
                /run/live/overlay/rw \
                /lib/live/mount/overlay/rw; do
            if [[ -d "$candidate" ]]; then
                UPPER_DIR="$candidate"
                LOG "Fallback overlay path: $UPPER_DIR"
                break
            fi
        done
    fi

    if [[ -z "$UPPER_DIR" ]] || [[ ! -d "$UPPER_DIR" ]]; then
        LOG "No live overlay found — not running in toram live mode, exiting."
        exit 0
    fi
fi

# If the overlay directory no longer exists (reboot race), warn and exit gracefully
if [[ ! -d "$UPPER_DIR" ]]; then
    LOG "Overlay directory gone before sync could run — persistence not saved."
    exit 1
fi

if ! mountpoint -q "$PERSIST_MOUNT"; then
    mkdir -p "$PERSIST_MOUNT"
    # Search for GPT partition labeled PERSIST
    PART=$(blkid -t PARTLABEL=PERSIST -o device | grep -v loop | head -n 1)
    if [[ -n "$PART" ]] && cryptsetup isLuks "$PART" 2>/dev/null; then
        if [[ ! -b /dev/mapper/worktop-persist ]]; then
            plymouth quit 2>/dev/null || true
            echo -e "\n\n=== Worktop Persistence ===" > /dev/console

            # Put console into a sane line-discipline so Enter sends LF only, not CR+LF.
            # Without this, bash read captures a trailing \r making every password wrong.
            stty sane < /dev/console 2>/dev/null || true
            stty -echo < /dev/console 2>/dev/null || true

            LUKS_OPENED=0
            for i in {1..3}; do
                echo -n "Enter LUKS Password for Worktop Persist (attempt $i/3): " > /dev/console
                # Read from the service stdin (TTYPath=/dev/console) — not a redirect —
                # so the line discipline set above applies correctly.
                IFS= read -r LUKS_PASS
                echo "" > /dev/console
                # Strip any residual \r that a raw console may still inject
                LUKS_PASS="${LUKS_PASS%$'\r'}"
                if printf '%s' "$LUKS_PASS" | cryptsetup luksOpen "$PART" worktop-persist -d - 2>/dev/null; then
                    LUKS_OPENED=1
                    break
                fi
                echo "Incorrect password, please try again." > /dev/console
            done
            # Restore echo before releasing console
            stty echo < /dev/console 2>/dev/null || true
            unset LUKS_PASS
            [[ $LUKS_OPENED -eq 0 ]] && echo "Failed to unlock persistence after 3 attempts." > /dev/console
        fi
        [[ -b /dev/mapper/worktop-persist ]] && mount /dev/mapper/worktop-persist "$PERSIST_MOUNT"
    fi
    # Fallback to unencrypted
    if ! mountpoint -q "$PERSIST_MOUNT"; then
        UNENC=$(blkid -L WORKTOP_PERSIST | grep -v loop | head -n 1)
        [[ -n "$UNENC" ]] && mount "$UNENC" "$PERSIST_MOUNT"
    fi
fi

if ! mountpoint -q "$PERSIST_MOUNT"; then
    echo "No persistence partition unlocked or found."
    exit 0
fi

if [[ "${1:-}" == "--restore" ]]; then
    # Capture overlay path now while guaranteed to exist — save path reads this on shutdown/reboot
    echo "$UPPER_DIR" > /run/worktop-overlay-path
    if [[ -d "${PERSIST_MOUNT}/upper" ]]; then
        LOG "Restoring overlay from PERSIST/upper/ → $UPPER_DIR ..."
        rsync -aAX "${PERSIST_MOUNT}/upper/" "$UPPER_DIR/" \
            && LOG "Restore complete." \
            || LOG "WARNING: restore rsync exited with error $?"
    else
        LOG "No saved overlay data found — first boot after install."
    fi
    exit 0
fi

if [[ -f /run/worktop-no-sync ]]; then
    echo "Update detected: Skipping sync and wiping overlay to prevent conflicts."
    [[ -d "${PERSIST_MOUNT}/upper" ]] && rm -rf "${PERSIST_MOUNT}/upper"/*
    exit 0
fi

LOG "Saving overlay $UPPER_DIR → PERSIST/upper/ ..."
mkdir -p "${PERSIST_MOUNT}/upper"
# Use /tmp for lock — /run may be teardown-only during shutdown
flock -w 300 /tmp/worktop-sync.lock \
    rsync -aAX --delete \
        --exclude='/tmp/*' \
        --exclude='/var/tmp/*' \
        --exclude='/run/*' \
        --exclude='/proc/*' \
        --exclude='/sys/*' \
        --exclude='/dev/*' \
        --exclude='/mnt/*' \
        --exclude='/media/*' \
        --exclude='/live/*' \
        "$UPPER_DIR/" "${PERSIST_MOUNT}/upper/" \
    && LOG "Save complete." \
    || LOG "WARNING: save rsync exited with error $?"
sync
SCRIPT
chmod +x "$CHROOT_DIR/usr/local/bin/worktop-sync-engine"

# Create Systemd Service for Sync Engine
cat > "$CHROOT_DIR/etc/systemd/system/worktop-sync.service" << 'EOF'
[Unit]
Description=Worktop Sync Engine (Toram Persistence)
Requires=local-fs.target
After=local-fs.target
Before=display-manager.service
# Ensure ExecStop (save) completes before systemd begins shutdown/reboot/unmount sequence.
# Before= is correct here; Conflicts= would race against shutdown, not sequence before it.
Before=shutdown.target reboot.target halt.target umount.target
DefaultDependencies=no

[Service]
Type=oneshot
RemainAfterExit=yes
StandardInput=tty
TTYPath=/dev/console
TTYReset=yes
TTYVHangup=yes
ExecStart=/usr/local/bin/worktop-sync-engine --restore
ExecStop=/usr/local/bin/worktop-sync-engine
# Clean LUKS teardown after save completes (prevents dirty fs on next boot)
ExecStopPost=/bin/sh -c 'umount /mnt/worktop-persist 2>/dev/null || true; cryptsetup luksClose worktop-persist 2>/dev/null || true'
TimeoutStopSec=300

[Install]
WantedBy=multi-user.target
EOF
chroot "$CHROOT_DIR" systemctl enable worktop-sync.service

# Create Systemd Timer for periodic 5-minute syncs
cat > "$CHROOT_DIR/etc/systemd/system/worktop-sync-periodic.service" << 'EOF'
[Unit]
Description=Worktop Periodic Sync (Toram Persistence)
After=worktop-sync.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/worktop-sync-engine
EOF

cat > "$CHROOT_DIR/etc/systemd/system/worktop-sync-periodic.timer" << 'EOF'
[Unit]
Description=Run Worktop Sync Every 5 Minutes

[Timer]
OnBootSec=5min
OnUnitActiveSec=5min

[Install]
WantedBy=timers.target
EOF
chroot "$CHROOT_DIR" systemctl enable worktop-sync-periodic.timer

# --- B. Update-Toram ---
cat > "$CHROOT_DIR/usr/local/bin/update-worktop" << 'SCRIPT'
#!/bin/bash
set -euo pipefail

if ! mountpoint -q /boot; then
    echo "--> Mounting /boot..."
    BOOT_PART=$(blkid -L WORKTOP_BOOT | head -n 1)
    if [[ -n "$BOOT_PART" ]]; then
        mount "$BOOT_PART" /boot
    fi
fi

LIVE_DIR="/boot/live"; KERNELS_DIR="$LIVE_DIR/kernels"
mkdir -p "$KERNELS_DIR"
echo "--> Regenerating Toram Image (ZSTD, All Cores)..."
mksquashfs / "$LIVE_DIR/filesystem.squashfs.tmp" -comp zstd -Xcompression-level 3 -b 1M -noappend -processors $(nproc) \
    -e dev proc sys run tmp mnt media boot/live var/cache/apt/archives var/tmp lost+found
mv -f "$LIVE_DIR/filesystem.squashfs.tmp" "$LIVE_DIR/filesystem.squashfs"

# Drop the no-sync flag for the current session (if live) so that shutdown wipes the overlay
touch /run/worktop-no-sync

# If we are NOT heavily utilizing the RAM overlay (i.e. running from the base system),
# proactively wipe the persistence partition now to prevent stale overlays.
if [[ ! -d /run/live/overlay/rw ]]; then
    echo "--> Clearing old persistent overlay to prevent system conflicts..."
    TEMP_MNT=$(mktemp -d)
    PART=$(blkid -t PARTLABEL=PERSIST -o device | grep -v loop | head -n 1)
    if [[ -n "$PART" ]] && cryptsetup isLuks "$PART" 2>/dev/null; then
        if [[ ! -b /dev/mapper/worktop-persist-update ]]; then
            systemd-ask-password "Enter LUKS Password to wipe old persistence layer:" | cryptsetup luksOpen "$PART" worktop-persist-update || true
        fi
        if [[ -b /dev/mapper/worktop-persist-update ]]; then
            mount /dev/mapper/worktop-persist-update "$TEMP_MNT"
            [[ -d "${TEMP_MNT}/upper" ]] && rm -rf "${TEMP_MNT}/upper"/*
            umount "$TEMP_MNT"
            cryptsetup luksClose worktop-persist-update
        fi
    else
        UNENC=$(blkid -L WORKTOP_PERSIST | grep -v loop | head -n 1)
        if [[ -n "$UNENC" ]]; then
            mount "$UNENC" "$TEMP_MNT"
            [[ -d "${TEMP_MNT}/upper" ]] && rm -rf "${TEMP_MNT}/upper"/*
            umount "$TEMP_MNT"
        fi
    fi
    rm -rf "$TEMP_MNT"
fi

rm -rf "$KERNELS_DIR"/*
KERNEL_FOUND=0
TMP_GRUB="/tmp/41_worktop_entries"
> "$TMP_GRUB"

for kernel in /boot/vmlinuz-*; do
    [[ -e "$kernel" ]] || continue
    version=$(basename "$kernel" | sed 's/vmlinuz-//'); initrd="/boot/initrd.img-$version"
    if [[ -f "$initrd" ]]; then
        echo "    Adding Kernel: $version"
        mkdir -p "$KERNELS_DIR/$version"; cp "$kernel" "$KERNELS_DIR/$version/vmlinuz"; cp "$initrd" "$KERNELS_DIR/$version/initrd.img"
        cat >> "$TMP_GRUB" << GRUB_ENTRY
    menuentry "Toram Live - Kernel $version" {
        search --no-floppy --file --set=root /live/kernels/$version/vmlinuz
        linux /live/kernels/$version/vmlinuz boot=live toram live-media-path=/live ignore_uuid quiet splash
        initrd /live/kernels/$version/initrd.img
    }
GRUB_ENTRY
        KERNEL_FOUND=1
    fi
done

cat > /etc/grub.d/41_worktop << 'GRUB_HEADER'
#!/bin/sh
exec tail -n +3 $0
GRUB_HEADER

if [[ $KERNEL_FOUND -eq 1 ]]; then
    echo "submenu 'Debian Worktop (TORAM LIVE)' --class debian {" >> /etc/grub.d/41_worktop
    cat "$TMP_GRUB" >> /etc/grub.d/41_worktop
    echo "}" >> /etc/grub.d/41_worktop
fi
chmod +x /etc/grub.d/41_worktop
rm -f "$TMP_GRUB"
if [[ -x /usr/sbin/update-grub ]]; then
    /usr/sbin/update-grub || echo "Warning: update-grub failed, check /etc/grub.d/41_worktop"
fi
SCRIPT
chmod +x "$CHROOT_DIR/usr/local/bin/update-worktop"

# --- C. Fast Clone Installer ---
cat > "$CHROOT_DIR/usr/local/bin/install-worktop" << 'SCRIPT'
#!/bin/bash
set -euo pipefail
echo "=== Debian Worktop Fast Clone Installer ==="
lsblk
read -p "Enter target disk (e.g., /dev/sda): " DISK
[[ ! -b "$DISK" ]] && { echo "Invalid disk."; exit 1; }
read -p "Type 'YES' to confirm (ERASES ALL DATA): " CONFIRM
[[ "$CONFIRM" != "YES" ]] && exit 1

SQUASHFS_SRC="/run/live/medium/live/filesystem.squashfs"
[[ ! -f "$SQUASHFS_SRC" ]] && SQUASHFS_SRC=$(find /run/live -name "filesystem.squashfs" | head -n 1)
[[ -z "$SQUASHFS_SRC" ]] && { echo "Error: Cannot find filesystem.squashfs on Live media."; exit 1; }

read -p "Enter size for Root Partition in GB (default: 20): " ROOT_SIZE_GB
ROOT_SIZE_GB=${ROOT_SIZE_GB:-20}
ROOT_END=$((4609 + (ROOT_SIZE_GB * 1024)))

echo "--> Partitioning..."
parted -s "$DISK" mklabel gpt
parted -s "$DISK" mkpart ESP fat32 1MiB 513MiB
parted -s "$DISK" set 1 esp on
parted -s "$DISK" mkpart BOOT ext4 513MiB 4609MiB
parted -s "$DISK" mkpart ROOT ext4 4609MiB ${ROOT_END}MiB
parted -s "$DISK" mkpart PERSIST ${ROOT_END}MiB 100%
partprobe "$DISK"; sleep 2

EFI_PART="${DISK}1"; BOOT_PART="${DISK}2"; ROOT_PART="${DISK}3"; PERSIST_PART="${DISK}4"
[[ "$DISK" == *"nvme"* ]] && { EFI_PART="${DISK}p1"; BOOT_PART="${DISK}p2"; ROOT_PART="${DISK}p3"; PERSIST_PART="${DISK}p4"; }

mkfs.vfat -F32 "$EFI_PART"; mkfs.ext4 -L WORKTOP_BOOT "$BOOT_PART"; mkfs.ext4 -L WORKTOP_ROOT "$ROOT_PART"
echo "Setting up Encryption for Persistence..."
cryptsetup luksFormat --type luks2 "$PERSIST_PART"
cryptsetup luksOpen "$PERSIST_PART" worktop-persist
mkfs.ext4 -L WORKTOP_PERSIST /dev/mapper/worktop-persist

mount "$ROOT_PART" /mnt; mkdir -p /mnt/boot; mount "$BOOT_PART" /mnt/boot; mkdir -p /mnt/boot/efi; mount "$EFI_PART" /mnt/boot/efi

echo "--> Cloning Base System..."
unsquashfs -dest /mnt -force -processors $(nproc) "$SQUASHFS_SRC"

echo "--> Setting up Toram Mode files..."
mkdir -p /mnt/boot/live
cp "$SQUASHFS_SRC" /mnt/boot/live/filesystem.squashfs
cp /run/live/medium/live/vmlinuz /mnt/boot/live/vmlinuz 2>/dev/null || cp /live/vmlinuz /mnt/boot/live/vmlinuz
cp /run/live/medium/live/initrd.img /mnt/boot/live/initrd.img 2>/dev/null || cp /live/initrd.img /mnt/boot/live/initrd.img

ROOT_UUID=$(blkid -s UUID -o value "$ROOT_PART"); BOOT_UUID=$(blkid -s UUID -o value "$BOOT_PART"); EFI_UUID=$(blkid -s UUID -o value "$EFI_PART"); PERSIST_UUID=$(blkid -s UUID -o value "$PERSIST_PART")
cat > /mnt/etc/fstab <<FSTAB
UUID=$ROOT_UUID  /       ext4    errors=remount-ro 0 1
UUID=$BOOT_UUID /boot   ext4    defaults        0 2
UUID=$EFI_UUID  /boot/efi vfat  umask=0077      0 1
FSTAB
# noauto: let worktop-sync.service handle unlock; prevents double-prompt at initramfs stage
echo "worktop-persist UUID=$PERSIST_UUID none luks,noauto,discard" > /mnt/etc/crypttab

mount --bind /dev /mnt/dev; mount --bind /proc /mnt/proc; mount --bind /sys /mnt/sys; mount --bind /run /mnt/run

if [[ -d /sys/firmware/efi ]]; then
    echo "--> Installing UEFI GRUB..."
    # CRITICAL: Mount efivarfs for UEFI registration
    mount -t efivarfs efivarfs /mnt/sys/firmware/efi/efivars 2>/dev/null || true
    chroot /mnt /usr/bin/env PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" apt-get update
    chroot /mnt /usr/bin/env PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" apt-get install -y grub-efi-amd64
    chroot /mnt /usr/bin/env PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" /usr/sbin/grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=Debian
else
    echo "--> Installing Legacy BIOS GRUB..."
    chroot /mnt /usr/bin/env PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" apt-get update
    chroot /mnt /usr/bin/env PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" apt-get install -y grub-pc
    chroot /mnt /usr/bin/env PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" /usr/sbin/grub-install "$DISK"
fi

chroot /mnt /usr/bin/env PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" /usr/local/bin/update-worktop
umount -R /mnt; cryptsetup luksClose worktop-persist
echo ""
echo "=== Installation Complete! ==="
echo ""
echo "IMPORTANT: Persistence (overlay sync) only works when booting via the"
echo "  'Debian Worktop (TORAM LIVE)' submenu in GRUB."
echo "  A direct root boot will NOT use the sync engine or restore your overlay."
echo ""
SCRIPT
chmod +x "$CHROOT_DIR/usr/local/bin/install-worktop"

# --- 4. Build ISO Image ---
cleanup
echo "--> Building SquashFS (ISO)..."
mksquashfs "$CHROOT_DIR" "$IMAGE_DIR/live/filesystem.squashfs" -comp zstd -Xcompression-level 1 -b 1M -processors $(nproc) -noappend -e boot/live var/cache/apt/archives

echo "--> Copying Kernel & Initrd to ISO..."
NEWEST_KERNEL=$(ls -v "$CHROOT_DIR/boot/vmlinuz-"* | tail -n 1 || true)
NEWEST_INITRD=$(ls -v "$CHROOT_DIR/boot/initrd.img-"* | tail -n 1 || true)
[[ -z "$NEWEST_KERNEL" || ! -f "$NEWEST_KERNEL" ]] && { echo "FATAL: No kernel found!"; exit 1; }
cp "$NEWEST_KERNEL" "$IMAGE_DIR/live/vmlinuz"
cp "$NEWEST_INITRD" "$IMAGE_DIR/live/initrd.img"

echo "--> Preparing Bootloaders..."
cp /usr/lib/ISOLINUX/isolinux.bin "$IMAGE_DIR/isolinux/"
cp /usr/lib/syslinux/modules/bios/* "$IMAGE_DIR/isolinux/" 2>/dev/null || cp /usr/lib/syslinux/bios/* "$IMAGE_DIR/isolinux/"
cat > "$IMAGE_DIR/isolinux/isolinux.cfg" <<EOF
default live
label live
  kernel /live/vmlinuz
  append initrd=/live/initrd.img boot=live components live-media-path=/live ignore_uuid toram bootdelay=5 quiet splash
EOF

cat > "$WORK_DIR/grub-early.cfg" <<EOF
insmod iso9660
insmod linux
insmod search_fs_file
if search --no-floppy --file --set=root /live/vmlinuz; then
    set prefix=(\$root)/boot/grub
    linux (\$root)/live/vmlinuz boot=live components live-media-path=/live ignore_uuid toram bootdelay=5 quiet splash
    initrd (\$root)/live/initrd.img
    boot
fi
EOF

mkdir -p "$IMAGE_DIR/EFI/BOOT"
GRUB_MODULES="part_gpt part_msdos fat iso9660 search search_fs_file search_label search_fs_uuid echo normal configfile all_video sleep linux ext2"
grub-mkstandalone -O x86_64-efi --modules="$GRUB_MODULES" -o "$IMAGE_DIR/EFI/BOOT/BOOTX64.EFI" "boot/grub/grub.cfg=$WORK_DIR/grub-early.cfg"

truncate -s 32M "$WORK_DIR/efiboot.img"
mkfs.vfat "$WORK_DIR/efiboot.img"
mmd -i "$WORK_DIR/efiboot.img" ::/EFI ::/EFI/BOOT
mcopy -i "$WORK_DIR/efiboot.img" "$IMAGE_DIR/EFI/BOOT/BOOTX64.EFI" ::/EFI/BOOT/BOOTX64.EFI
cp "$WORK_DIR/efiboot.img" "$IMAGE_DIR/efiboot.img"

ISOHDPFX="/usr/lib/ISOLINUX/isohdpfx.bin"
[[ ! -f "$ISOHDPFX" ]] && ISOHDPFX="/usr/lib/syslinux/isohdpfx.bin"
xorriso -as mkisofs -iso-level 3 -full-iso9660-filenames -volid "WORKTOP_LIVE" -eltorito-boot isolinux/isolinux.bin -eltorito-catalog isolinux/boot.cat -no-emul-boot -boot-load-size 4 -boot-info-table -isohybrid-mbr "$ISOHDPFX" -eltorito-alt-boot -e efiboot.img -no-emul-boot -isohybrid-gpt-basdat -append_partition 2 0xef "$WORK_DIR/efiboot.img" -output "$WORK_DIR/$ISO_NAME" "$IMAGE_DIR"

echo "=== Build Complete: $WORK_DIR/$ISO_NAME ==="

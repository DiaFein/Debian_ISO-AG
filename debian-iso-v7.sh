#!/bin/bash
# Debian Worktop ISO Builder (Trixie/13) - V5.2
# Creates a minimal GNOME Live ISO with:
#   - Toram mode: squashfs loaded into RAM at boot
#   - Native live-boot encrypted persistence (LUKS2 + persistence.conf)
#   - Fast clone installer (install-worktop)
#   - Live system updater (update-worktop)
#   - Base system is the source of truth for the Live-toram system.

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

echo "=== Starting Debian Worktop ISO Build (V5.2) ==="
mkdir -p "$WORK_DIR" "$IMAGE_DIR/live" "$IMAGE_DIR/isolinux" "$IMAGE_DIR/boot/grub"

# =============================================================================
# 1. Bootstrap Debian Trixie
# =============================================================================
if [ ! -d "$CHROOT_DIR" ]; then
    echo "--> Bootstrapping Debian $DEBIAN_CODENAME..."
    # removed zram-tools
    PACKAGES=(
        live-boot live-config live-config-systemd
        systemd-sysv network-manager gnome-core gnome-terminal
        firefox-esr parted cryptsetup cryptsetup-initramfs rsync curl wget vim sudo
        grub-efi-amd64-bin grub-pc-bin
        dosfstools mtools squashfs-tools bc file isolinux syslinux-common zstd
    )
    mmdebstrap --include="$(IFS=,; echo "${PACKAGES[*]}")" \
        "$DEBIAN_CODENAME" "$CHROOT_DIR" "$MIRROR"
fi

# =============================================================================
# 2. Configure Chroot & Install Backports Kernel
# =============================================================================
echo "--> Configuring Chroot & Kernel..."
mount --bind /dev "$CHROOT_DIR/dev"
mount --bind /proc "$CHROOT_DIR/proc"
mount --bind /sys "$CHROOT_DIR/sys"

chroot "$CHROOT_DIR" /bin/bash <<EOF
export DEBIAN_FRONTEND=noninteractive
echo "debian-worktop" > /etc/hostname
echo "deb $MIRROR ${DEBIAN_CODENAME}-backports main contrib non-free non-free-firmware" \
    > /etc/apt/sources.list.d/backports.list || true
apt-get update
apt-get install -y -t ${DEBIAN_CODENAME}-backports linux-image-amd64 \
    || apt-get install -y linux-image-amd64
apt-get install -y locales
update-initramfs -u
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

# =============================================================================
# 3. Inject Custom Scripts
# =============================================================================

# --- A. update-worktop ---
# Rebuilds the squashfs from the running system (live or installed).
# Captures ALL Kernels, Apps, Settings (etc), and User Data (home).
cat > "$CHROOT_DIR/usr/local/bin/update-worktop" << 'SCRIPT'
#!/bin/bash
set -euo pipefail

[[ "$EUID" -ne 0 ]] && { echo "Please run as root."; exit 1; }

# Environment Detection
IS_LIVE=0
if grep -q "boot=live" /proc/cmdline 2>/dev/null; then
    IS_LIVE=1
    echo "--> Environment: Live Mode"
else
    echo "--> Environment: Installed Mode (Base System)"
fi

# Find and mount WORKTOP_BOOT if not already mounted at /boot
if ! mountpoint -q /boot; then
    echo "--> Mounting /boot (WORKTOP_BOOT)..."
    BOOT_PART=$(blkid -L WORKTOP_BOOT -o device | head -n 1)
    [[ -z "$BOOT_PART" ]] && { echo "ERROR: Cannot find WORKTOP_BOOT partition."; exit 1; }
    mount "$BOOT_PART" /boot
fi

LIVE_DIR="/boot/live"
KERNELS_DIR="$LIVE_DIR/kernels"
mkdir -p "$KERNELS_DIR"

# --- Step 0: Ensure system state is synced ---
if [[ $IS_LIVE -eq 0 ]]; then
    echo "--> Ensuring initramfs is updated for all kernels (Base System)..."
    update-initramfs -u -k all || true
fi

# --- Step 1: Rebuild squashfs from current root ---
echo "--> Capturing entire system state into SquashFS (Apps, Settings, Home)..."
# Exclude only what's absolutely necessary.
# If on base system, /boot/live is where we write, so exclude it.
EXCLUDES=(
    "dev/*" "proc/*" "sys/*" "run/*" "tmp/*" "mnt/*" "media/*"
    "boot/live/*" "boot/efi/*" "lib/live/mount/*"
    "var/cache/apt/archives/*" "var/lib/apt/lists/*"
    "var/tmp/*" "**/worktop-build"
)

EXCLUDE_FILE=$(mktemp)
printf "%s\n" "${EXCLUDES[@]}" > "$EXCLUDE_FILE"

mksquashfs / "$LIVE_DIR/filesystem.squashfs.tmp" \
    -comp zstd -Xcompression-level 3 -b 1M -noappend -processors "$(nproc)" \
    -wildcards -ef "$EXCLUDE_FILE" \
    || { echo "ERROR: mksquashfs failed."; rm -f "$EXCLUDE_FILE"; exit 1; }

rm -f "$EXCLUDE_FILE"
mv -f "$LIVE_DIR/filesystem.squashfs.tmp" "$LIVE_DIR/filesystem.squashfs"
echo "--> Squashfs rebuilt: $(du -sh "$LIVE_DIR/filesystem.squashfs" | cut -f1)"

# --- Step 2: Sync ALL kernels and update GRUB ---
echo "--> Syncing kernels and updating GRUB snippets..."
rm -rf "${KERNELS_DIR:?}"/*
KERNEL_FOUND=0
TMP_GRUB=$(mktemp)

for kernel in /boot/vmlinuz-*; do
    [[ -e "$kernel" ]] || continue
    version=$(basename "$kernel" | sed 's/vmlinuz-//')
    initrd="/boot/initrd.img-$version"
    [[ -f "$initrd" ]] || continue
    echo "    Syncing kernel: $version"
    mkdir -p "$KERNELS_DIR/$version"
    cp "$kernel" "$KERNELS_DIR/$version/vmlinuz"
    cp "$initrd" "$KERNELS_DIR/$version/initrd.img"
    cat >> "$TMP_GRUB" << EOF
    menuentry "Toram Live - Kernel $version" {
        search --no-floppy --file --set=root /live/kernels/$version/vmlinuz
        linux  /live/kernels/$version/vmlinuz \
               boot=live toram live-media-path=/live ignore_uuid \
               persistence persistence-encryption=luks \
               quiet splash
        initrd /live/kernels/$version/initrd.img
    }
EOF
    KERNEL_FOUND=1
done

if [[ $KERNEL_FOUND -eq 1 ]]; then
    # Update default live kernels to the newest
    NEWEST_VMLINUZ=$(ls -v /boot/vmlinuz-* | tail -n 1)
    NEWEST_INITRD=$(ls -v /boot/initrd.img-* | tail -n 1)
    cp "$NEWEST_VMLINUZ" "$LIVE_DIR/vmlinuz"
    cp "$NEWEST_INITRD" "$LIVE_DIR/initrd.img"

    # Write /etc/grub.d/41_worktop
    {
        echo "#!/bin/sh"
        echo "exec tail -n +3 \$0"
        echo "submenu 'Debian Worktop (TORAM LIVE)' --class debian {"
        cat "$TMP_GRUB"
        echo "}"
    } > /etc/grub.d/41_worktop
    chmod +x /etc/grub.d/41_worktop
    if command -v update-grub &>/dev/null; then update-grub; fi
fi
rm -f "$TMP_GRUB"

# --- Step 3: Clear persistence partition ---
clear_persistence() {
    local mnt="$1"
    echo "    Clearing persistence content at $mnt..."
    # Keep persistence.conf, delete everything else
    find "$mnt" -mindepth 1 ! -name "persistence.conf" -delete
    echo "/ union" > "$mnt/persistence.conf"
    sync
}

if [[ $IS_LIVE -eq 1 ]]; then
    echo "--> Clearing Live persistence partition (Live Mode)..."
    PERSIST_MNT=$(findmnt -n -o TARGET -L persistence 2>/dev/null || echo "")
    if [[ -n "$PERSIST_MNT" ]]; then
        clear_persistence "$PERSIST_MNT"
    else
        echo "    WARNING: Persistence partition not found/mounted."
    fi
else
    echo "--> Checking for Live persistence partition (Installed Mode)..."
    # Search by label ( GPT PARTLABEL )
    PERSIST_PART=$(blkid -t PARTLABEL=PERSIST -o device | head -n 1 || true)
    if [[ -z "$PERSIST_PART" ]]; then
        # Fallback to partition 4 of the boot disk
        BOOT_DEV=$(findmnt -n -o SOURCE /boot | sed 's/[0-9]*$//; s/p[0-9]*$//')
        [[ -b "${BOOT_DEV}4" ]] && PERSIST_PART="${BOOT_DEV}4"
        [[ -b "${BOOT_DEV}p4" ]] && PERSIST_PART="${BOOT_DEV}p4"
    fi

    if [[ -n "$PERSIST_PART" ]] && [[ -b "$PERSIST_PART" ]]; then
        echo "    Persistence partition detected: $PERSIST_PART"
        printf "Clear Live persistence partition to ensure clean update? (y/N): "
        read -r CLEAR_P </dev/tty || CLEAR_P="n"
        
        if [[ "$CLEAR_P" =~ ^[Yy]$ ]]; then
            TMP_MNT=$(mktemp -d)
            if cryptsetup isLuks "$PERSIST_PART" 2>/dev/null; then
                echo "    Unlocking LUKS persistence partition..."
                # Try to unlock. Might ask for password.
                cryptsetup luksOpen "$PERSIST_PART" worktop-update-persist </dev/tty
                mount /dev/mapper/worktop-update-persist "$TMP_MNT"
                clear_persistence "$TMP_MNT"
                umount "$TMP_MNT"
                cryptsetup luksClose worktop-update-persist
            else
                mount "$PERSIST_PART" "$TMP_MNT"
                clear_persistence "$TMP_MNT"
                umount "$TMP_MNT"
            fi
            rm -rf "$TMP_MNT"
            echo "    Persistence partition cleared."
        fi
    fi
fi

echo "=== update-worktop complete ==="
SCRIPT
chmod +x "$CHROOT_DIR/usr/local/bin/update-worktop"

# --- B. install-worktop ---
cat > "$CHROOT_DIR/usr/local/bin/install-worktop" << 'SCRIPT'
#!/bin/bash
set -euo pipefail
echo "=== Debian Worktop Fast Clone Installer ==="
lsblk
read -r -p "Enter target disk (e.g., /dev/sda): " DISK </dev/tty
[[ ! -b "$DISK" ]] && { echo "Invalid disk."; exit 1; }
read -r -p "Type 'YES' to confirm (ERASES ALL DATA on $DISK): " CONFIRM </dev/tty
[[ "$CONFIRM" != "YES" ]] && { echo "Aborted."; exit 1; }

SQUASHFS_SRC="/run/live/medium/live/filesystem.squashfs"
[[ ! -f "$SQUASHFS_SRC" ]] && SQUASHFS_SRC=$(find /run/live -name "filesystem.squashfs" 2>/dev/null | head -n 1)

read -r -p "Root partition size in GB (default: 20): " ROOT_SIZE_GB </dev/tty
ROOT_SIZE_GB=${ROOT_SIZE_GB:-20}
ROOT_END=$((4609 + (ROOT_SIZE_GB * 1024)))

echo "--> Partitioning $DISK..."
parted -s "$DISK" mklabel gpt
parted -s "$DISK" mkpart ESP fat32 1MiB 513MiB
parted -s "$DISK" set 1 esp on
parted -s "$DISK" mkpart WORKTOP_BOOT ext4 513MiB 4609MiB
parted -s "$DISK" mkpart WORKTOP_ROOT ext4 4609MiB "${ROOT_END}MiB"
parted -s "$DISK" mkpart PERSIST ext4 "${ROOT_END}MiB" 100%
# Set PARTLABEL so update-worktop can find it
parted -s "$DISK" name 4 PERSIST
partprobe "$DISK"; sleep 2

if [[ "$DISK" == *"nvme"* ]] || [[ "$DISK" == *"mmcblk"* ]]; then
    EFI_PART="${DISK}p1"; BOOT_PART="${DISK}p2"; ROOT_PART="${DISK}p3"; PERSIST_PART="${DISK}p4"
else
    EFI_PART="${DISK}1"; BOOT_PART="${DISK}2"; ROOT_PART="${DISK}3"; PERSIST_PART="${DISK}4"
fi

echo "--> Formatting system partitions..."
mkfs.vfat -F32 -n EFI "$EFI_PART"
mkfs.ext4 -L WORKTOP_BOOT "$BOOT_PART"
mkfs.ext4 -L WORKTOP_ROOT "$ROOT_PART"

echo "--> Setting up encrypted persistence..."
cryptsetup luksFormat --type luks2 "$PERSIST_PART" </dev/tty
cryptsetup luksOpen "$PERSIST_PART" worktop-persist-setup </dev/tty
mkfs.ext4 -L persistence /dev/mapper/worktop-persist-setup
PERSIST_TMP=$(mktemp -d)
mount /dev/mapper/worktop-persist-setup "$PERSIST_TMP"
echo "/ union" > "$PERSIST_TMP/persistence.conf"
umount "$PERSIST_TMP"
cryptsetup luksClose worktop-persist-setup

echo "--> Cloning system..."
mount "$ROOT_PART" /mnt
mkdir -p /mnt/boot && mount "$BOOT_PART" /mnt/boot
mkdir -p /mnt/boot/efi && mount "$EFI_PART" /mnt/boot/efi
unsquashfs -dest /mnt -force -processors "$(nproc)" "$SQUASHFS_SRC"

mkdir -p /mnt/boot/live
cp "$SQUASHFS_SRC" /mnt/boot/live/filesystem.squashfs
cp /run/live/medium/live/vmlinuz /mnt/boot/live/vmlinuz 2>/dev/null || cp /live/vmlinuz /mnt/boot/live/vmlinuz
cp /run/live/medium/live/initrd.img /mnt/boot/live/initrd.img 2>/dev/null || cp /live/initrd.img /mnt/boot/live/initrd.img

ROOT_UUID=$(blkid -s UUID -o value "$ROOT_PART")
BOOT_UUID=$(blkid -s UUID -o value "$BOOT_PART")
EFI_UUID=$(blkid -s UUID -o value "$EFI_PART")
cat > /mnt/etc/fstab << FSTAB
UUID=$ROOT_UUID / ext4 errors=remount-ro 0 1
UUID=$BOOT_UUID /boot ext4 defaults 0 2
UUID=$EFI_UUID /boot/efi vfat umask=0077 0 1
FSTAB

mount --bind /dev /mnt/dev && mount --bind /proc /mnt/proc && mount --bind /sys /mnt/sys && mount --bind /run /mnt/run
ENV="PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

if [[ -d /sys/firmware/efi ]]; then
    mount -t efivarfs efivarfs /mnt/sys/firmware/efi/efivars 2>/dev/null || true
    chroot /mnt /usr/bin/env "$ENV" apt-get install -y grub-efi-amd64
    chroot /mnt /usr/bin/env "$ENV" grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=Debian
else
    chroot /mnt /usr/bin/env "$ENV" apt-get install -y grub-pc
    chroot /mnt /usr/bin/env "$ENV" grub-install "$DISK"
fi

cat > /mnt/etc/grub.d/41_worktop << 'GRUB_HEADER'
#!/bin/sh
exec tail -n +3 $0
GRUB_HEADER

for kernel in /mnt/boot/vmlinuz-*; do
    [[ -e "$kernel" ]] || continue
    version=$(basename "$kernel" | sed 's/vmlinuz-//')
    initrd="/mnt/boot/initrd.img-$version"
    [[ -f "$initrd" ]] || continue
    mkdir -p "/mnt/boot/live/kernels/$version"
    cp "$kernel" "/mnt/boot/live/kernels/$version/vmlinuz"
    cp "$initrd" "/mnt/boot/live/kernels/$version/initrd.img"
    cat >> /mnt/etc/grub.d/41_worktop << GRUB_ENTRY
    menuentry "Toram Live - Kernel $version" {
        search --no-floppy --file --set=root /live/kernels/$version/vmlinuz
        linux  /live/kernels/$version/vmlinuz \
               boot=live toram live-media-path=/live ignore_uuid \
               persistence persistence-encryption=luks \
               quiet splash
        initrd /live/kernels/$version/initrd.img
    }
GRUB_ENTRY
done

{
    head -n 2 /mnt/etc/grub.d/41_worktop
    echo "submenu 'Debian Worktop (TORAM LIVE)' --class debian {"
    tail -n +3 /mnt/etc/grub.d/41_worktop
    echo "}"
} > /mnt/etc/grub.d/41_worktop.tmp && mv /mnt/etc/grub.d/41_worktop.tmp /mnt/etc/grub.d/41_worktop
chmod +x /mnt/etc/grub.d/41_worktop
chroot /mnt /usr/bin/env "$ENV" update-grub
umount -R /mnt
echo "=== Installation Complete! ==="
SCRIPT
chmod +x "$CHROOT_DIR/usr/local/bin/install-worktop"

# =============================================================================
# 4. Build ISO Image
# =============================================================================
cleanup
echo "--> Building SquashFS (ISO)..."
mksquashfs "$CHROOT_DIR" "$IMAGE_DIR/live/filesystem.squashfs" \
    -comp zstd -Xcompression-level 1 -b 1M -processors "$(nproc)" -noappend \
    -e boot/live var/cache/apt/archives

echo "--> Copying Kernel & Initrd to ISO..."
NEWEST_KERNEL=$(ls -v "$CHROOT_DIR/boot/vmlinuz-"* 2>/dev/null | tail -n 1 || true)
NEWEST_INITRD=$(ls -v "$CHROOT_DIR/boot/initrd.img-"* 2>/dev/null | tail -n 1 || true)
cp "$NEWEST_KERNEL" "$IMAGE_DIR/live/vmlinuz"
cp "$NEWEST_INITRD" "$IMAGE_DIR/live/initrd.img"

echo "--> Preparing Bootloaders..."
cp /usr/lib/ISOLINUX/isolinux.bin "$IMAGE_DIR/isolinux/"
cp /usr/lib/syslinux/modules/bios/* "$IMAGE_DIR/isolinux/" 2>/dev/null || cp /usr/lib/syslinux/bios/* "$IMAGE_DIR/isolinux/"

cat > "$IMAGE_DIR/isolinux/isolinux.cfg" << 'EOF'
default live
label live
  kernel /live/vmlinuz
  append initrd=/live/initrd.img boot=live components live-media-path=/live ignore_uuid \
         toram persistence persistence-encryption=luks \
         bootdelay=5 quiet splash
EOF

cat > "$WORK_DIR/grub-early.cfg" << 'EOF'
insmod iso9660
insmod linux
insmod search_fs_file
if search --no-floppy --file --set=root /live/vmlinuz; then
    set prefix=($root)/boot/grub
    linux  ($root)/live/vmlinuz \
           boot=live components live-media-path=/live ignore_uuid \
           toram persistence persistence-encryption=luks \
           bootdelay=5 quiet splash
    initrd ($root)/live/initrd.img
    boot
fi
EOF

mkdir -p "$IMAGE_DIR/EFI/BOOT"
grub-mkstandalone -O x86_64-efi -o "$IMAGE_DIR/EFI/BOOT/BOOTX64.EFI" "boot/grub/grub.cfg=$WORK_DIR/grub-early.cfg"
truncate -s 32M "$WORK_DIR/efiboot.img"
mkfs.vfat "$WORK_DIR/efiboot.img"
mmd -i "$WORK_DIR/efiboot.img" ::/EFI ::/EFI/BOOT
mcopy -i "$WORK_DIR/efiboot.img" "$IMAGE_DIR/EFI/BOOT/BOOTX64.EFI" ::/EFI/BOOT/BOOTX64.EFI
cp "$WORK_DIR/efiboot.img" "$IMAGE_DIR/efiboot.img"

ISOHDPFX="/usr/lib/ISOLINUX/isohdpfx.bin"
[[ ! -f "$ISOHDPFX" ]] && ISOHDPFX="/usr/lib/syslinux/isohdpfx.bin"

xorriso -as mkisofs -iso-level 3 -full-iso9660-filenames -volid "WORKTOP_LIVE" \
    -eltorito-boot isolinux/isolinux.bin -eltorito-catalog isolinux/boot.cat \
    -no-emul-boot -boot-load-size 4 -boot-info-table -isohybrid-mbr "$ISOHDPFX" \
    -eltorito-alt-boot -e efiboot.img -no-emul-boot -isohybrid-gpt-basdat \
    -append_partition 2 0xef "$WORK_DIR/efiboot.img" -output "$WORK_DIR/$ISO_NAME" "$IMAGE_DIR"

echo "=== Build Complete: $WORK_DIR/$ISO_NAME ==="

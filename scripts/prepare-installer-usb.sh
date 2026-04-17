#!/bin/bash
# ============================================================================
# Prepare a bootable Fedora Server USB installer with kickstart auto-boot.
#
# Usage:
#   sudo bash scripts/prepare-installer-usb.sh <fedora-iso> [ks-label]
#
# Arguments:
#   <fedora-iso>   Path to the Fedora Server ISO file.
#   [ks-label]     Volume label of the USB stick holding ks.cfg.
#                  Default: KSUSB
#
# What it does:
#   1. Finds the USB block device (must be exactly one plugged in).
#   2. Confirms with the user before wiping.
#   3. Flashes the ISO with dd.
#   4. Mounts the EFI partition on the freshly-flashed stick.
#   5. Patches grub.cfg to:
#      - Auto-boot with inst.ks=hd:LABEL=<ks-label>:/ks.cfg
#      - Set a 5-second timeout (no keyboard needed)
#   6. Unmounts and syncs — ready to boot.
#
# Requirements:
#   - Run as root (dd needs raw device access).
#   - Exactly one USB block device plugged in (the target).
#   - A second USB stick labelled <ks-label> with ks.cfg at its root
#     (plug it in at boot time alongside this one).
#
# After this script finishes:
#   1. Plug both sticks into the target machine (installer + kickstart).
#   2. Boot from the installer stick.
#   3. GRUB auto-selects "Install Fedora" after 5 s.
#   4. Anaconda reads ks.cfg from the second stick → unattended install.
#   5. Machine reboots into fresh Fedora (if ks.cfg ends with `reboot`).
# ============================================================================
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
BOLD='\033[1m'
NC='\033[0m'

info() { echo -e "${GREEN}==>${NC} $*"; }
warn() { echo -e "${RED}==>${NC} $*"; }
die()  { warn "$*"; exit 1; }

# --- Argument parsing ---
ISO="${1:-}"
KS_LABEL="${2:-KSUSB}"

if [[ -z "$ISO" ]]; then
    echo "Usage: sudo $0 <fedora-iso> [ks-label]"
    echo "  ks-label defaults to KSUSB"
    exit 1
fi

[[ $EUID -eq 0 ]] || die "Run as root: sudo $0 $*"
[[ -f "$ISO" ]]    || die "ISO file not found: $ISO"

# --- Find the USB device ---
# List all block devices on the usb transport, excluding partitions.
mapfile -t USB_DEVS < <(lsblk -dnpo NAME,TRAN | awk '$2 == "usb" {print $1}')

if [[ ${#USB_DEVS[@]} -eq 0 ]]; then
    die "No USB block devices found. Plug in the target stick and retry."
elif [[ ${#USB_DEVS[@]} -gt 1 ]]; then
    warn "Multiple USB devices found:"
    for d in "${USB_DEVS[@]}"; do
        lsblk -dno NAME,SIZE,MODEL "$d"
    done
    die "Unplug all but the target stick and retry."
fi

USB_DEV="${USB_DEVS[0]}"
USB_SIZE=$(lsblk -dno SIZE "$USB_DEV")
USB_MODEL=$(lsblk -dno MODEL "$USB_DEV" | sed 's/ *$//')

info "Found USB device:"
echo "  Device: $USB_DEV"
echo "  Size:   $USB_SIZE"
echo "  Model:  $USB_MODEL"
echo

# --- Confirm ---
warn "ALL DATA ON ${USB_DEV} WILL BE DESTROYED."
echo -ne "${BOLD}Type 'yes' to continue: ${NC}"
read -r confirm
[[ "$confirm" == "yes" ]] || die "Aborted."

# --- Unmount any mounted partitions ---
info "Unmounting any mounted partitions on ${USB_DEV}..."
for part in "${USB_DEV}"*; do
    mountpoint -q "$part" 2>/dev/null && umount "$part" 2>/dev/null || true
done

# --- Flash the ISO ---
ISO_SIZE=$(stat -c%s "$ISO")
ISO_SIZE_MB=$((ISO_SIZE / 1024 / 1024))
info "Flashing ${ISO_SIZE_MB} MB ISO to ${USB_DEV}..."
dd if="$ISO" of="$USB_DEV" bs=4M status=progress oflag=direct conv=fsync
sync
info "Flash complete."

# --- Wait for kernel to re-read partition table ---
info "Waiting for partitions to appear..."
partprobe "$USB_DEV" 2>/dev/null || true
sleep 3

# --- Find and mount the EFI partition ---
# Fedora ISOs typically have an EFI System Partition with a FAT filesystem.
EFI_PART=""
for part in "${USB_DEV}"*[0-9]; do
    fstype=$(lsblk -no FSTYPE "$part" 2>/dev/null || true)
    parttype=$(lsblk -no PARTTYPE "$part" 2>/dev/null || true)
    # EFI System Partition GUID: C12A7328-F81F-11D2-BA4B-00A0C93EC93B
    if [[ "$fstype" == "vfat" ]] && [[ "${parttype,,}" == *"c12a7328"* ]]; then
        EFI_PART="$part"
        break
    fi
done

# Fallback: if PARTTYPE detection didn't work, try finding any vfat partition
# with EFI/BOOT/grub.cfg.
if [[ -z "$EFI_PART" ]]; then
    for part in "${USB_DEV}"*[0-9]; do
        fstype=$(lsblk -no FSTYPE "$part" 2>/dev/null || true)
        if [[ "$fstype" == "vfat" ]]; then
            EFI_PART="$part"
            break
        fi
    done
fi

[[ -n "$EFI_PART" ]] || die "Could not find EFI partition on ${USB_DEV} after flashing."

MNT=$(mktemp -d /tmp/installer-efi.XXXX)
info "Mounting EFI partition ${EFI_PART} at ${MNT}..."
mount -t vfat "$EFI_PART" "$MNT"

# --- Find grub.cfg ---
GRUB_CFG=""
for candidate in \
    "$MNT/EFI/BOOT/grub.cfg" \
    "$MNT/boot/grub2/grub.cfg" \
    "$MNT/EFI/fedora/grub.cfg"; do
    if [[ -f "$candidate" ]]; then
        GRUB_CFG="$candidate"
        break
    fi
done

if [[ -z "$GRUB_CFG" ]]; then
    warn "Could not find grub.cfg. Contents of EFI partition:"
    find "$MNT" -type f | head -30
    umount "$MNT"
    rmdir "$MNT"
    die "Patch grub.cfg manually and re-run."
fi

info "Found GRUB config: ${GRUB_CFG}"

# --- Extract the inst.stage2 LABEL from existing config ---
# We need it so the kernel can find the installer media.
STAGE2_LABEL=$(grep -oP 'inst\.stage2=hd:LABEL=\K[^ ]+' "$GRUB_CFG" | head -1 || true)
if [[ -z "$STAGE2_LABEL" ]]; then
    warn "Could not auto-detect inst.stage2 LABEL from grub.cfg."
    warn "Proceeding anyway — the existing inst.stage2 line will be preserved."
fi

# --- Patch grub.cfg ---
info "Patching GRUB config..."
cp "$GRUB_CFG" "${GRUB_CFG}.orig"

# 1. Add inst.ks= to the kernel command line (all linuxefi/linux lines
#    that already have inst.stage2). Idempotent — won't add twice.
if ! grep -q "inst.ks=" "$GRUB_CFG"; then
    sed -i \
        '/inst\.stage2=/s|$| inst.ks=hd:LABEL='"$KS_LABEL"':/ks.cfg|' \
        "$GRUB_CFG"
    info "Added inst.ks=hd:LABEL=${KS_LABEL}:/ks.cfg to kernel command line."
else
    info "inst.ks= already present in grub.cfg — skipping."
fi

# 2. Set timeout to 5 seconds for auto-boot.
sed -i 's/^set timeout=.*/set timeout=5/' "$GRUB_CFG"
info "Set GRUB timeout to 5 seconds."

# --- Show the patched entry for verification ---
echo
echo -e "${BOLD}--- Patched boot entry ---${NC}"
grep -A3 'menuentry.*Install' "$GRUB_CFG" | head -8
echo -e "${BOLD}--- End ---${NC}"
echo

# --- Cleanup ---
umount "$MNT"
rmdir "$MNT"
sync

info "Done! USB installer is ready at ${USB_DEV}."
echo
echo "Next steps:"
echo "  1. Plug this stick + the ${KS_LABEL} stick into the target machine."
echo "  2. Boot from ${USB_DEV}."
echo "  3. GRUB auto-boots after 5 s → Anaconda reads ks.cfg → unattended install."
echo "  4. Machine reboots into fresh Fedora when done."

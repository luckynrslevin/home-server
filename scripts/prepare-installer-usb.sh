#!/bin/bash
# ============================================================================
# Prepare a bootable Fedora Server USB installer with kickstart auto-boot.
#
# Usage:
#   sudo bash scripts/prepare-installer-usb.sh [fedora-iso] [ks-cfg]
#
# Arguments:
#   [fedora-iso]   Path to an already-downloaded ISO file. If omitted, the
#                  script queries the Fedora releases API, lists available
#                  Server DVD ISOs for this machine's architecture, lets
#                  you choose, and downloads it.
#   [ks-cfg]       Path to a kickstart file. If provided, it is copied onto
#                  the installer stick's EFI partition and GRUB is pointed
#                  at it — single-stick operation, no second USB needed.
#                  If omitted, GRUB points at hd:LABEL=KSUSB:/ks.cfg
#                  (a second stick labelled KSUSB must be plugged in at
#                  boot time).
#
# What it does:
#   1. (Optional) Fetches available Fedora Server ISOs and downloads one.
#   2. Finds the USB block device (must be exactly one plugged in).
#   3. Confirms with the user before wiping.
#   4. Flashes the ISO with dd.
#   5. Mounts the EFI partition on the freshly-flashed stick.
#   6. Patches grub.cfg to:
#      - Auto-boot with inst.ks=hd:LABEL=<ks-label>:/ks.cfg
#      - Set a 5-second timeout (no keyboard needed)
#   7. Unmounts and syncs — ready to boot.
#
# Requirements:
#   - Run as root (dd needs raw device access).
#   - Exactly one USB block device plugged in (the target).
#   - curl, python3, lsblk, dd, partprobe available.
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
KS_CFG="${2:-}"

[[ $EUID -eq 0 ]] || die "Run as root: sudo $0 $*"

# ============================================================================
# Step 1: If no ISO provided, fetch the list and let the user choose
# ============================================================================
if [[ -z "$ISO" ]]; then
    info "No ISO specified. Querying Fedora releases..."

    RELEASES_JSON=$(curl -fsSL https://getfedora.org/releases.json) \
        || die "Failed to fetch release data from getfedora.org."

    # Filter for stable Server DVD ISOs for aarch64 and x86_64.
    # Excludes Beta / test releases.
    FILTER_SCRIPT='
import json, sys
data = json.load(sys.stdin)
seen = set()
idx = 0
for r in data:
    ver = r.get("version", "")
    arch = r.get("arch", "")
    if (r.get("subvariant") == "Server"
        and arch in ("aarch64", "x86_64")
        and r.get("variant") == "Server"
        and r.get("link", "").endswith(".iso")
        and "dvd" in r.get("link", "").lower()
        and "Beta" not in ver
        and "/test/" not in r.get("link", "")):
        key = ver + r["link"]
        if key in seen:
            continue
        seen.add(key)
        idx += 1
        size = r.get("size")
        size_mb = str(int(size) // 1024 // 1024) if size and str(size).isdigit() else "?"
        url = r["link"]
        name = url.rsplit("/", 1)[-1]
        print(f"CHOICE|{idx}) Fedora {ver:5s} {arch:8s} {size_mb:>6s} MB  {name}")
        print(f"URL|{url}")
'
    PARSED=$(echo "$RELEASES_JSON" | python3 -c "$FILTER_SCRIPT") \
        || die "Failed to parse release data."

    CHOICES=$(echo "$PARSED" | grep "^CHOICE|" | cut -d'|' -f2-)
    mapfile -t URLS < <(echo "$PARSED" | grep "^URL|" | cut -d'|' -f2-)

    if [[ -z "$CHOICES" ]]; then
        die "No stable Fedora Server DVD ISOs found."
    fi

    echo
    echo -e "${BOLD}Available Fedora Server DVD ISOs:${NC}"
    echo
    echo "$CHOICES"
    echo

    echo -ne "${BOLD}Select ISO number [1]: ${NC}"
    read -r selection
    selection="${selection:-1}"

    # Validate
    if ! [[ "$selection" =~ ^[0-9]+$ ]] || (( selection < 1 || selection > ${#URLS[@]} )); then
        die "Invalid selection: $selection"
    fi

    DOWNLOAD_URL="${URLS[$((selection - 1))]}"
    ISO_FILENAME="${DOWNLOAD_URL##*/}"
    ISO="/var/tmp/${ISO_FILENAME}"

    if [[ -f "$ISO" ]]; then
        info "ISO already downloaded: ${ISO}"
        echo -ne "${BOLD}Re-download? [y/N]: ${NC}"
        read -r redownload
        if [[ "$redownload" =~ ^[Yy]$ ]]; then
            rm -f "$ISO"
        fi
    fi

    if [[ ! -f "$ISO" ]]; then
        info "Downloading ${ISO_FILENAME}..."
        curl -fL -o "$ISO" "$DOWNLOAD_URL" \
            || die "Download failed."
        info "Downloaded to ${ISO}"
    fi
fi

[[ -f "$ISO" ]] || die "ISO file not found: $ISO"

# ============================================================================
# Step 2: Find the USB device
# ============================================================================
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

# ============================================================================
# Step 3: Confirm
# ============================================================================
warn "ALL DATA ON ${USB_DEV} WILL BE DESTROYED."
echo -ne "${BOLD}Type 'yes' to continue: ${NC}"
read -r confirm
[[ "$confirm" == "yes" ]] || die "Aborted."

# --- Unmount any mounted partitions ---
info "Unmounting any mounted partitions on ${USB_DEV}..."
for part in "${USB_DEV}"*; do
    mountpoint -q "$part" 2>/dev/null && umount "$part" 2>/dev/null || true
done

# ============================================================================
# Step 4: Flash the ISO
# ============================================================================
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

# ============================================================================
# Step 5: Find and mount the EFI partition
# ============================================================================
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

# ============================================================================
# Step 6: Patch grub.cfg
# ============================================================================
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

# Extract the inst.stage2 LABEL from existing config (for reference).
STAGE2_LABEL=$(grep -oP 'inst\.stage2=hd:LABEL=\K[^ ]+' "$GRUB_CFG" | head -1 || true)
if [[ -z "$STAGE2_LABEL" ]]; then
    warn "Could not auto-detect inst.stage2 LABEL from grub.cfg."
    warn "Proceeding anyway — the existing inst.stage2 line will be preserved."
fi

info "Patching GRUB config..."
cp "$GRUB_CFG" "${GRUB_CFG}.orig"

# --- Determine kickstart source ---
if [[ -n "$KS_CFG" ]]; then
    # Embedded mode: copy ks.cfg onto the EFI partition and point GRUB
    # at it using the installer media's own LABEL (same partition).
    if [[ ! -f "$KS_CFG" ]]; then
        umount "$MNT"; rmdir "$MNT"
        die "Kickstart file not found: $KS_CFG"
    fi
    cp "$KS_CFG" "$MNT/ks.cfg"
    info "Copied $(basename "$KS_CFG") onto EFI partition."

    # Use the inst.stage2 LABEL (the installer media itself) to
    # reference ks.cfg — no second stick needed.
    if [[ -n "$STAGE2_LABEL" ]]; then
        KS_REF="hd:LABEL=${STAGE2_LABEL}:/ks.cfg"
    else
        # Fallback: assume the EFI partition is the first thing found.
        KS_REF="hd:LABEL=KSUSB:/ks.cfg"
        warn "Could not detect inst.stage2 LABEL; falling back to LABEL=KSUSB."
    fi
    info "GRUB will load kickstart from: ${KS_REF}"
else
    # External mode: expect a second stick labelled KSUSB.
    KS_REF="hd:LABEL=KSUSB:/ks.cfg"
    info "No kickstart file provided — GRUB will look for hd:LABEL=KSUSB:/ks.cfg"
    info "(Plug in a second stick labelled KSUSB with ks.cfg at its root.)"
fi

# Add inst.ks= to the kernel command line (all linuxefi/linux lines
# that already have inst.stage2). Idempotent — won't add twice.
if ! grep -q "inst.ks=" "$GRUB_CFG"; then
    sed -i \
        '/inst\.stage2=/s|$| inst.ks='"$KS_REF"'|' \
        "$GRUB_CFG"
    info "Added inst.ks=${KS_REF} to kernel command line."
else
    info "inst.ks= already present in grub.cfg — skipping."
fi

# Set timeout to 5 seconds for auto-boot.
sed -i 's/^set timeout=.*/set timeout=5/' "$GRUB_CFG"
info "Set GRUB timeout to 5 seconds."

# --- Show the patched entry for verification ---
echo
echo -e "${BOLD}--- Patched boot entry ---${NC}"
grep -A3 'menuentry.*Install' "$GRUB_CFG" | head -8
echo -e "${BOLD}--- End ---${NC}"
echo

# ============================================================================
# Step 7: Cleanup
# ============================================================================
umount "$MNT"
rmdir "$MNT"
sync

info "Done! USB installer is ready at ${USB_DEV}."
echo
echo "Next steps:"
if [[ -n "$KS_CFG" ]]; then
    echo "  1. Plug this stick into the target machine (single-stick mode)."
else
    echo "  1. Plug this stick + a KSUSB stick into the target machine."
fi
echo "  2. Boot from the USB stick."
echo "  3. GRUB auto-boots after 5 s → Anaconda reads ks.cfg → unattended install."
echo "  4. Machine reboots into fresh Fedora when done."

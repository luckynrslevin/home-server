#!/usr/bin/env python3
"""
scripts/test_e2e/verify_backup_contents.py — confirm a backup tarball
contains the expected fixture files.

Used by scripts/test_e2e.sh after a backup run to assert end-to-end
data flow: the fixture filenames uploaded into Nextcloud via WebDAV
should appear inside the nextcloud-data tarball on the NAS share. Any
mid-pipeline data loss (rsync misconfig, tar exclude pattern, wrong
volume) shows up as a missing file here.

Two operating modes:

  --mount-and-check        mount the NAS share read-only, find the
                           latest tarball for the named role+volume,
                           grep for expected fixture filenames, then
                           unmount. The pattern the backup script
                           actually deploys to NAS.

  --tarball <path>         skip the mount step and look at a tarball
                           the caller already located. Useful for
                           debugging without NFS access.

Exit 0 if every expected filename is present; non-zero otherwise.
"""

import argparse
import os
import subprocess
import sys
import tarfile
import tempfile
from pathlib import Path


def latest_tarball(share_root: Path, role: str, volume: str) -> Path:
    """Return the most recent .tar.gz under share_root/<role>/<volume>/."""
    candidates = sorted((share_root / role / volume).glob("*.tar.gz"),
                        key=lambda p: p.stat().st_mtime, reverse=True)
    if not candidates:
        sys.exit(f"ERROR: no *.tar.gz under {share_root / role / volume}")
    return candidates[0]


def names_in_tar(tar_path: Path) -> set:
    """Return the set of basename(member) for every file in the tarball."""
    names = set()
    with tarfile.open(tar_path, "r:gz") as tf:
        for m in tf.getmembers():
            if m.isfile():
                names.add(os.path.basename(m.name))
    return names


def check(tar_path: Path, expected: list[str]) -> int:
    """Assert every name in `expected` is present inside `tar_path`."""
    present = names_in_tar(tar_path)
    print(f"Tarball: {tar_path} ({len(present)} files)")
    missing = [n for n in expected if n not in present]
    if missing:
        print(f"MISSING: {len(missing)} fixture(s) not in tarball:")
        for n in missing:
            print(f"  - {n}")
        return 1
    print(f"OK: all {len(expected)} expected fixture(s) present.")
    return 0


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--expect", nargs="+", required=True,
                   help="Filename(s) that MUST be present in the tarball.")
    g = p.add_mutually_exclusive_group(required=True)
    g.add_argument("--tarball", help="Path to an already-extracted tarball.")
    g.add_argument("--mount-and-check", action="store_true",
                   help="Mount the NAS share, find the latest tarball, check, unmount.")
    p.add_argument("--nas-host", help="NAS hostname (with --mount-and-check)")
    p.add_argument("--nas-volume", help="NAS volume root (with --mount-and-check)")
    p.add_argument("--share-name", help="Share basename, e.g. backup-homeserver2")
    p.add_argument("--role", help="Role subdir inside the share, e.g. nextcloud")
    p.add_argument("--volume", help="Volume subdir inside the role, e.g. nextcloud-data")
    args = p.parse_args()

    if args.tarball:
        sys.exit(check(Path(args.tarball), args.expect))

    # --mount-and-check path
    for needed in ("nas_host", "nas_volume", "share_name", "role", "volume"):
        if not getattr(args, needed):
            sys.exit(f"ERROR: --mount-and-check requires --{needed.replace('_', '-')}")

    with tempfile.TemporaryDirectory(prefix="e2e-backup-mount-") as mnt:
        nfs_src = f"{args.nas_host}:{args.nas_volume}/{args.share_name}"
        try:
            subprocess.run(
                ["sudo", "mount", "-t", "nfs", "-o", "ro,noatime,vers=4",
                 nfs_src, mnt],
                check=True,
            )
        except subprocess.CalledProcessError as exc:
            sys.exit(f"ERROR: NFS mount {nfs_src} → {mnt} failed: {exc}")
        try:
            tar_path = latest_tarball(Path(mnt), args.role, args.volume)
            rc = check(tar_path, args.expect)
        finally:
            subprocess.run(["sudo", "umount", mnt], check=False)
        sys.exit(rc)


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""
scripts/test_e2e/upload_nextcloud_files.py — upload fixture files
into Nextcloud via WebDAV.

Used by scripts/test_e2e.sh to populate the running Nextcloud instance
with deterministic test data before triggering a backup. The same
filenames are looked up in the backup tarball by
verify_backup_contents.py, so any mid-pipeline data loss is caught.

Auth is HTTP Basic with the admin user from inventory. The runner
fetches the password via `homeserver.sh secret nextcloud_admin_password`
(ASCII-clean since PR #291) and passes it as --password-from-env.

Exit code: 0 on every PUT returning 201/204/207; non-zero otherwise.
"""

import argparse
import os
import sys
import urllib.parse
from pathlib import Path

try:
    import requests
except ImportError:
    sys.exit("ERROR: python-requests not installed.")
try:
    from requests.packages.urllib3.exceptions import InsecureRequestWarning
    requests.packages.urllib3.disable_warnings(InsecureRequestWarning)
except ImportError:
    pass


def upload(base_url, user, password, src_path):
    """PUT src_path into Nextcloud at /remote.php/dav/files/{user}/{name}."""
    dest_url = (f"{base_url.rstrip('/')}/remote.php/dav/files/"
                f"{urllib.parse.quote(user)}/{urllib.parse.quote(src_path.name)}")
    with open(src_path, "rb") as fh:
        r = requests.put(
            dest_url, data=fh,
            auth=(user, password),
            verify=False,           # caddy may still be issuing the cert
            timeout=30,
        )
    return r.status_code, dest_url


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--url", required=True,
                   help="Nextcloud base URL, e.g. https://cloud.simsons-t.dedyn.io")
    p.add_argument("--user", default="ncadmin",
                   help="Admin username (default: ncadmin)")
    p.add_argument("--password-from-env", default="NEXTCLOUD_ADMIN_PASSWORD",
                   help="Read admin password from this env var "
                        "(default: NEXTCLOUD_ADMIN_PASSWORD)")
    p.add_argument("--fixtures-dir", required=True,
                   help="Directory containing the fixture files to upload")
    p.add_argument("--glob", default="payload-*.txt",
                   help="Fixture filename glob (default: payload-*.txt)")
    args = p.parse_args()

    password = os.environ.get(args.password_from_env)
    if not password:
        sys.exit(f"ERROR: env var {args.password_from_env} is empty or unset.")

    fixtures = sorted(Path(args.fixtures_dir).glob(args.glob))
    if not fixtures:
        sys.exit(f"ERROR: no fixtures matched {args.glob} under {args.fixtures_dir}")

    print(f"Uploading {len(fixtures)} fixture(s) to {args.url} as {args.user}")
    failures = []
    for src in fixtures:
        status, url = upload(args.url, args.user, password, src)
        marker = "OK " if status in (201, 204, 207) else "FAIL"
        print(f"  [{marker}] {status} {url}")
        if status not in (201, 204, 207):
            failures.append((src.name, status))

    if failures:
        print(f"\n{len(failures)} upload(s) failed:")
        for name, status in failures:
            print(f"  - {name}: HTTP {status}")
        sys.exit(1)
    print(f"\nAll {len(fixtures)} fixture(s) uploaded successfully.")


if __name__ == "__main__":
    main()

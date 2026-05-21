#!/usr/bin/env python3
# Build an HTML report of Ente photo organization for operator self-cleanup.
"""
Joins the museum's collection_files / collections tables with the on-disk
.meta/*.json sidecars left by `ente export`, then writes a static HTML page
to /var/www/dashboard/ente-photos-report.html (served by Caddy alongside
the dashboard).

Three sections are listed (single-album files are skipped — nothing actionable):
  - Unsorted  : files only in Uncategorized
  - Orphan    : files in no user-owned collection at all (DB cruft)
  - Multi-album: files in 2+ named albums

Names render as click-to-copy spans (Ente has no deep-link URLs for the
gallery view, so this is the closest thing to "jump there from the report").
"""

import argparse
import csv
import html
import io
import json
import shutil
import subprocess
import sys
import time
from collections import defaultdict
from pathlib import Path


def psql(sql: str) -> list[dict]:
    """Run a SELECT in the entephoto-postgres container, return list of dict rows.

    Uses --csv output so values with commas/newlines round-trip cleanly.
    SQL is fed via stdin to dodge nested-quote hell.
    """
    cmd = [
        "su", "-", "entephoto", "-c",
        "podman exec -i entephoto-postgres psql -U pguser ente_db --csv",
    ]
    r = subprocess.run(cmd, input=sql, capture_output=True, text=True, check=True)
    return list(csv.DictReader(io.StringIO(r.stdout)))


def detect_owner_id() -> int:
    rows = psql("SELECT owner_id, count(*) AS n FROM files GROUP BY owner_id "
                "ORDER BY n DESC LIMIT 1;")
    if not rows:
        sys.exit("no files in museum DB")
    return int(rows[0]["owner_id"])


def fetch_collections(owner_id: int, export_dir: Path) -> dict:
    """{collection_id: {name, type}} merged from DB type + sidecar names.

    Ente stores collection names E2E-encrypted; the plaintext `name` column
    is empty. The album folder's `.meta/album_meta.json` sidecar carries
    the CLI-decrypted name keyed by the collection_id.
    """
    rows = psql(f"SELECT collection_id, type FROM collections "
                f"WHERE owner_id = {owner_id} AND is_deleted = false;")
    collections = {int(r["collection_id"]): {"name": "(unnamed)", "type": r["type"]}
                   for r in rows}
    for meta in export_dir.glob("*/.meta/album_meta.json"):
        try:
            data = json.loads(meta.read_text())
        except (OSError, json.JSONDecodeError):
            continue
        cid = data.get("id")
        name = data.get("albumName")
        if cid is None or not name:
            continue
        if int(cid) in collections:
            collections[int(cid)]["name"] = name
    # Surface the special collections with friendly labels.
    for c in collections.values():
        if c["type"] == "uncategorized" and c["name"] == "(unnamed)":
            c["name"] = "Uncategorized"
    return collections


def fetch_memberships(owner_id: int) -> dict:
    """{file_id: [collection_id, ...]} for non-deleted memberships of user's own files."""
    rows = psql(f"SELECT file_id, collection_id FROM collection_files "
                f"WHERE is_deleted = false AND f_owner_id = {owner_id};")
    out = defaultdict(list)
    for r in rows:
        out[int(r["file_id"])].append(int(r["collection_id"]))
    return out


def walk_sidecars(export_dir: Path) -> dict:
    """{file_id: {filename, created}} from per-photo JSON sidecars."""
    out: dict = {}
    for meta in export_dir.rglob(".meta/*.json"):
        if meta.name == "album_meta.json":
            continue
        try:
            data = json.loads(meta.read_text())
        except (OSError, json.JSONDecodeError):
            continue
        info = data.get("info") or {}
        fid = info.get("id")
        if fid is None:
            continue
        out[int(fid)] = {
            "filename": data.get("title") or meta.stem,
            "created": data.get("creationTime") or "",
        }
    return out


CSS = """
body { font-family: -apple-system, BlinkMacSystemFont, sans-serif;
       max-width: 1400px; margin: 1rem auto; padding: 0 1rem; color: #222; }
h1 { font-size: 1.4rem; margin-bottom: 0.25rem; }
.meta { color: #888; font-size: 0.85rem; margin-bottom: 1rem; }
.help { margin: 0.5rem 0 1rem; color: #555; font-size: 0.95rem; line-height: 1.45; }
.stats { background: #f4f4f4; padding: 0.5rem 1rem; border-radius: 4px;
         font-family: ui-monospace, monospace; font-size: 0.9rem;
         margin-bottom: 1rem; }
.warn { background: #fff3cd; border-left: 4px solid #ffc107; border-radius: 2px;
        padding: 0.75rem 1rem; margin: 1rem 0; color: #604812;
        line-height: 1.5; }
.warn strong { color: #b85c00; }
details { margin: 1rem 0; }
summary { cursor: pointer; font-weight: 600; padding: 0.5rem 0.75rem;
          background: #eee; border-radius: 4px; }
summary:hover { background: #e0e0e0; }
table { border-collapse: collapse; width: 100%; margin-top: 0.5rem;
        font-size: 0.9rem; }
th { background: #f8f8f8; text-align: left; padding: 0.35rem 0.6rem;
     border-bottom: 2px solid #ddd; cursor: pointer; user-select: none;
     position: sticky; top: 0; }
th:hover { background: #e8e8e8; }
th::after { content: ' \\2195'; opacity: 0.4; font-size: 0.7em; }
td { padding: 0.25rem 0.6rem; border-bottom: 1px solid #f0f0f0;
     vertical-align: top; }
tr:hover { background: #fafafa; }
em { color: #999; font-style: normal; font-size: 0.85rem; }
"""

JS = r"""
document.querySelectorAll('table.sortable').forEach(function(table) {
    table.querySelectorAll('th').forEach(function(th, i) {
        th.addEventListener('click', function() {
            var tbody = table.tBodies[0];
            var rows = Array.prototype.slice.call(tbody.rows);
            var asc = th.dataset.dir !== 'asc';
            th.dataset.dir = asc ? 'asc' : 'desc';
            rows.sort(function(a, b) {
                var x = a.cells[i].textContent.trim();
                var y = b.cells[i].textContent.trim();
                return (asc ? 1 : -1) * x.localeCompare(y, undefined, { numeric: true });
            });
            rows.forEach(function(r) { tbody.appendChild(r); });
        });
    });
});
"""


HELP_HTML = """
<p class="help">
Photos have no &ldquo;primary&rdquo; album in Ente &mdash; each album in
the <em>albums</em> column is an equal reference to the same stored photo.
Ente&rsquo;s web app does not support deep-links into albums or files yet,
so names below are plain text. Find them by name in the Ente UI.
</p>
"""

WARN_HTML = """
<div class="warn">
<strong>&#9888; Remove from album</strong> vs <strong>Move to trash / Delete</strong><br>
<em>Remove from album</em> removes only the link from that one album &mdash;
the photo stays in your other albums and in Uncategorized. Safe.<br>
<em>Move to trash / Delete</em> removes the photo from <strong>every</strong>
album and queues the underlying file for permanent deletion. Destructive
&mdash; use only when you mean to remove the photo from the library entirely.
</div>
"""


def emit_html(stats_line: str, sections: list, output: Path) -> None:
    """sections: [(title, rows)] where rows = [(filename, created, [album_names])]."""
    out = io.StringIO()
    out.write("<!doctype html>\n<html lang=\"en\"><head>")
    out.write("<meta charset=\"utf-8\">"
              "<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">")
    out.write("<title>Ente Photos report</title>")
    out.write(f"<style>{CSS}</style></head><body>")
    out.write("<h1>Ente Photos report</h1>")
    out.write(f"<div class=\"meta\">Generated {html.escape(time.strftime('%Y-%m-%d %H:%M:%S %Z'))}</div>")
    out.write(HELP_HTML)
    out.write(WARN_HTML)
    out.write(f"<div class=\"stats\">{html.escape(stats_line)}</div>")

    for title, rows in sections:
        out.write(f"<details open><summary>{html.escape(title)} "
                  f"({len(rows):,})</summary>")
        if not rows:
            out.write("<p><em>(empty)</em></p></details>")
            continue
        out.write("<table class=\"sortable\"><thead><tr>"
                  "<th>filename</th><th>created</th><th>albums</th>"
                  "</tr></thead><tbody>")
        for fname, created, albums in rows:
            fname_html = html.escape(fname)
            created_html = html.escape(created or "")
            if albums:
                album_cells = " &middot; ".join(html.escape(a) for a in albums)
            else:
                album_cells = "<em>(none)</em>"
            out.write(
                f"<tr><td>{fname_html}</td>"
                f"<td>{created_html}</td><td>{album_cells}</td></tr>"
            )
        out.write("</tbody></table></details>")

    out.write(f"<script>{JS}</script></body></html>\n")
    output.write_text(out.getvalue())


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--export-dir", default="/srv/photos-export",
                   help="Root of the entephoto export tree (default: %(default)s)")
    p.add_argument("--output", default="/var/www/dashboard/ente-photos-report.html",
                   help="HTML output path (default: %(default)s)")
    p.add_argument("--owner-id", type=int, help="Restrict to this user; "
                                                "auto-detected by file count if omitted")
    p.add_argument("--dry-run", action="store_true",
                   help="Print stats to stdout instead of writing HTML")
    args = p.parse_args()

    if not shutil.which("su"):
        sys.exit("su(1) not on PATH — this script expects to run on a deployed host")

    owner_id = args.owner_id or detect_owner_id()
    print(f"[info] owner_id={owner_id}", file=sys.stderr)

    export_dir = Path(args.export_dir)
    collections = fetch_collections(owner_id, export_dir)
    memberships = fetch_memberships(owner_id)
    sidecars = walk_sidecars(export_dir)

    files = {}
    for fid, info in sidecars.items():
        member_cids = memberships.get(fid, [])
        album_names = []
        in_uncat = False
        for cid in member_cids:
            col = collections.get(cid)
            if not col:
                continue
            if col["type"] == "uncategorized":
                in_uncat = True
            elif col["type"] in ("album", "folder"):
                album_names.append(col["name"])
        files[fid] = {
            "filename": info["filename"],
            "created": info["created"],
            "albums": sorted(set(album_names), key=str.lower),
            "in_uncategorized": in_uncat,
        }

    unsorted_rows, orphan_rows, multi_rows = [], [], []
    for f in files.values():
        row = (f["filename"], f["created"], f["albums"])
        if not f["albums"]:
            (unsorted_rows if f["in_uncategorized"] else orphan_rows).append(row)
        elif len(f["albums"]) > 1:
            multi_rows.append(row)

    for rows in (unsorted_rows, orphan_rows, multi_rows):
        rows.sort(key=lambda r: r[0].lower())

    total_files = len(files)
    total_albums = sum(1 for c in collections.values()
                       if c["type"] in ("album", "folder"))
    stats = (f"{total_files:,} photos · {total_albums:,} albums · "
             f"{len(unsorted_rows):,} unsorted · "
             f"{len(orphan_rows):,} orphan · "
             f"{len(multi_rows):,} multi-album")

    if args.dry_run:
        print(stats)
        return 0

    out_path = Path(args.output)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    emit_html(stats, [
        ("Unsorted (only in Uncategorized)", unsorted_rows),
        ("Orphan (in no user-owned collection)", orphan_rows),
        ("Multi-album", multi_rows),
    ], out_path)
    print(f"[info] wrote {out_path} ({out_path.stat().st_size:,} bytes)",
          file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())

# Automated regression testing on `homeserver2`

The project ships an automated E2E regression test that exercises the
full deploy → app → backup chain on a dedicated test host. It catches
the kinds of bugs that previously needed an hour of manual testing
after every PR — silent admin-password drift, broken backup snapshot
triggers, partial deploys that fail at first user contact.

This doc covers:

1. One-time operator setup on `homeserver2`
2. Running the test
3. Reading the output
4. Extending coverage to more apps

## What the test does

`scripts/test_e2e.sh` orchestrates 12 phases against `homeserver2`:

| Phase | What runs | What it proves |
|---|---|---|
| 0 | Pre-flight checks | The host is `homeserver2`, the test overlay exists, the prod overlay is clean, no backup is mid-flight |
| 1 | Stage helpers + fixtures to `/tmp` | (so they survive the uninstall in phase 3) |
| 2 | Park prod overlay aside, swap test overlay into its place | The test runs against a known-clean curated inventory; the prod overlay is untouched |
| 3 | `homeserver.sh uninstall` | The host returns to a known-empty state — exercises `clean-host.sh` for regressions |
| 4 | `git clone` a fresh repo | Bootstrap path |
| 5 | `homeserver.sh install -y -h homeserver2` (platform only) | Install flow's non-interactive mode against the test overlay's curated services list |
| 6 | `curl https://<caddy_domain>/` | Caddy serving + LE cert issued |
| 7 | `homeserver.sh add nextcloud -y` | `add` workflow + role's `tasks/verify.yml` (container running, /status.php, WebDAV PROPFIND, occ status) |
| 8 | Upload 5 fixture files via WebDAV | Real app traffic — the auth path the user takes |
| 9 | `homeserver.sh add backup -y` | `add` workflow + backup role's `tasks/verify.yml` (timer enabled+active, NFS mount round-trip, last log clean) |
| 10 | `systemctl start home-server-backup.service`, wait | A real backup run end-to-end |
| 11 | Assert log shows `0 errors` | The backup script completed every per-app step |
| 12 | Mount NAS share read-only, assert all 5 fixtures present in the nextcloud-data tarball | **End-to-end data flow**: user-uploaded files survived the backup pipeline |

On exit (success or failure), an `EXIT` trap always:
- Swaps the prod overlay back into place.
- Removes the staging directory under `/tmp`.

Total wall time: 30-40 min.

## One-time operator setup

You only need to do this once per machine. After this, the test is
`./scripts/test_e2e.sh -y`.

### 1. Create `~/home-server-test-overlay/` on `homeserver2`

This is a separate operator-owned tree with the same layout as your
production overlay (`~/home-server-private/`). The test runner
**parks the prod overlay aside** and renames this one into its place
for the duration of the run.

The cleanest seed is to copy your prod overlay and trim it:

```bash
# On homeserver2
cp -a ~/home-server-private ~/home-server-test-overlay

# Strip the apps so the test starts from "platform only":
cd ~/home-server-test-overlay/inventory/host_vars/homeserver2

# Edit 00-services.yml — leave caddy + dashboard, drop nextcloud/paperless/etc.
# Final state should look like:
#   platform_services: [caddy, dashboard]
#   apps: []

# Remove the per-app files (the runner re-generates them via `add`):
rm -rf apps/

# Set up a backup file with NAS coords but no other app-specific bits.
# (50-backup.yml will be re-created by `add backup` during the run, but
# pre-seeding the NAS IP avoids the prompt under -y.)
```

The test overlay reuses:
- The same `caddy_domain` (e.g. `simsons-t.dedyn.io`) — `homeserver2`
  IS the system under test, no other service needs the domain during
  a test run.
- The same SMTP credentials (sending mail is a real dependency).
- The same NAS coords + NFS share (`backup-homeserver2`).
- The same `vault.pw`.

### 2. Confirm prerequisites

```bash
# Prod overlay clean (no uncommitted changes)
cd ~/home-server-private && git status -sb

# Test overlay exists at the expected path
ls -la ~/home-server-test-overlay/inventory/host_vars/homeserver2/

# Optional but recommended: temporarily stop the prod backup timer so
# the next nightly backup doesn't race the test.
sudo systemctl stop home-server-backup.timer
```

The runner re-enables the timer on exit if you used the trap (which is
default), but stopping it explicitly avoids any surprise interaction.

## Running

```bash
# Interactive (gates with a confirmation prompt)
ssh homeserver2 'cd ~/home-server && ./scripts/test_e2e.sh'

# Non-interactive (for cron)
ssh homeserver2 'cd ~/home-server && ./scripts/test_e2e.sh -y'
```

Or from `homeserver2` directly:

```bash
cd ~/home-server
./scripts/test_e2e.sh
```

Exit code 0 = green. Any other exit = a phase failed; the last log
lines name which one.

## Reading the output

Phases print a heading and tick marks for each sub-step:

```
=== Phase 6: assert caddy + dashboard reachable ===
[09:14:22] caddy_domain: simsons-t.dedyn.io
  ✓ Caddy serves apex: HTTP 200

=== Phase 7: ./homeserver.sh add nextcloud -y ===
... (ansible play output) ...
  ✓ nextcloud added (role verify passed inline)
```

On failure, the trap names the failed phase before cleanup runs:

```
  ✗ Failed in phase: 11/log-check (exit 1)

=== Cleanup (always runs) ===
[09:42:05] [[ -d '/home/ds/home-server-private' ]] && mv ... || true
[09:42:05] [[ -d '/home/ds/home-server-private.parked-by-e2e' ]] && mv ... || true
[09:42:05] rm -rf '/tmp/home-server-e2e-staging-12345'
```

If the runner crashes mid-flight (e.g. SIGKILL'd), you may find
`~/home-server-private.parked-by-e2e/` left over. The pre-flight check
detects this on the next run and tells you how to restore.

## Extending coverage

The current MVP is platform + nextcloud + backup. Adding another app
is mechanical — two pieces of code:

1. Add `tasks/verify.yml` to the role (see `roles/apps/nextcloud/tasks/verify.yml`
   for the shape and `roles/platform/pihole/tasks/verify.yml` as the
   schema reference).
2. Add three phases to `scripts/test_e2e.sh` between phases 11 and 12:
   - `homeserver.sh add <svc> -y`
   - Upload a small fixture (PDF for paperless, video for jellyfin,
     etc.)
   - Extend the phase-12 backup-content check to include the
     new tarball + fixture names.

The `tasks/verify.yml` change is the higher-value deliverable — it
runs at every deploy, not just E2E test runs.

Out of scope today (next PRs):
- paperless-ngx, jellyfin, entephoto, syncthing, music-assistant verify + E2E phases.
- Restore round-trip verification (boot a restored snapshot, confirm fixtures come back).
- GitHub Actions matrix run on PRs with a `needs-e2e` label.
- Nightly cron + mail-on-failure.

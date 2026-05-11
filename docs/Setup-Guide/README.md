# Setup Guide

> **Setup Guide** · Index · ▱▱▱▱▱ 0% · ~50–90 min total

Welcome. By the end of this guide you'll have a fully-deployed
homeserver reachable from your laptop at
`https://<your-name>.dedyn.io/` — green padlock, no warnings, no
per-device cert install. The dashboard shows every service that's
running and lets you click straight into Pi-hole, Syncthing,
Paperless, Ente Photos, Jellyfin, Music Assistant.

> [!NOTE]
> Prefer one long page over a wizard? See
> **[Quickstart](../Quickstart.md)** — same path, denser format.

## What you'll do

| # | Step | Time | What you'll have at the end |
|---|---|---|---|
| 1 | [deSEC account](01-deSEC-account.md) | ~5 min | A free `*.dedyn.io` subdomain + an API token in your clipboard. |
| 2 | [Install the OS](02-install-os.md) | ~20–60 min | AlmaLinux 9 booted on your hardware or VPS, SSH-reachable. |
| 3 | [SSH & sudo](03-ssh-and-sudo.md) | ~3 min | A working SSH session as a non-root user with passwordless sudo. |
| 4 | [Run setup.sh](04-run-setup.md) | ~20 min | The full stack deployed, certs issued, services running. |
| 5 | [Verify & explore](05-verify-and-explore.md) | ~2 min | You're logged into the dashboard. Done. |

**Total budget:** ~50–90 min depending on which OS install method you
pick in Step 2.

## Prerequisites

Before you start, make sure you have:

- A piece of hardware to run the homeserver on (mini-PC, NUC, old
  laptop, or a cloud VPS). 4 GB RAM minimum, 8 GB+ recommended.
- A laptop or desktop on the same network — you'll use it to SSH
  into the server and to load the dashboard.
- An internet connection (the server needs it to fetch packages
  and renew certificates).
- ~1 hour of unrushed time.

## Start

➡️ **[Step 1: Set up your deSEC account](01-deSEC-account.md)**

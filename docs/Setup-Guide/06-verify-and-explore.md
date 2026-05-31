# Step 6 — Verify & explore

> **Setup Guide** · Step 6 of 6 · ▰▰▰▰▰▰ 100% · ~53 min spent · ~2 min to go
> [← Step 5: Run homeserver.sh](05-run-setup.md) · **Step 6: Verify & explore**

You're ~2 minutes from a working homeserver. ☕

## Verify

### 1. Open the dashboard

From your **laptop's** browser:

```
https://<your-subdomain>.dedyn.io/
```

(Replace `<your-subdomain>` with what you chose in Step 1 —
e.g. `https://alice-home.dedyn.io/`.)

You should see:

- The **dashboard page** listing every service you deployed, with
  status / container image / volumes / last backup time.
- A **green padlock** in the address bar — no certificate
  warning, no "this site is unsafe" prompt.
- No need to install anything on your laptop. The certs are real
  Let's Encrypt; every device trusts them out of the box.

If you see a padlock — congratulations, you're done. 🎉

### Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| **DNS doesn't resolve** the subdomain | Your laptop isn't using Pi-hole as DNS, OR you haven't picked Pi-hole in the service list | Set your laptop's DNS to the homeserver's IP, or add the homeserver to your router's DHCP DNS server. |
| **Cert warning** | Caddy's first cert issuance hadn't completed yet when you opened the URL | Wait 1–2 min; reload. If still wrong, check `journalctl --user -u caddy -n 50` on the server for an ACME error. |
| **Some subdomains work, others fail with `SSL_ERROR_INTERNAL_ERROR_ALERT`** | One subdomain's cert hasn't been issued yet — Caddy issues one cert per name (apex + each reverse-proxied subdomain) and they trickle in on first deploy. | Wait ~2 min and reload. If still failing, check `sudo -u webproxy XDG_RUNTIME_DIR=/run/user/1011 podman logs caddy` for the failed name. Closes the apex+wildcard race that was [#170](https://github.com/luckynrslevin/home-server/issues/170). |
| **Connection refused** | Server's firewall not yet open on 443 | Re-run `homeserver.sh upgrade` on the server. |

## Explore

Click any tile on the dashboard to open that service's UI. A few
good first stops:

- **Pi-hole admin** (`https://pihole.<sub>.dedyn.io/admin`) — see
  the queries already being filtered. Log in with the admin
  password homeserver.sh generated and stored in your vault.
- **Syncthing** (`https://syncthing.<sub>.dedyn.io/`) — set up a
  folder share between this server and your laptop / phone.
- **Ente Photos** (`https://photos.<sub>.dedyn.io/`) — sign up
  inside the app (this is *your* instance), install the iOS or
  Android client, point it at your subdomain, start uploading.
- **Paperless-NGX** (`https://paperless.<sub>.dedyn.io/`) — log
  in with the admin credentials from your vault, drop a PDF into
  the consume folder, watch OCR + tagging happen.
- **Jellyfin** (`https://jellyfin.<sub>.dedyn.io/`) — point it at
  your media library (if you set up NFS in Step 3 / inventory),
  install the iOS / tvOS / Android client.
- **Music Assistant** (`https://music.<sub>.dedyn.io/`) — point
  it at your music collection in Jellyfin (built-in provider) and
  add streaming services.

## Optional — remote access via Tailscale

Want to reach your homeserver while travelling? Enable
**Tailscale** — it gives every device a stable IP on a private
mesh VPN, no router config, no port forwarding. Then
`https://paperless.<sub>.dedyn.io/` works from a café in Tokyo
the same as it works on your home Wi-Fi.

➡️ **[Tailscale-DNS-Setup.md](../Tailscale-DNS-Setup.md)** (~10 min
admin-console click-through)

## You're done

| Step | Status | Time |
|---|---|---|
| 1 — deSEC account | ✅ done | ~5 min |
| 2 — SMTP account | ✅ done | ~5 min |
| 3 — Install OS | ✅ done | ~20–60 min |
| 4 — SSH & sudo | ✅ done | ~3 min |
| 5 — Run homeserver.sh | ✅ done | ~20 min |
| 6 — Verify & explore | ✅ done | ~2 min |

Total: **~55–95 min** to your own homeserver. Welcome to owning
your data.

## Where to next

- **Add more devices** — install the Ente / Syncthing / Jellyfin /
  Music Assistant mobile apps, point them at your subdomain.
- **Add a service later** — `homeserver.sh add <service>` on the server.
  Run `homeserver.sh add` with no args to see what's available.
- **Upgrade** — `homeserver.sh upgrade` bumps to the latest release within
  the current major and re-runs ansible.
- **Backup / restore** — `homeserver.sh backup` triggers a backup now;
  `homeserver.sh restore` pulls the latest NAS backup.
- **Read the role docs** in `roles/<service>/README.md` for
  tuning knobs.
- **Watch the project repo** for new services landing (Nextcloud,
  Home Assistant, Mealie are on the roadmap).
- **Report any rough edges** — this is still an early-days
  project; PRs and issues welcome.

[← Back to the guide index](README.md)

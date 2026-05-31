# Tailscale split-DNS for the homeserver

Optional one-time setup for users who want to reach the homeserver
**from anywhere** (café Wi-Fi, mobile data, hotel) using the same
URLs as on the home LAN — `https://paperless.<sub>.dedyn.io/` etc.

This guide assumes:

- You've completed the [Setup Guide](Setup-Guide/README.md) — the
  homeserver is deployed, dashboards are reachable on your LAN.
- Tailscale is installed on the homeserver (the `os-tailscale` role
  is in your `platform_services` list with `tailscale_enabled: true`)
  and the box is logged into your tailnet.
- You have at least one device (laptop, phone) on the same tailnet.

## What this fixes

After the basic setup, your URLs work from home but not from the
road:

| Where you are | Tailscale on? | URL works? | Why |
|---|---|---|---|
| Home LAN | — | ✅ | Pi-hole resolves `*.<sub>.dedyn.io` to the homeserver's LAN IP. |
| Public Wi-Fi | ❌ | ❌ | Public DNS resolves to the LAN IP, which isn't routable from the internet. |
| Public Wi-Fi | ✅ | ❌ *(without this guide)* | Tailscale uses the laptop's local DNS, which goes to public DNS and lands on the same unreachable LAN IP. |
| Public Wi-Fi | ✅ | ✅ *(after this guide)* | Tailscale's split-DNS forwards `*.dedyn.io` to your homeserver's Pi-hole, which returns the LAN IP. The homeserver's tailnet subnet route delivers the packet over the tunnel. |

## Step 1 — Confirm the homeserver advertises its LAN subnet

The `os-tailscale` role already advertises the home LAN subnet via
`tailscale up --advertise-routes=<lan-cidr>`, but you need to
**approve** the route in the Tailscale admin console (one-time):

1. Open <https://login.tailscale.com/admin/machines>.
2. Find the homeserver in the machine list.
3. Click the `...` menu → **Edit route settings**.
4. Tick the box next to your LAN CIDR (e.g. `192.168.1.0/24`).
5. Save.

After this, any tailnet device knows: "to reach 192.168.1.x, send
the packet through the homeserver".

## Step 2 — Add the homeserver as a tailnet nameserver

Now tell every tailnet device to use the homeserver's Pi-hole for
the relevant queries.

1. Open <https://login.tailscale.com/admin/dns>.
2. Under **Nameservers**, click **Add nameserver** → **Custom**.
3. Enter the homeserver's **tailnet IP** (find it in
   <https://login.tailscale.com/admin/machines> — usually starts
   with `100.`). Note: do **not** use the LAN IP here; tailnet
   clients on the road can't reach LAN IPs except via the subnet
   route from Step 1, and the route's no good if you can't resolve
   the name in the first place.
4. **Important**: tick **Restrict to domain** and enter
   `<your-subdomain>.dedyn.io` (or just `dedyn.io` if you want all
   deSEC subdomains routed). This is the **Split DNS** mode — only
   queries for that domain go to your Pi-hole; everything else uses
   the device's normal DNS. **Do not** tick "Override local DNS"
   unless you specifically want all your tailnet devices' DNS
   centralized through your homeserver.
5. Save.

## Step 3 — Verify

From a tailnet-connected device on a different network (café,
phone hotspot), open a terminal:

```bash
# 1. Confirm name resolution goes to the LAN IP via Pi-hole.
dig +short paperless.<your-subdomain>.dedyn.io
# Expected: 192.168.1.<homeserver>  (your home LAN IP)

# 2. Confirm reachability via the subnet route.
ping -c 2 paperless.<your-subdomain>.dedyn.io
# Expected: replies from the homeserver
```

Then open `https://paperless.<your-subdomain>.dedyn.io/` in a
browser. Same URL, same green padlock, no warnings. ✅

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `dig` returns the public deSEC IP, not the LAN IP | Split-DNS rule isn't matching the domain you queried | Re-check the **Restrict to domain** field — it must be `<sub>.dedyn.io` (with subdomain) or `dedyn.io` (broad). |
| `dig` returns the LAN IP but the connection times out | Subnet route not approved | Step 1 — the LAN CIDR's checkbox must be ticked in the homeserver's machine settings. |
| Resolution works but the cert is wrong | Browser is using its own DNS-over-HTTPS, bypassing Tailscale | Disable DoH in the browser, or use a different browser. |
| Everything works on iOS/macOS but not on Android | Android caches DNS aggressively | Toggle airplane mode off/on, or restart the Tailscale app. |

## Why this is manual (not automated)

The Tailscale admin console has a REST API that can do all of the
above non-interactively, but it requires an org-level API key —
which is a significant trust step that doesn't fit the project's
"opinionated minimal config" pitch. A one-time browser session is
a fair price for never having to think about remote access again.

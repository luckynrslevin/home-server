# SSO bootstrap — Nextcloud as the OIDC Identity Provider

When you deploy **Nextcloud** with this project, it doubles as your
household's OpenID Connect Identity Provider for any other app that
can OIDC. Today: **Paperless-NGX**. Future: Jellyfin (via plugin),
Vaultwarden, anything else that supports the openid_connect backend.

The Nextcloud role pre-installs the `oidc` app, but **registering
each OIDC client and wiring its credentials into the consuming role
is a one-time manual step** per app — there's no public Nextcloud
API to create OIDC clients programmatically.

This doc walks the bootstrap for Paperless. The same pattern applies
to any other app you add later.

---

## Prerequisites

- Nextcloud deployed and reachable at `https://cloud.<caddy_domain>/`.
- You can log in as the `ncadmin` user (from
  `nextcloud_admin_password` in your inventory).
- The Paperless role is deployed (without OIDC yet) and reachable at
  `https://paperless.<caddy_domain>/`.

---

## Step 1 — Register the OIDC client in Nextcloud

1. Sign in to Nextcloud as `ncadmin`.
2. Top-right avatar → **Administrative settings** → left sidebar
   **Security** → scroll to **OpenID Connect 1.0**.
3. Click **Add client**.
4. Fill the form:

   | Field | Value |
   |---|---|
   | Name | `paperless` |
   | Redirection URI | `https://paperless.<caddy_domain>/accounts/oidc/nextcloud/login/callback/` |
   | Signing algorithm | **RS256** |
   | Client type | **Confidential** |

   The trailing slash on the redirect URI matters. The `nextcloud`
   segment after `/accounts/oidc/` is the `provider_id` the role
   hardcodes — leave it as `nextcloud`.

5. **Save**. Nextcloud generates a **Client ID** and **Client
   Secret**. Copy both immediately — the secret is shown once.

---

## Step 2 — Add the credentials to inventory

In your private overlay's
`inventory/host_vars/<host>/apps/paperless-ngx.yml`:

```yaml
paperless_oidc_enabled: true
paperless_oidc_client_id: "<paste client ID>"
paperless_oidc_provider_url: "https://cloud.<caddy_domain>"
paperless_oidc_client_secret: !vault | ...
```

Vault-encrypt the secret before pasting:

```bash
cd ~/home-server   # or wherever vault.pw is wired up
ansible-vault encrypt_string --encrypt-vault-id default \
    --stdin-name 'paperless_oidc_client_secret'
# paste the secret, then Ctrl-D
```

Copy the YAML block it prints into the inventory.

Commit + push:

```bash
cd ~/github/home-server-private
git add -A && git commit -m "<host>: enable Paperless OIDC via Nextcloud"
git push origin main
```

---

## Step 3 — Redeploy Paperless

```bash
cd ~/home-server
ansible-playbook playbooks/paperless-ngx.yml --limit <host>
```

The container picks up the new `PAPERLESS_APPS` + `PAPERLESS_SOCIALACCOUNT_PROVIDERS`
+ `PAPERLESS_REDIRECT_LOGIN_TO_SSO` env vars and starts redirecting
visitors to Nextcloud for login.

---

## Step 4 — End-to-end login test

In a fresh private window:

1. Open `https://paperless.<caddy_domain>/` → should redirect to
   `https://cloud.<caddy_domain>/login` (Nextcloud).
2. Log in as `ncadmin` (or any Nextcloud user).
3. First time only: Nextcloud shows a consent screen for the
   `paperless` client. Approve.
4. Redirected back to Paperless, **auto-logged-in as a new
   Paperless local user** named after the Nextcloud username (e.g.
   `ncadmin`).

If you see HTTP 403 on `/api/ui_settings/` after login, the
auto-provisioned user has no permissions yet — see Step 5.

---

## Step 5 — Grant the new user admin (per-user, one-time)

Paperless creates OIDC users without `is_staff` / `is_superuser`
flags. Most of the UI returns 403 until they're promoted. For each
user that should be admin:

```bash
ssh <host> "sudo -u paperless XDG_RUNTIME_DIR=/run/user/1007 \
    podman exec paperless-ngx python manage.py shell -c \
    \"from django.contrib.auth.models import User; \
    u=User.objects.get(username='<nextcloud-username>'); \
    u.is_superuser=True; u.is_staff=True; u.save(); print('promoted')\""
```

For users you want to keep as regular (non-admin), skip this step.

---

## Fallback: local login still works

If OIDC / Nextcloud is ever down or the SSO redirect misbehaves,
the local Paperless `admin` user from the original install still
works. Bypass the auto-redirect with the `?process=login` query
parameter:

```
https://paperless.<caddy_domain>/accounts/login/?process=login
```

Useful for emergency access and for the very first deploy when
you need to promote your first OIDC user before they have UI access.

---

## Adding more OIDC apps later

Repeat Steps 1–4 for each app. Each app gets its own
**Client ID** + **Client Secret** in Nextcloud, its own `*_oidc_*`
inventory vars, and its own `provider_id` in the role template.
The Nextcloud side doesn't need redeploy — only the consuming app.

For Jellyfin specifically, the OIDC integration goes through the
[`jellyfin-plugin-sso`](https://github.com/9p4/jellyfin-plugin-sso)
plugin. That role hasn't grown the integration yet; track as a
follow-up when family-profile separation in Jellyfin becomes useful.

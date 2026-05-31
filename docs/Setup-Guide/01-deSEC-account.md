# Step 1 — Set up your deSEC account

> **Setup Guide** · Step 1 of 6 · ▰▱▱▱▱▱ 17% · ~0 min spent · ~55 min to go
> **Step 1: deSEC account** · [Step 2: SMTP account →](02-smtp-account.md)

This is the only manual sign-up in the whole guide. ~5 minutes.

## Why deSEC

We use **deSEC** (a German non-profit DNS host) for two things:

- A free `*.dedyn.io` subdomain — your homeserver's permanent
  address.
- An API token that lets the homeserver automatically request
  real Let's Encrypt certificates (so every URL has a green
  padlock, no per-device CA install).

Why deSEC specifically over alternatives: non-profit, EU-hosted,
DNSSEC by default, scoped API tokens, and a clean upgrade path if
you later want to bring your own domain.

## What you'll do

### 1. Create an account

- Open <https://desec.io/> in your browser.
- Click **Create Account** button in the top menue.
  - Enter your email
  - chose "No, I'll add one later"
  - fill in CAPTCHA
  - accept the terms & sign up
  - Open the verification email from deSEC, click the confirmation link.
  - Afterwards you will get a second email with a link to set your password (valid 24 hours).

(~2 min.)

### 2. Claim a dedyn.io subdomain

After creating your account create your domain:
  - Open <https://desec.io/> and click **Log In** button and log in with your username and password.
  - Click "Domain Management" and **&#10753;** button to add a new domain
  - Type in the domain you want, e.g. if you would like to register **mydomain**, type in **mydomain.dedyn.io** and register.
  - If it's taken, pick another and re-check.

You now own `mydomain.dedyn.io` and any subdomain under it
(`pihole.mydomain.dedyn.io`, `paperless.mydomain.dedyn.io`,
etc.) — Caddy will mint one Let's Encrypt cert per name (apex
+ each subdomain) via DNS-01 against deSEC in Step 4.

(~1 min.)

### 3. Create an API token

After creating your domain, you need to create a API token caddy can use to automatically request creation
of Let's Encrypt SSL certificates.
- Click "Token Management" and **&#10753;** button to add a new API token
- Give it a descriptive name like `homeserver`.
- Leave the default permissions.
- Click **Save**.

> [!IMPORTANT]  
> **Copy the token now** to a password manager or a temporary 
> note — **deSEC shows it only once**.

(~1 min.)

## Keep these two values

You'll paste them into `homeserver.sh` in Step 5:

| | Example |
|---|---|
| **Subdomain** (without `.dedyn.io`) | `alice-home` |
| **API token** | a long opaque string |

## Time check

| Step | Status | Time |
|---|---|---|
| 1 — deSEC account | ✅ done | ~5 min |
| 2 — SMTP account | next | ~5 min |
| 3 — Install OS | | ~20–60 min |
| 4 — SSH & sudo | | ~3 min |
| 5 — Run homeserver.sh | | ~20 min |
| 6 — Verify & explore | | ~2 min |

➡️ **[Step 2: Set up an SMTP relay account](02-smtp-account.md)**

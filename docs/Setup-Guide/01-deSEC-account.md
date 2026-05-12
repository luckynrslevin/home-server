# Step 1 — Set up your deSEC account

> **Setup Guide** · Step 1 of 5 · ▰▱▱▱▱ 20% · ~0 min spent · ~50 min to go
> **Step 1: deSEC account** · [Step 2: Install OS →](02-install-os.md)

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
- Click **Sign Up**.
  - Enter your email
  - chose "No, I'll add one later"
  - fill in CAPTCHA
  - accept the terms & sign up
- Open the verification email from deSEC, click the confirmation link.

(~2 min.)

### 2. Claim a subdomain

After confirming your email and signing in, deSEC asks:

> **Do you want to set up a domain right away?**
> a) Configure your own domain (Managed DNS or dynDNS)
> b) Register a new domain under dedyn.io (DynDNS)
> c) No, I'll add one later

Pick **(b) Register a new domain under dedyn.io (DynDNS)**.

- Type the subdomain you want — for example, `alice-home`.
- Click **Check availability**. If it's taken, pick another and
  re-check.
- Confirm to claim `alice-home.dedyn.io`.

You now own `alice-home.dedyn.io` and any subdomain under it
(`pihole.alice-home.dedyn.io`, `paperless.alice-home.dedyn.io`,
etc.) — Caddy will mint a wildcard cert covering all of them in
Step 4.

(~1 min.)

### 3. Create an API token

deSEC's web UI shows your domain's dashboard after Step 2.

- Open the **Token Management** page from the top-right account
  menu (user icon → Token Management).
- Click **Create new token**.
- Give it a descriptive name like `homeserver`.
- Leave the default permissions (full account scope) unless you
  know you want to restrict it.
- Click **Save**.

> [!IMPORTANT]  
> **Copy the token now** to a password manager or a temporary 
> note — **deSEC shows it only once**.

(~1 min.)

## Keep these two values

You'll paste them into `setup.sh` in Step 4:

| | Example |
|---|---|
| **Subdomain** (without `.dedyn.io`) | `alice-home` |
| **API token** | a long opaque string |

## Time check

| Step | Status | Time |
|---|---|---|
| 1 — deSEC account | ✅ done | ~5 min |
| 2 — Install OS | next | ~20–60 min |
| 3 — SSH & sudo | | ~3 min |
| 4 — Run setup.sh | | ~20 min |
| 5 — Verify & explore | | ~2 min |

➡️ **[Step 2: Install the OS](02-install-os.md)**

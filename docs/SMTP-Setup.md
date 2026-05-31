# SMTP relay setup

A working outbound SMTP relay lets the homeserver's apps send email
for things like:

- Account invitations and password reset links (Nextcloud, Paperless)
- Email-verification one-time-passwords (Ente Photos)
- Share notifications (Nextcloud)
- Alerts and audit notifications (future)

The project consumes SMTP via a small set of host-level inventory
vars (issue [#153]) — set them once per host and any role that wants
to send mail picks them up.

This doc walks you through the recommended provider (Mailbox.org)
and the minimal inventory wiring.

> [!NOTE]
> Self-hosting a Postfix MTA on the homeserver is **not** recommended.
> Residential IP ranges are on most spam blocklists, port 25 is
> commonly blocked outbound by ISPs, and you'd need to manage SPF /
> DKIM / DMARC records yourself. Use a relay.

---

## Picking a provider

| Provider | Where | Cost | Notes |
|---|---|---|---|
| **Mailbox.org** (recommended) | Berlin 🇩🇪 | €1/mo (Mail Light) | Privacy-first, transparent ownership. App-password support. ~500 mails/day cap is huge for household scale. |
| **Posteo** | Berlin 🇩🇪 | €1/mo | Similar to Mailbox.org, climate-neutral framing. Equally fine. |
| **IONOS Mail** | DE | included with hosting / domain | Mass-market hoster. Less privacy-focused but works. |
| **Brevo** (ex-Sendinblue) | France 🇪🇺 | 300/day free, paid above | Transactional-only (no inbox). Needs sender-domain DKIM setup. Overkill for household. |
| **AWS SES Frankfurt** | DE region 🇪🇺 | ~$0.10 per 1000 mails | Cheapest at scale; more setup. Overkill for household. |

If you already have a personal Mailbox.org or Posteo account, **just
reuse it** — generate an app-specific password so you can revoke it
without touching your main login.

---

## Mailbox.org — generate an app password

App passwords let an external app (the homeserver) authenticate to
SMTP without seeing your main account password. They're scoped, named,
and individually revocable. Recommended even (especially) when 2FA is
enabled on your account.

1. Sign in at <https://login.mailbox.org/>.
2. Top-right: click your initials / avatar → **Einstellungen** (Settings).
3. Left sidebar: **Sicherheit** (Security) → **App-Passwörter** (App passwords).
4. **+ App-Passwort erstellen** (Create app password).
5. If 2FA is on, you'll be prompted for your TOTP code.
6. Label: e.g. `homeserver-smtp` so you remember what's using it later.
7. Scope: **Mail** (or "Alle" / "All" if your UI doesn't split).
8. **Erstellen** (Create).
9. **Copy the displayed password immediately** — it's shown only once.
   Paste into your password manager and into the inventory vault step
   below.

If "App-Passwörter" doesn't appear in the menu, 2FA isn't enabled on
your account. Mailbox.org will accept your main password for SMTP, but
the cleaner path is: turn on 2FA first, then generate an app password.

---

## Inventory configuration

Add these vars to `inventory/host_vars/<host>/30-smtp.yml` (in
your private overlay — or use `homeserver.sh config smtp` to open
it in your `$EDITOR` and auto-apply via `playbooks/site.yml`):

```yaml
##################################################################################################
### SMTP relay (project-level — used by Nextcloud, Ente, Paperless, …)
smtp_host: "smtp.mailbox.org"
smtp_port: 587
smtp_username: "you@mailbox.org"
smtp_encryption: "starttls"           # "starttls" for 587; "ssl" for 465
smtp_from: "homeserver@yourdomain"    # appears as From: on outgoing mail
smtp_password: !vault | ...           # vault-encrypt the app password
```

Vault-encrypt the password before pasting:

```bash
ansible-vault encrypt_string \
  --encrypt-vault-id default \
  --stdin-name 'smtp_password'
# paste the app password, then Ctrl-D
# copy the YAML block it prints into the inventory under smtp_password:
```

### Provider-specific notes

| Provider | `smtp_host` | `smtp_port` | `smtp_encryption` |
|---|---|---|---|
| Mailbox.org | `smtp.mailbox.org` | `587` | `starttls` |
| Posteo | `posteo.de` | `587` | `starttls` |
| IONOS | `smtp.ionos.de` | `587` | `starttls` |
| Brevo | `smtp-relay.brevo.com` | `587` | `starttls` |
| AWS SES eu-central-1 | `email-smtp.eu-central-1.amazonaws.com` | `587` | `starttls` |

`smtp_from` should be a real address you control. For Mailbox.org with
no custom domain, just use your mailbox address itself
(`you@mailbox.org`). With a custom domain pointed at Mailbox.org, you
can use anything at that domain.

---

## Verification

After setting the vars and re-running the role(s) that consume SMTP
(Nextcloud, Ente, Paperless), the easiest end-to-end test is to
trigger a real email:

- **Nextcloud**: Settings → Personal → Email → "Send test email" button.
- **Paperless**: try the password-reset flow on the login page (you'll
  receive a reset link if SMTP works).
- **Ente**: signup with a fresh email (verification OTP delivered).

If a test fails, check:

```bash
# On the host, look for SMTP errors in the relevant container's logs:
sudo -u <svcuser> XDG_RUNTIME_DIR=/run/user/$(id -u <svcuser>) \
    podman logs <container> 2>&1 | grep -iE 'smtp|mail|tls' | tail -20
```

Common issues:

| Symptom | Likely cause |
|---|---|
| `535 Authentication failed` | Wrong app-password, or `smtp_username` is wrong (must be the full email). |
| `Connection refused` | Wrong port, or your egress firewall blocks outbound 587. |
| Email "sent" but never arrives | Check the from-address matches a real account at the relay; check spam folder; check recipient's spam policy on the from-domain. |

---

## Rotation

If the app password leaks or the homeserver is rebuilt:

1. Mailbox.org webmail → Sicherheit → App-Passwörter → revoke the old one.
2. Generate a new one, label it the same (`homeserver-smtp`).
3. Re-vault-encrypt and replace the value in inventory.
4. Re-run any role that consumes SMTP (or `playbooks/site.yml`).

The main account password is never touched.

---

## See also

- [#153](https://github.com/luckynrslevin/home-server/issues/153) — tracking issue for project-level SMTP wiring.
- [#148](https://github.com/luckynrslevin/home-server/issues/148) — Ente self-host UX, where SMTP is one of the planned fixes.

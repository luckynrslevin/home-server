# Step 2 — Set up an SMTP relay account

> **Setup Guide** · Step 2 of 6 · ▰▰▱▱▱▱ 33% · ~5 min spent · ~50 min to go
> [← Step 1: deSEC account](01-deSEC-account.md) · **Step 2: SMTP account** · [Step 3: Install OS →](03-install-os.md)

The homeserver sends email for things like Nextcloud invitations,
Paperless password resets, Ente verification codes, and (in the
future) backup-failure alerts. It does that through a real mail
provider — no Postfix on the box, no fighting residential-IP
blocklists.

If you already have a personal Mailbox.org / Posteo / IONOS account,
just generate an app-specific password and reuse it. Otherwise pick
one below.

## Pick a provider

| Provider | App password / SMTP user | SMTP host & port |
|---|---|---|
| **Mailbox.org** (recommended) | [Change e-mail password / app password](https://kb.mailbox.org/de/privat/sicherheit-privatsphaere/e-mail-passwort/) | [Server, ports, encryption](https://kb.mailbox.org/de/privat/e-mail/e-mail-konfiguration/#3-postausgangsserver-ports-und-verschl%C3%BCsselung) |
| **Posteo** | [Account password / 2FA setup](https://posteo.de/hilfe/wie-andere-mein-passwort) | [SMTP server settings](https://posteo.de/hilfe/welche-einstellungen-brauche-ich-fuer-imap-pop3-und-smtp) |
| **IONOS Mail** | [Mailbox password](https://www.ionos.de/hilfe/e-mail/allgemeine-themen/mailbox-passwort-aendern/) | [Server data for mail programs](https://www.ionos.de/hilfe/e-mail/allgemeine-themen/serverdaten-fuer-e-mail-programme/) |

> [!TIP]
> Use an **app-specific password** wherever the provider supports it
> (Mailbox.org does). It's scoped, named, and individually revocable
> — so if the homeserver is ever rebuilt or lost, you can revoke just
> that one credential without touching your main account.

For a deeper write-up, including provider comparison and per-app
notes, see **[docs/SMTP-Setup.md](../SMTP-Setup.md)**.

## Keep these five values

You'll paste them into `homeserver.sh` in Step 5:

| | Example |
|---|---|
| **smtp_host** | `smtp.mailbox.org` |
| **smtp_port** | `587` |
| **smtp_username** | `you@example.org` |
| **smtp_from** | `you@example.org` (usually the same as username) |
| **smtp_password** | the app password from the table above |

## Time check

| Step | Status | Time |
|---|---|---|
| 1 — deSEC account | ✅ done | ~5 min |
| 2 — SMTP account | in progress | ~5 min |
| 3 — Install OS | next | ~20–60 min |
| 4 — SSH & sudo | | ~3 min |
| 5 — Run homeserver.sh | | ~20 min |
| 6 — Verify & explore | | ~2 min |

➡️ **[Step 3: Install the OS](03-install-os.md)**

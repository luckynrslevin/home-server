# Step 4 — Run setup.sh

> **Setup Guide** · Step 4 of 5 · ▰▰▰▰▱ 80% · ~28 min spent · ~22 min to go
> [← Step 3: SSH & sudo](03-ssh-and-sudo.md) · **Step 4: Run setup.sh** · [Step 5: Verify →](05-verify-and-explore.md)

The longest step (~20 min), but most of it is unattended. ~3
minutes of your attention up front, ~17 minutes of "container
images pull and services start" you can use to make coffee.

## Heads-up on the prompts

`setup.sh` is interactive. It will ask you for:

| Prompt | What to paste | From Step |
|---|---|---|
| **deSEC subdomain** (without `.dedyn.io`) | `alice-home` | 1 |
| **deSEC API token** | the long opaque string | 1 |
| **Which services to deploy?** | y/N per service (defaults are sensible) | — |

Have your deSEC values from Step 1 ready in your clipboard /
notes.

## Run setup.sh

In your SSH session on the server:

```bash
curl -fsSL https://raw.githubusercontent.com/luckynrslevin/home-server/main/setup.sh \
  -o /tmp/setup.sh && bash /tmp/setup.sh
```

> [!IMPORTANT]
> Run this **on the server** (i.e. inside the SSH session from
> Step 3) — not on your laptop. **The script provisions the
> machine it runs on.**

### What you'll see

Roughly in order:

1. **Prereqs install** — Ansible, podman, python3.11, EPEL — about
   ~1 min.
2. **Repo clone** — pulls this project into `~/home-server`.
3. **Vault setup** — generates or asks for a vault password
   (encrypts your deSEC token at rest).
4. **The prompts** — server IP, hostname, deSEC subdomain + token,
   service picker.
5. **Deploy** — Ansible runs. **~15–20 min**. You can step away;
   the script doesn't need more input after the prompts.

## What setup.sh does behind the scenes

- Writes the wildcard A record (`*.<sub>.dedyn.io → <server LAN
  IP>`) to deSEC via API. (One less manual step in the deSEC
  dashboard.)
- Generates your inventory file under
  `~/home-server/inventory/host_vars/homeserver/main.yml`,
  including vault-encrypted secrets for every service.
- Runs `ansible-playbook playbooks/site.yml --connection=local`
  against your box, deploying every role you picked.
- Caddy issues a wildcard Let's Encrypt cert for
  `*.<sub>.dedyn.io` via DNS-01 against deSEC — no inbound port
  forwarding needed.
- Pi-hole gets a wildcard local DNS record so LAN clients resolve
  the subdomain to your homeserver's IP.

## Time check

| Step | Status | Time |
|---|---|---|
| 1 — deSEC account | ✅ done | ~5 min |
| 2 — Install OS | ✅ done | ~20–60 min |
| 3 — SSH & sudo | ✅ done | ~3 min |
| 4 — Run setup.sh | in progress | ~20 min |
| 5 — Verify & explore | next | ~2 min |

➡️ **[Step 5: Verify & explore](05-verify-and-explore.md)**

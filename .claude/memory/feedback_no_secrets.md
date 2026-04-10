---
name: Never push secrets or host-specific values
description: CRITICAL — never push credentials, passwords, keys, OR host-specific identifiers (hostnames, LAN IPs) to the public repo
type: feedback
---

NEVER push to the public `home-server` repo: (a) any security-relevant information — passwords, API keys, tokens, private keys, vault passwords — OR (b) any host-specific identifiers — real hostnames (e.g. `ds9`, `eddie`), LAN IPs (e.g. `192.168.1.184`), real URLs, NAS volume paths, etc.

**Why:** The repo is public on GitHub. Credentials in version control are a direct security risk; host-specific values leak LAN topology and break the repo's reusability for other users cloning it. The repo has a private overlay at `home-server-private/` containing `inventory/host_vars/homeserver.yml` and `roles/dashboard/files/dashboard-config.yaml` for exactly this purpose.

**How to apply:**

Before writing or committing any file in the public repo, scan for:
1. **Secrets**: passwords, tokens, API keys, private key material, vault passwords. If found, STOP, warn, and ask how to handle (Ansible Vault, .gitignore, env file).
2. **Host-specific identifiers**: real hostnames, real LAN IPs, real NAS paths, real domain names. If you're about to hardcode one in the public repo, STOP and move it to either:
   - `roles/<role>/defaults/main.yml` with a *placeholder* value (e.g. `nas`, `192.168.x.x`, `/volume1`) and a comment saying "override per-host in inventory"
   - The real value in `home-server-private/inventory/host_vars/homeserver.yml`
   - Scripts with host-specific config should be deployed as `.j2` templates (not static `files/`), with values coming from role defaults overridden in host_vars.
3. **`.example` files** in the public repo should use placeholders like `192.168.x.x` or `nas.example`, never real values.
4. `vault.pw` is already gitignored; never commit it.

When auditing at commit time, grep the staged diff for literal strings that look like LAN IPs (`192.168.`, `10.`, `172.16.`) and for any hostname you've seen in conversation. A clean public repo should grep-match zero of them.

**Known pre-existing exception:** `.claude/strategy.md` mentions the hostname `eddie` from the initial commit. Don't touch without user direction — it's a strategy doc the user wrote intentionally.

---
name: Never push secrets
description: CRITICAL — never push credentials, passwords, API keys, or vault passwords to the repo
type: feedback
---

NEVER push security-relevant information to the GitHub repository. This includes passwords, API keys, tokens, private keys, vault passwords, and any other credentials.

**Why:** The repo is on GitHub and secrets in version control are a serious security risk.

**How to apply:** Before every commit, check all staged files for hardcoded credentials. If any are found, STOP and warn the user, then ask how to handle it (e.g., Ansible Vault, .gitignore, environment files). This applies to all files including container definitions, config templates, and variable files. The `vault.pw` file is already in `.gitignore`.

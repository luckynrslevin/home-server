---
name: Never modify Galaxy roles in-place
description: CRITICAL — Galaxy roles (like luckynrslevin.podman_quadlet) must only be changed via their own git repo and released properly
type: feedback
---

NEVER modify, copy, or install Galaxy roles into the home-server repo's `roles/` directory. The `roles/` directory is for this project's own roles only.

**Why:** Galaxy roles are managed dependencies installed via `ansible-galaxy install -r roles/requirements.yml`. They belong in `.ansible/roles/` (which is gitignored). Putting them in `roles/` creates confusion about what's a local role vs a dependency, and any changes get overwritten on the next `ansible-galaxy install --force`.

**How to apply:**
- If a Galaxy role needs a bug fix, make the change in the role's **own git repo** (e.g., `github.com/luckynrslevin/ansible-role-podman-quadlet`), release a new version, and update `requirements.yml`.
- NEVER edit files under `.ansible/roles/luckynrslevin.*` as a "quick fix" — those changes are lost on reinstall.
- NEVER copy Galaxy role files into `roles/` — even temporarily.
- If testing a Galaxy role change, use the role's own repo with molecule tests, not the home-server project.
- The `roles_path` in `ansible.cfg` searches `./roles` first, then `./.ansible/roles` — so a role in `roles/` would shadow the Galaxy-installed one silently. This is dangerous.

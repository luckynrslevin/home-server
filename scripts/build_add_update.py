#!/usr/bin/env python3
"""
scripts/build_add_update.py — translate a role's meta/install.yml into
the update.json that scripts/inventory_merge.py consumes for add mode.

Resolves each declared inventory_var:
  - secret        → run `generator` (shell command); emit vaulted scalar
  - secret_prompt → operator supplies the value (e.g. existing account
                    password). Caller passes via --prompted-secrets;
                    if absent, build_add_update.py exits 3 and prints
                    the list of needed prompts on stdout (machine
                    readable) so the wrapper can collect them and
                    re-invoke.
  - config        → leave for setup.sh's interactive prompt (skipped
                    here; caller supplies via --extra-overrides if
                    non-interactive)
  - computed      → render `template` Jinja against existing inventory
  - literal       → emit value verbatim

Side-effects → list/dict update entries (caddy_reverse_proxy_services,
my_linux_users). The service name itself is always appended to
deploy_services.

Inventory_vars already set in inventory are skipped (idempotent;
won't regenerate secrets or re-render computed values).

Usage:
    build_add_update.py --meta roles/nextcloud/meta/install.yml
                        --service nextcloud
                        --vault-password-file ~/.vaultpw
                        --target-host homeserver2
                        [--inventory-dir inventory]
                        [--overrides key1=val1 key2=val2]
                        --output /tmp/update.json
"""

import argparse
import json
import os
import shutil
import subprocess
import sys


def load_existing_inventory(target, vault_pw, inventory_dir):
    """Get target host's current inventory as a dict (with vault dicts
    still wrapped — we only need to check key presence for idempotency
    and to render computed templates against scalar values)."""
    env = {**os.environ, "ANSIBLE_VAULT_PASSWORD_FILE": vault_pw}
    if inventory_dir:
        env["ANSIBLE_INVENTORY"] = os.path.join(inventory_dir, "hosts.yml")
    try:
        result = subprocess.run(
            ["ansible-inventory", "--host", target],
            capture_output=True, text=True, check=True, env=env,
        )
    except subprocess.CalledProcessError:
        return {}
    if not result.stdout.strip():
        return {}
    return json.loads(result.stdout)


def render_template(template_str, ctx):
    """Render a small Jinja-like template. Uses jinja2 if available
    (ansible-core depends on it so it should be on PATH), otherwise
    falls back to str.format-style {key} substitution."""
    try:
        from jinja2 import Template
        return Template(template_str).render(**ctx)
    except ImportError:
        # Crude fallback — operators using `computed` vars need jinja2.
        return template_str.format(**ctx)


def resolve_secret(generator):
    """Run a shell generator command and return its stripped stdout."""
    result = subprocess.run(
        ["sh", "-c", generator],
        capture_output=True, text=True, check=True,
    )
    return result.stdout.rstrip("\n")


def _sh(cmd):
    """Run a shell command; return stripped stdout, empty on failure."""
    try:
        r = subprocess.run(
            ["sh", "-c", cmd], capture_output=True, text=True, check=True,
        )
        return r.stdout.strip()
    except Exception:
        return ""


def host_detect(key):
    """Resolve a `host_detect:<key>` default value from system state.
    Mirrors the host-detect logic in setup.sh's install verb so
    `setup.sh add <svc>` on a fresh host gets the same auto-resolution.
    """
    if key == "lan_subnet":
        iface = _sh("ip route show default 2>/dev/null | awk '{print $5; exit}'")
        if not iface:
            return ""
        cidr = _sh(
            f"ip -4 addr show {iface} 2>/dev/null | grep inet | "
            "awk '{print $2}' | head -1"
        )
        # Normalise host IP/CIDR (e.g. 192.168.1.5/24) → subnet CIDR.
        if "/" not in cidr:
            return cidr
        ip, prefix = cidr.split("/", 1)
        octets = ip.split(".")
        if len(octets) == 4:
            return f"{octets[0]}.{octets[1]}.{octets[2]}.0/{prefix}"
        return cidr
    if key == "lan_gateway":
        return _sh("ip route show default 2>/dev/null | awk '{print $3; exit}'")
    if key == "timezone":
        return _sh("timedatectl show -p Timezone --value 2>/dev/null") or "UTC"
    if key == "hostname":
        return _sh("hostname -s 2>/dev/null")
    if key == "server_user":
        return _sh("whoami 2>/dev/null")
    return ""


def resolve_config_default(default):
    """A `config`-type var's default is either a literal string or a
    `host_detect:<key>` spec. Resolve to a concrete value."""
    if isinstance(default, str) and default.startswith("host_detect:"):
        return host_detect(default.split(":", 1)[1])
    return default if default is not None else ""


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--meta", required=True)
    p.add_argument("--service", required=True)
    p.add_argument("--vault-password-file", required=True)
    p.add_argument("--target-host", required=True)
    p.add_argument("--inventory-dir", default="inventory")
    p.add_argument("--overrides", nargs="*", default=[],
                   help="key=value pairs to use for `config`-type vars")
    p.add_argument("--prompted-secrets", nargs="*", default=[],
                   help="key=value pairs supplying operator-provided "
                        "secrets for `secret_prompt`-type vars")
    p.add_argument("--output", required=True)
    args = p.parse_args()

    # Load meta
    try:
        import yaml
    except ImportError:
        print("ERROR: PyYAML not available.", file=sys.stderr)
        sys.exit(1)
    with open(args.meta) as f:
        meta = yaml.safe_load(f)

    # Parse overrides into a dict
    overrides = {}
    for kv in args.overrides:
        if "=" in kv:
            k, v = kv.split("=", 1)
            overrides[k] = v
    prompted = {}
    for kv in args.prompted_secrets:
        if "=" in kv:
            k, v = kv.split("=", 1)
            prompted[k] = v

    # Existing inventory (for idempotency + computed-template context)
    existing = load_existing_inventory(
        args.target_host, args.vault_password_file, args.inventory_dir,
    )

    # Resolve inventory_vars
    scalars = {}
    config_needed = []  # config-type vars not in inventory or overrides
    prompt_needed = []  # secret_prompt vars not in inventory or --prompted-secrets
    for var in meta.get("inventory_vars", []) or []:
        name = var["name"]
        vtype = var["type"]
        if name in existing:
            continue  # already set, don't clobber
        if name in overrides:
            scalars[name] = {"value": overrides[name], "vault": False}
            continue
        if name in prompted:
            scalars[name] = {"value": prompted[name], "vault": var.get("vault", True)}
            continue
        if vtype == "secret":
            value = resolve_secret(var["generator"])
            scalars[name] = {"value": value, "vault": var.get("vault", True)}
        elif vtype == "secret_prompt":
            prompt_needed.append(var)
        elif vtype == "computed":
            value = render_template(var["template"], existing)
            scalars[name] = {"value": value, "vault": False}
        elif vtype == "literal":
            scalars[name] = {"value": var["value"], "vault": False}
        elif vtype == "config":
            # Auto-resolve via host_detect or literal default. Only
            # fall through to config_needed if there's no default to
            # work with (operator must supply via --overrides).
            resolved = resolve_config_default(var.get("default"))
            if resolved:
                scalars[name] = {"value": resolved, "vault": False}
            else:
                config_needed.append(var)
        else:
            print(f"ERROR: unknown var type {vtype!r} for {name!r}", file=sys.stderr)
            sys.exit(1)

    if config_needed:
        print("ERROR: the following `config`-type vars need values but"
              " weren't found in inventory or --overrides:", file=sys.stderr)
        for var in config_needed:
            prompt = var.get("prompt", var["name"])
            print(f"  --overrides {var['name']}=<...>  ({prompt})", file=sys.stderr)
        sys.exit(2)

    if prompt_needed:
        # Machine-readable on stdout, human-readable on stderr.
        # Wrapper (setup.sh add) reads stdout to know which prompts
        # to ask the operator for, then re-invokes with --prompted-secrets.
        print("PROMPTS_NEEDED")
        for var in prompt_needed:
            prompt_text = var.get("prompt", var["name"])
            confirm = "true" if var.get("confirm", False) else "false"
            # `mask` controls echo: true = hide input (passwords).
            # Default true since `secret_prompt` is intended for secrets;
            # roles set `mask: false` on visible fields like email.
            mask = "true" if var.get("mask", True) else "false"
            # name<TAB>prompt_text<TAB>confirm<TAB>mask
            print(f"{var['name']}\t{prompt_text}\t{confirm}\t{mask}")
        sys.exit(3)

    # Side effects → lists + dicts
    lists = {}
    dicts = {}
    side = meta.get("side_effects") or {}

    # Post platform/apps split: append the service name to whichever list
    # it belongs to. Platform service names are canonical (see
    # PLATFORM_SERVICES_CANON in homeserver.sh); everything else is an app.
    _PLATFORM = {"caddy", "dashboard", "pihole", "backup", "os-tailscale"}
    _list_name = "platform_services" if args.service in _PLATFORM else "apps"
    lists[_list_name] = {"items": [args.service]}

    if "caddy_reverse_proxy_services" in side:
        lists["caddy_reverse_proxy_services"] = {
            "items": side["caddy_reverse_proxy_services"],
        }
    if "my_linux_users" in side:
        dicts["my_linux_users"] = {"entries": side["my_linux_users"]}

    update = {"scalars": scalars, "lists": lists, "dicts": dicts}
    with open(args.output, "w") as f:
        json.dump(update, f, indent=2)


if __name__ == "__main__":
    main()

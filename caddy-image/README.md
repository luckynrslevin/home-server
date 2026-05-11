# caddy-image — custom Caddy build with DNS plugins

This directory holds the Dockerfile and CI workflow that produces
**`ghcr.io/luckynrslevin/caddy-acme`**, the Caddy image the
`caddy` role pulls. It's the same upstream `caddy:latest` plus
three DNS-01 ACME provider plugins compiled in via `xcaddy`:

| Plugin | When you need it |
|---|---|
| `caddy-dns/desec` | Default platform path (free `*.dedyn.io` subdomain). |
| `caddy-dns/cloudflare` | Bring-your-own domain hosted at Cloudflare DNS. |
| `caddy-dns/hetzner` | Bring-your-own domain hosted at Hetzner DNS. |

## How it builds

[`.github/workflows/caddy-build.yml`](../.github/workflows/caddy-build.yml)
triggers on:

- pushes to `main` that touch `caddy-image/**` or the workflow file,
- a weekly cron (Monday 04:00 UTC) so we pick up upstream Caddy
  point releases,
- manual `workflow_dispatch`.

It builds for `linux/amd64` + `linux/arm64`, pushes to GHCR with
two tags:

- `latest` — always the most recent successful build.
- `<run-number>` — immutable build identifier for rollback.

## Adding a new DNS provider

1. Add another `--with github.com/caddy-dns/<provider>` line to
   the Dockerfile.
2. Commit + push to a branch + open PR. The workflow's
   `paths` trigger means CI builds + tests the image on the PR.
3. After merge to `main`, the production tag updates.

## Verifying locally

```bash
docker build -t caddy-acme-local ./caddy-image
docker run --rm caddy-acme-local caddy list-modules | grep dns.providers
```

Expected output includes `dns.providers.desec`,
`dns.providers.cloudflare`, `dns.providers.hetzner`.

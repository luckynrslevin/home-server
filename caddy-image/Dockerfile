# Custom Caddy image with bundled DNS-01 ACME provider plugins.
#
# Why this exists:
#   The official `caddy:latest` image doesn't include any DNS provider
#   plugins, so Caddy can't run the DNS-01 ACME challenge — the
#   platform's only supported cert path. Bundle the three providers
#   we support so any of them works without a per-user rebuild:
#     - deSEC      (default — free *.dedyn.io subdomain)
#     - Cloudflare (BYO domain, most popular DNS host)
#     - Hetzner DNS (BYO domain, second-most-popular)
#
# Add more providers by extending the xcaddy line below; the image
# rebuilds automatically via .github/workflows/caddy-build.yml.

FROM caddy:builder AS builder
RUN xcaddy build \
    --with github.com/caddy-dns/desec \
    --with github.com/caddy-dns/cloudflare \
    --with github.com/caddy-dns/hetzner

FROM caddy:latest
COPY --from=builder /usr/bin/caddy /usr/bin/caddy

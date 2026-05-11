# Install method: cloud-init self-provisioning

Use this when:

- You're deploying on a **cloud VPS** that supports `cloud-init`
  (Hetzner, DigitalOcean, OVH, Linode, Vultr, Scaleway, AWS
  Lightsail, Google Cloud, …).
- You want **zero-touch provisioning** — paste a `user-data` blob
  into the provider's "Create VM" form and walk away.

End state: AlmaLinux 9 booted *and the entire homeserver stack
deployed*. No SSH session opened.

> [!WARNING]
> **Coming soon — not implemented yet.** The full design is in
> [`CloudInit-Self-Provision-Plan.md`](CloudInit-Self-Provision-Plan.md)
> and tracked in [issue #106](https://github.com/luckynrslevin/home-server/issues/106).
>
> Today, you can still *manually* use AlmaLinux 9 cloud images and
> configure SSH access via cloud-init — see
> [Install-VPS.md](Install-VPS.md). The future cloud-init route
> will collapse the bootstrap + ansible-playbook steps into a
> single user-data paste.

## When this lands, the flow will be

1. Pick AlmaLinux 9 cloud image at your provider.
2. Paste a prepared `user-data` blob into the "Cloud-init" /
   "User data" / "Custom script" field. The blob includes:
   - Your SSH public key.
   - The git URL of your `home-server-private` overlay (with a
     deploy-key token, ideally fetched from a one-shot signed URL
     for security).
   - Your vault password.
   - Hostname + chosen SSH port.
   - Which `deploy_services` preset to use (e.g.
     `cloud-vserver-dns`, `cloud-vserver-files`, `cloud-vserver-full`).
3. Click "Create VM".
4. Wait 15–30 minutes.
5. `https://<hostname>` returns the dashboard.

No bootstrap-host.sh run, no Ansible-from-laptop step — the box
provisions itself end-to-end.

## Until then, the alternatives

If you need to deploy on a cloud VPS *today*:

- **[Install-VPS.md](Install-VPS.md)** — get an AlmaLinux 9 VPS
  with SSH access set up via the provider's UI (or cloud-init for
  just the SSH key bit), then continue with
  [Quickstart](Quickstart.md).

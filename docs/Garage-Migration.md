# Migrating entephoto from MinIO to Garage

Closes issue #168. The `entephoto` role's S3 backend changed from MinIO
to Garage. New deployments get Garage automatically; existing
deployments need this one-time migration.

## Why

- MinIO upstream removed the admin UI from the community image and
  pivoted to a commercial SKU.
- Garage is a maintained Rust S3-compatible store designed for
  self-hosted 1–3 node clusters; lower footprint, same S3 API.

## Pre-flight

Per-host checklist before starting:

- Repo is on a commit that includes the new Garage role files
  (`roles/entephoto/templates/quadlets/entephoto-garage.container.j2`
  should exist locally).
- Vault entries `entephoto_garage_rpc_secret` and
  `entephoto_garage_admin_token` exist in the host's vars. If missing,
  generate and vault them:

  ```bash
  openssl rand -hex 32 | ansible-vault encrypt_string \
    --encrypt-vault-id default --stdin-name entephoto_garage_rpc_secret
  openssl rand -base64 32 | ansible-vault encrypt_string \
    --encrypt-vault-id default --stdin-name entephoto_garage_admin_token
  ```
- A fresh backup has run since the last upload activity (so a
  rollback target exists). Trigger explicitly if unsure:

  ```bash
  ansible-playbook playbooks/backup.yml --limit <host>
  ```

## Run

```bash
ansible-playbook playbooks/entephoto-minio-to-garage.yml --limit <host>
```

What happens, in order:

1. **Stand up Garage** in the existing `entephoto` pod alongside
   MinIO, using the new quadlet's image + the rendered `garage.toml`.
2. **Bootstrap**: assign single-node layout, create the three Ente
   buckets, generate an access key for museum and persist it to
   `/home/entephoto/.garage-museum-key.json`.
3. **Warm mirror**: `rclone sync` from MinIO → Garage for each of the
   three buckets while museum still serves traffic.
4. **Quiesce**: stop `entephoto-museum` and `entephoto-web` so no new
   uploads land in MinIO.
5. **Final mirror**: a second `rclone sync` pass to catch anything
   written during step 3.
6. **Cut over**: re-render `museum.yaml` with the Garage access key,
   restart museum + web.

MinIO is **not** torn down by this playbook. It stays running on
3200 as live rollback insurance until the operator decides it's safe
to remove.

## Verify

1. Open the Ente UI and load a long-lived album → all thumbnails load.
2. Open a random old original photo → loads (proves Garage signs +
   serves presigned URLs against the new credentials).
3. Run a fresh photo export:

   ```bash
   homeserver.sh entephoto-export export-now <host>
   ```

   File count should match the pre-migration baseline.

## Finalize (after 24h with no issues)

1. Reconcile role-managed state — this removes the MinIO container +
   volume from the pod since the new role no longer references them:

   ```bash
   ansible-playbook playbooks/entephoto.yml --limit <host>
   ```

2. Remove the MinIO data volume:

   ```bash
   ssh <host> sudo -u entephoto podman volume rm entephoto-minio-data
   ```

3. Remove the old NAS backup tree at the next backup rotation
   (delete `backup-photos/entephoto-minio-data/` once the new
   `entephoto-garage-data/` + `entephoto-garage-meta/` trees have at
   least one full snapshot).

## Rollback

If the verification step fails:

1. Stop museum + web.
2. Restore the pre-migration `museum.yaml`:

   ```bash
   ssh <host> sudo -u entephoto cp \
     /home/entephoto/.local/share/containers/storage/volumes/entephoto-museum-config/_data/museum.yaml.bak \
     /home/entephoto/.local/share/containers/storage/volumes/entephoto-museum-config/_data/museum.yaml
   ```
   (The cutover step does not auto-create this backup — copy it yourself
   before running the playbook if you want a one-command rollback.)

3. Start museum + web. MinIO is still running on 3200, so museum
   reconnects to it and serves traffic as before.

4. File an issue with logs and we'll iterate.

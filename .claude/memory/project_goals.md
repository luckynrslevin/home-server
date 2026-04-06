---
name: Project goals
description: Core goal and approach — kickstart OS install, then Ansible-driven podman containers
type: project
---

The goal is to set up a home server from scratch, fully automated:

1. **OS install**: Fedora Server via Kickstart (`ks.cfg`)
2. **Application deployment**: All apps run as Podman containers (rootless or rootful), deployed via Ansible roles using the `luckynrslevin.podman_quadlet` collection

**Why:** Rebuild-over-repair philosophy — reproducible, zero-touch server provisioning.

**How to apply:** Every service must be an Ansible role deploying Podman quadlet containers. No manual setup steps on the server.

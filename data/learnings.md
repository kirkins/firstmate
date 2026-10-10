# Learnings

## Emergency SSH access to k3s-master-1 (established 2026-10-10)

The captain approved a dedicated emergency keypair during the 2026-10-09 node incident.
Local side: `~/.ssh/id_ed25519_k3s_emergency` with the `ssh k3s-master-1` alias (root@10.200.0.1).

Authorization procedure (when the node is calm and the Kubernetes API is reachable):

1. Create a short-lived privileged pod in `kube-system` on k3s-master-1 that mounts host `/`
   and appends the public key to `/root/.ssh/authorized_keys` behind a `grep -qF` idempotence
   guard, then fixes modes (`chown 0:0`, `chmod 600` on the file, `chmod 700` on `~/.ssh/.`).
   Create, poll to Succeeded, then delete the pod; never attach interactively.
2. Verify end-to-end with `ssh -o BatchMode=yes k3s-master-1 'echo ok'`.
3. If the API is unreachable, retry on a modest bounded cadence (minutes, not seconds) and
   report the blocker rather than hot-looping.

Never print or copy the private key; the public key may appear in commands.

Revocation: delete the single line containing `id_ed25519_k3s_emergency` from
`/root/.ssh/authorized_keys` on the node (via emergency SSH, or the same privileged-pod
procedure if access is already lost). Nothing else is required to fully revoke access.

## Dead-replica debris on k3s (2026-10-10)

- `opencode-azure-burst-controller` had a `ContainerStatusUnknown` twin from the 2026-10-09
  incident; deleting that dead pod is safe as long as the live replica (`2/2 Running`) stays
  untouched.
- Wedged `forgejo-isolated-*` single-task pollers log `single task poller received no task ...
  trying again` every 5s. A poller older than 30 minutes still receiving no task is wedged;
  deleting the pod alone just respawns it from the owning Job, so delete the Job instead.
  Freshly spawned pollers waiting for their first task are normal - only delete old ones.

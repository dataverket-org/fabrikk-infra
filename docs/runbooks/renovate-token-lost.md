# Runbook: make the bot's token again when its Secret is lost

Written 2026-11-24. Run in a kind cluster on 2026-11-22; not yet run on the cluster.

## Why

After this job the Secret `renovate/renovate` holds a new token and Renovate runs again. The job is needed when the
Secret is gone and the old token still lives on the forge: the Job `renovate-bootstrap` then fails with "access
token name has been used already". The old token cannot be deleted through the forge's API, so its row is deleted
in the database.

## What it touches

| What | Read or written | Needs |
|---|---|---|
| One row of the table `access_token` in the forge's database | Deleted | `dataverket-prod-admin` (`task admin:start`) |
| The Job `renovate-bootstrap` | Deleted; Flux makes it again | The same context |
| Secret `renovate/renovate` | Made by the Job | Nothing |
| The user `renovate`, the team, the branch rules, any other token | Never touched | |

## Steps

1. Check that this is the case. The log must end `access token name has been used already`.

   ```sh
   kubectl --context dataverket-prod-readers -n renovate logs job/renovate-bootstrap | tail -3
   ```

2. Delete the old token's row. It must print `DELETE 1`.

   ```sh
   kubectl cnpg psql forgejo-postgres -n forgejo --context dataverket-prod-admin -- -d forgejo \
     -c "DELETE FROM access_token WHERE name = 'renovate-cluster' AND uid = (SELECT id FROM \"user\" WHERE lower_name = 'renovate');"
   ```

3. Delete the failed Job and let Flux make it again. The log must end `renovate/renovate created`.

   ```sh
   kubectl --context dataverket-prod-admin -n renovate delete job renovate-bootstrap --ignore-not-found
   flux --context dataverket-prod-admin reconcile kustomization renovate --with-source
   kubectl --context dataverket-prod-admin -n renovate logs job/renovate-bootstrap
   ```

## Proof

Start a run as `renovate-run-now.md` says, steps 1 to 4.

The guard prints `guard: renovate can write to <n> repositories and reaches the default branch of none`, with `<n>`
as before the Secret was lost. In kind the Job made a new Secret and the guard passed with the new token.

| Seen | Means |
|---|---|
| `DELETE 0` in step 2 | No token of that name exists. The Job fails for another reason; read its whole log |

## Not part of this

Reading or copying the token: nobody holds it, and nothing here shows it. A new GitHub token, which is a different
Secret (`renovate-bring-up.md`, step 4). Deleting any other row of `access_token`.

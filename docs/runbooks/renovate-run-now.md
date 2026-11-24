# Runbook: run Renovate now

Written 2026-11-24. The check of step 1 has run on the cluster, and Jobs were made from the CronJob there on
2026-11-22 and 2026-11-24. That a scheduled run is skipped while a run by hand is active is how Kubernetes works
with `concurrencyPolicy: Forbid`; it has not been tested here.

## Why

After this job Renovate has made one run outside its schedule, and its log is read. There are two ways, and the
first is often enough:

- **A look.** `bin/renovate-local` prints what Renovate would propose, from a laptop. It changes nothing and cannot
  collide with a run.
- **A real run.** A Job made from the CronJob does what a scheduled run does: the guard first, then pull requests.

Two real runs at once work on the same branches. So a run by hand is started only when no run is active.

## What it touches

| What | Read or written | Needs |
|---|---|---|
| The repositories on disk, for a look | Read | Podman; no token, no cluster |
| A Job in the namespace `renovate` | Made, and deleted when read | `dataverket-prod-admin` (`task admin:start`) |
| Pull requests, branches `renovate/*` and the dashboard issues on the forge | Written by Renovate, as in a scheduled run | Nothing; the bot's own token |
| The CronJob, its schedule, the Secrets | Never touched | |

## Steps

For a look, run this from the repository's root and stop here. It prints one line per update.

```sh
bin/renovate-local "${PWD##*/}"
```

For a real run:

1. Check that no run is active. It must print nothing. A scheduled run starts at 01, 07, 13 and 19 Oslo time and
   takes about three minutes.

   ```sh
   kubectl --context dataverket-prod-readers -n renovate get jobs -o json |
     jq -r '.items[] | select(.status.active) | .metadata.name'
   ```

2. Start the run and wait for it. The second command must print `condition met`.

   ```sh
   job=by-hand-$(date +%H%M)
   kubectl --context dataverket-prod-admin -n renovate create job "$job" --from=cronjob/renovate
   kubectl --context dataverket-prod-readers -n renovate wait --for=condition=complete "job/$job" --timeout=180s
   ```

3. Read the guard's line, then the end of Renovate's log.

   ```sh
   kubectl --context dataverket-prod-readers -n renovate logs "job/$job" -c guard
   kubectl --context dataverket-prod-readers -n renovate logs "job/$job" -c renovate | grep -E '^ *(WARN|ERROR|FATAL)' | sort | uniq -c
   ```

4. Delete the Job.

   ```sh
   kubectl --context dataverket-prod-admin -n renovate delete job "$job"
   ```

## Proof

The guard prints `guard: renovate can write to <n> repositories and reaches the default branch of none`. The second
command of step 3 prints nothing, or warnings that the dashboard issue also lists under "Repository Problems". The
dashboard issue of each repository has a new edit time.

| Seen | Means |
|---|---|
| Step 1 prints a name | A run is active. Wait three minutes and do step 1 again |
| The wait of step 2 ends with `timed out` | The run is slow or has failed. `kubectl ... get job "$job"` shows which; a failed run is read as in step 3 |
| The pod is `Pending` for half a minute | The Renovate image, 1.4 GB, is being pulled |
| The guard prints any other line, and Renovate's log is empty | The guard stopped the run. `artifacts/renovate/README.md`, "What the guard says" |
| `already exists` in step 2 | A Job of that name from the same minute is left. Do step 4, then step 2 |
| No scheduled run at 01, 07, 13 or 19 | A run by hand was active at that time, so the scheduled one was skipped. The next one runs as usual |

## Not part of this

A run with other settings than the cluster's, such as a dry run or one repository only: the Job is a copy of the
CronJob and takes none. `bin/renovate-local` is the dry run. Changing the schedule (`renovate-change.md`). Running
Renovate from a laptop with the bot's token: nobody holds it.

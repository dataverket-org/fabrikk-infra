# Runbook: give Renovate a repository

Written 2026-11-24. Run that day on the cluster for `fabrikk-infra` and `renovate`.

## Why

After this job Renovate opens pull requests in one more repository, and cannot push to its `main` or merge into
it. One workflow run does it: it writes the branch rule first and adds the repository to the team after. The order
matters, and `artifacts/renovate/README.md` says why.

## What it touches

| What | Read or written | Needs |
|---|---|---|
| The rule on `main` of the repository | Written: push and merge limited to the Owners team | The `forgejo` definition's token, through swamp |
| The team `renovate` | The repository added | The same token |
| Other settings of the rule, other rules, other teams | Never touched | |

## Steps

1. Check that the repository has a `renovate.json` on its default branch. It must print `200`. Without the file
   Renovate passes the repository by.

   ```sh
   curl -s -o /dev/null -w '%{http_code}\n' https://git.dataverket.org/dataverket/<repository>/raw/branch/main/renovate.json
   ```

2. Check that everyone who merges in this repository is in the Owners team. After step 3 nobody else can push to
   `main` or merge into it.

3. Run the workflow. It must end `succeeded`.

   ```sh
   swamp workflow run @dataverket/forgejo-team-repository-behind-rule \
     --input forgejo=forgejo --input owner=dataverket --input name=<repository> --input team=renovate \
     --input 'pushWhitelistTeams=["Owners"]' --input 'mergeWhitelistTeams=["Owners"]'
   ```

4. Start a run, or wait for the next one at 01, 07, 13 or 19 Oslo time.

   ```sh
   kubectl --context dataverket-prod-admin -n renovate create job by-hand-$(date +%H%M) --from=cronjob/renovate
   ```

## Proof

```sh
swamp behavior run forgejo team_get --input org=dataverket --input name=renovate --json | jq '.dataArtifacts[0].attributes.repositories'
kubectl --context dataverket-prod-readers -n renovate get jobs --sort-by=.status.startTime | tail -2
kubectl --context dataverket-prod-readers -n renovate logs job/<the newest> -c guard
```

The first lists the repository. The guard prints
`guard: renovate can write to <n> repositories and reaches the default branch of none`, with `<n>` one higher than
before. The repository has an issue "Dependency Dashboard" by `renovate`.

| Seen | Means |
|---|---|
| The workflow fails with `the forge does not count ... in the branch protection` | A team or a login in a whitelist has no write access to the repository. The message names it |
| The workflow fails with `the team is named "x", not "X"` | A team name in another case than the forge's. Use the forge's spelling |
| The guard prints `<repo>@main has no branch protection` | The repository was added to the team by hand. Do step 3 |
| The guard prints `<repo> is empty` | The repository has no commit. Take it out of the team until it has one |
| No dashboard issue after a run | Step 1 did not print `200`, or the run has not happened yet |

## Not part of this

Adding a repository to the team by hand, in the browser or with `team_repo_ensure` alone: that leaves `main` open to
the bot until the rule exists. Taking a repository out of the team, which an owner does on the forge. Writing the
repository's `renovate.json`, which is tried first with `task local` in the renovate repository.

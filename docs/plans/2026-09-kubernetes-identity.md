# Plan: Kubernetes authenticates against Zitadel

Written 2026-09-29 for decision 015. Nothing is applied, and nothing here can start yet: this plan runs after
`docs/plans/2026-09-credential-tiers.md`, which is done, and after `docs/plans/2026-09-break-glass.md`, which is
not, because it needs that plan's route.

## Why

Omni is already the identity provider for Kubernetes here. `omnictl kubeconfig` writes an OIDC kubeconfig that
kubelogin drives, and this repository opts out of it with `--service-account` to get a bearer token in a file
instead, because an `exec` plugin opens a browser and a session wants a credential it can hand to an unattended
run.

So the cluster's authentication sits inside the thing decision 010 says is not part of future designs, and tier 2
holds an eight hour token in `~/.kube/config` where an OIDC token would live minutes. Zitadel runs here already.

## Goals

1. **Reach the cluster without Omni in the path**, with a credential that expires in minutes rather than hours.
2. **The kube context carries no credential**, as the talos context already does not.
3. **The readers and admin split lives in git**, as ClusterRoleBindings against Zitadel groups, rather than in an
   `omnictl --groups` flag.
4. **Automation keeps working** without a browser and without a standing human credential.
5. **Nothing is half done.** An API server that trusts Zitadel while the only route to it is Omni's proxy is worse
   than either end state.

## What it depends on

The overlay from the break-glass plan, and not incidentally. Omni's Kubernetes proxy authenticates callers with
Omni's own identity; it will not carry a Zitadel token. A Zitadel-authenticated `kubectl` therefore talks to the
API server directly, which is only reachable over the WireGuard interface that plan puts in the machine config.
One route serves both, which is the reason to build it once and use it twice.

## The three questions to settle first

**How long a refresh token lives.** The ID token expiring in minutes is the improvement. The refresh token beside
it is a standing credential that re-authenticates a person with nobody present, which is exactly what invariant 1
refuses and exactly the reason `pass-cli` personal access tokens are not used here. Zitadel makes the lifetime a
setting, so it is a decision and not a default to accept.

**What automation authenticates as.** A Zitadel service user with client credentials and short-lived tokens, named
per purpose, so Zitadel's log says which one acted. That is the machine identity decision 010 says has to exist
before a replacement for Omni is designed, and this is where Dataverket first provides it rather than borrowing
it.

**What happens when the cluster is down.** Zitadel would guard the cluster it runs in, so a broken cluster means
no authentication to fix the cluster. The `os:admin` talosconfig in `vaults/operator/break-glass/` stops being prudence and
becomes the requirement that makes this safe.

## Steps

1. **Settle the three questions above** and write the answers into decision 015 before anything is patched.
2. **A Zitadel project for the cluster**: an application for kubelogin with the redirect URIs it needs, the groups
   claim in the ID token, and two groups that mean what `fabrikk-readers` and cluster administration mean today.
3. **RBAC in git.** ClusterRoleBindings under `infrastructure/` binding those groups, reconciled by Flux. Apply
   them before the API server trusts the issuer, so that the first successful login already has its permissions.
4. **Patch the API server** through `omni-cluster applyPatch`, `dryRun` first: the OIDC issuer, client id, the
   username and groups claims and their prefixes. This needs an Operator key, which is a session minted
   deliberately.
5. **Write the context** with an `exec` entry for kubelogin, pointing at the API server over the overlay. It
   carries no credential, so it can live in this repository as a template rather than being minted per session.
6. **Verify as a person**: `kubectl --context <name> auth whoami` shows the Zitadel identity and the expected
   groups, a readers login is refused what it should be refused, and the cached token expires when it should.
7. **Verify as automation**: the service user reaches the cluster with no browser, and its token expires.
8. **Retire the minting tasks.** `admin:kube-admin` and `admin:kube-readers` stop being renewed with the session;
   `admin:status` shows the context as carrying no credential, the way the talos context already reads.
9. **Keep the Omni path until it is not needed.** The service-account kubeconfig still works while Omni exists,
   and is the second way in during the change.

## What is assumed and must be checked

- That the API server flags for OIDC can be set through an Omni config patch and survive Omni's reconciliation.
  If Omni overwrites them, this plan needs Omni to support the setting rather than a patch fighting it.
- That Zitadel can issue a groups claim in the shape the API server expects, and that the prefixes do not collide
  with the `system:` namespace.
- That kubelogin's cache can be pointed somewhere sensible per cluster; `omnictl` has flags for exactly that
  today, which suggests the shape is known to work.

## Not in this plan

- OpenStack. Keystone federating to Zitadel is the same idea and a separate plan, worth doing only once this one
  has proved the shape.
- Talos. It authenticates with certificates from its own PKI, not OIDC, so it is the break-glass plan's business
  and not this one's.
- Replacing Omni for machine lifecycle. This plan takes one service off it, which is the first piece and not the
  whole.

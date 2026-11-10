# Plan: GitHub as a login at id.dataverket.org, and an organization people register in

Written 2026-11-10, rewritten twice the same day: first around the cluster's own configuration, then around a Go
program on Zitadel's client, built with ko. Two goals on the upstream's Zitadel instance, `id.dataverket.org`
(decision 034): an organization `dataverket` that a person who registers lands in, and GitHub as an identity provider
that organization offers. Both are part of the `platform/zitadel-config` artifact, applied by Flux, so a platform
installed anywhere gets them with the rest of Zitadel. Nothing is applied. The site instance of
`docs/plans/2026-11-site-names.md` R4 is another instance; this plan does not touch it.

## Status, 2026-11-10

**Not started.** The Go code in the appendix is a draft that compiles, passes `go vet` and builds as an image with
ko 0.19.1 against `zitadel-go` v3.30.0. It has not run against any Zitadel. G2 runs it on a throwaway instance
before the cluster sees it.

## Where we are

Read with the reader key through `zitadel-instance`, `zitadel-org`, `zitadel-settings`, `zitadel-user`,
`zitadel-project` and `zitadel-app`:

| Fact | Value |
|---|---|
| Instance | v4.15.3, one organization: `Operators` (`389916413806052639`), which is also the default |
| People | Ten humans, all in `Operators`: two hold `IAM_OWNER`, one is the chart's admin account, seven are members |
| Login settings | Never set per organization; the instance default is in force: registration on, external providers on |
| Identity providers | None |
| Projects | `git.dataverket.org`, `zulip`, `zot-artifact-registry`, `incus`, `fabrikk-infra-admin`, all in `Operators` |
| Legal links | `docsLink` only; no terms and no privacy link on the registration page |

A stranger can register today, with a password, and lands in the organization named `Operators`, beside the two
instance owners and the machine keys. Goal 1 corrects that; GitHub only makes the door easier to find.

## What was weighed

| Way | Why not, or why |
|---|---|
| The chart (10.0.4 and its main branch) | Passes Zitadel's runtime config through and writes the first machine user's key into a Secret. Nothing for a second organization, a provider, a project or a client. `FirstInstance` is used below for what it does cover |
| Zitadel's Terraform provider with OpenTofu | Covers everything and removes what leaves the file, but is a second tool with state beside a service that has to be written anyway |
| Pulumi, Dagger | The same provider at one remove; a pipeline runner and not a configuration tool |
| A shell script over the REST API | The first draft of this plan. Works, and leads nowhere |
| **A Go program on `zitadel-go`** | Chosen. The same package is what a later service calls. The Terraform provider is built on the same client (v3.29.3) and is Apache-2.0: its resources cannot be imported, since they take Terraform's data model, but each is the reference for which call does what, and its `acceptance/` directory for how to test against a real instance |

## What carries it

Desired state lives in what Flux applies, never in a swamp definition; swamp is not something a rebuild depends on.

| Part | Where | Is |
|---|---|---|
| `zitadel-seed` | Its own repository on the forge, `dataverket/zitadel-seed`, as `nordhost-integrator` is and `versitygw-lifecycle` will be | One Go module. Package `identity` holds the functions; `cmd/zitadel-seed apply` runs them once and exits. A `serve` command for the later service is another `cmd` on the same package, and not in this plan |
| The image | `registry.dataverket.org/dataverket/zitadel-seed`, built by ko, signed by cosign once the key of the gitless plan's goal 3 exists | One static binary on a static base. No shell, no curl |
| `artifacts/zitadel/identity/identity.json` | This repository | What the instance should hold. No value of any credential |
| `artifacts/zitadel/identity-job.yaml` | This repository | A Job that runs the image by digest, the shape of Zulip's `organization-job.yaml`: the ConfigMap's name carries a hash of the file, so a change is a new Job spec and one new run |
| `artifacts/zitadel/zitadel-idp-github.enc.yaml` | This repository | The GitHub client id and secret, encrypted to the cluster's key like the Secrets beside it. Written by you |
| `FirstInstance` in `release.yaml` | This repository | What a new instance is born with, so the Job has little to correct on a fresh platform |
| swamp | | The reads this plan is written from, and the same reads as assertions in the health workflow. No extension release and no swamp workflow is part of the result |

The Job acts as `iam-admin`, the machine user the chart makes at install, whose key the chart writes into a Secret
in the `zitadel` namespace and `bin/zitadel-bootstrap` already uses. No new credential is minted. It holds
`IAM_OWNER`, which moving the default organization needs.

It reaches Zitadel at `id.dataverket.org`, the public address, with TLS, the way the client is documented and the way
every other client in the cluster reaches it. The Service in the cluster would need the public name forced into both
the token request and the gRPC authority, which the client has no option for. The cost: on a fresh install the Job
cannot finish before the route and the certificate are there, so `apply` takes `--wait`.

## The shape

| Organization | Holds | Login settings |
|---|---|---|
| The instance default | Applies to `Operators` and to any organization made later | Registration off, external providers off. An operator's account is reached with a passkey made at Zitadel and nothing else |
| `dataverket` | Everyone else. The default organization: a registration with no organization in the request lands here | Its own: registration on, external providers on, GitHub active |

GitHub is a provider **of the `dataverket` organization**, not of the instance. An instance-wide provider would be
offered to `Operators` too, and a GitHub account would be a second way to an `IAM_OWNER`.

| Provider option | Value | Why |
|---|---|---|
| `isCreationAllowed` | true | A person with no account gets one from the GitHub login |
| `isAutoCreation` | false | The person sees and confirms the name and address before the account exists |
| `isLinkingAllowed` | true | A person who has an account adds GitHub to it after logging in |
| Automatic linking | off, and not in the file: the program never sets it | Linking by matching e-mail would let whoever controls a GitHub address take the Zitadel account with that address |
| `isAutoUpdate` | true | Name and address follow GitHub |

On GitHub it is an OAuth app owned by `dataverket-org`, one per Zitadel instance since the callback names the host.
GitHub has no API that creates one. The callback is `https://id.dataverket.org/idps/callback` for both login UIs
(`internal/api/idp/idp.go` in v4.15.3: the handler takes the callback and hands on to whichever UI began).

## The program

```
zitadel-seed/
  cmd/zitadel-seed/main.go    apply: flags, the login, the wait
  identity/spec.go            identity.json as types; Load refuses an unknown field
  identity/ensure.go          Applier: organization, default, login settings, GitHub provider
  identity/*_test.go          G2
  .ko.yaml
  .forgejo/workflows/         test, build, push; as nordhost-integrator's
```

How it behaves, which is what G2 tests:

- Every function reads first and writes only a difference. A second run makes one write, the provider's, since the
  secret is sent every time: Zitadel cannot say which one it holds.
- Organizations first, the instance default last, so registration is never closed everywhere in between.
- It adds and corrects. It removes nothing: an organization or a provider taken out of the file stays in Zitadel.
- Login settings are merged field by field over what Zitadel holds; a field not in the file is left alone, and an
  organization's settings become its own on the first write.
- Both secret files are read before any provider call. A value goes into a request and never into a log line or an
  error text.
- Output is one JSON line per change and one at the end; exit 1 on any failure.

### `.ko.yaml`

```yaml
# The base by digest, from the registry's mirror, so a build fetches nothing but Go modules (decision 035).
defaultBaseImage: registry.dataverket.org/mirror/chainguard/static@sha256:…
defaultPlatforms:
  - linux/amd64
builds:
  - id: zitadel-seed
    main: ./cmd/zitadel-seed
    env: [CGO_ENABLED=0]
    flags: [-trimpath]
    ldflags: [-s, -w]
```

### Build and publish

```sh
go test ./...
KO_DOCKER_REPO=registry.dataverket.org/dataverket/zitadel-seed \
  ko build --bare --tags "$(git describe --tags --always)" ./cmd/zitadel-seed   # prints the image by digest
cosign sign --key … registry.dataverket.org/dataverket/zitadel-seed@sha256:…    # when the key exists
```

The digest ko prints is what the Job names. Until the forge's CI holds the push credential (the gitless plan's CI
step), the push is yours from a laptop with the ci credential, as every artifact push is today.

## The manifests

### `artifacts/zitadel/identity/identity.json`

```json
{
  "instance": {
    "login": { "allowRegister": false, "allowExternalIdp": false }
  },
  "organizations": [
    {
      "name": "dataverket",
      "default": true,
      "login": { "allowRegister": true, "allowExternalIdp": true },
      "providers": [
        {
          "kind": "github",
          "name": "GitHub",
          "secret": "github",
          "options": {
            "isLinkingAllowed": true,
            "isCreationAllowed": true,
            "isAutoCreation": false,
            "isAutoUpdate": true
          }
        }
      ]
    }
  ]
}
```

C2 merges the file without `providers`; C3 adds them. `secret` names a directory under `/secrets`, never a value.
Scopes are left to Zitadel's default for GitHub.

### `artifacts/zitadel/identity-job.yaml`

```yaml
# The instance's organizations, login settings and identity providers, as identity/identity.json says, made so by
# zitadel-seed (git.dataverket.org/dataverket/zitadel-seed). The ConfigMap's name carries a hash of the file, so a
# change to it changes this Job's spec; the force annotation lets Flux recreate the Job then, which runs it again.
# A finished Job stays; a failed one fails the Kustomization, where it shows. It acts as iam-admin, the owner the
# chart makes at install, and reaches Zitadel at its public name, so on a fresh install it waits for the route.
# IDP_SECRET_REVISION is raised by hand when zitadel-idp-github.enc.yaml changes, which is what runs a rotation.
apiVersion: batch/v1
kind: Job
metadata:
  name: zitadel-identity
  namespace: zitadel
  annotations:
    kustomize.toolkit.fluxcd.io/force: Enabled
spec:
  backoffLimit: 2
  template:
    spec:
      restartPolicy: Never
      automountServiceAccountToken: false
      securityContext:
        runAsNonRoot: true
        runAsUser: 65532
        runAsGroup: 65532
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: identity
          image: registry.dataverket.org/dataverket/zitadel-seed@sha256:…
          args:
            - apply
            - --domain=id.dataverket.org
            - --key=/key/iam-admin.json
            - --file=/identity/identity.json
            - --wait=10m
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: [ALL]
          env:
            - name: IDP_SECRET_REVISION
              value: "1"
          volumeMounts:
            - { name: identity, mountPath: /identity, readOnly: true }
            - { name: key, mountPath: /key, readOnly: true }
            - { name: github, mountPath: /secrets/github, readOnly: true }   # C3
      volumes:
        - name: identity
          configMap:
            name: zitadel-identity
        - name: key
          secret:
            secretName: iam-admin
            defaultMode: 0440
        - name: github                                                      # C3
          secret:
            secretName: zitadel-idp-github
            defaultMode: 0440
```

A Secret volume is root's by default; the pod runs as 65532, so C2 settles `fsGroup` against the modes above.

### `artifacts/zitadel/kustomization.yaml`, added

```yaml
resources:
  - identity-job.yaml
  - zitadel-idp-github.enc.yaml   # C3
configMapGenerator:
  - name: zitadel-identity
    namespace: zitadel
    files:
      - identity/identity.json
```

### `artifacts/zitadel/release.yaml`, added under `configmapConfig`

```yaml
        # What a new instance is born with; setup reads it once and never again, so on an instance that exists
        # this changes nothing and identity/ is what holds it. The first organization is the operators', closed
        # (the identity plan); the organization people register in is made by the zitadel-identity Job.
        FirstInstance:
          Org:
            Name: Operators
          LoginPolicy:
            AllowRegister: false
            AllowExternalIDP: false
```

With it `ZITADEL_ORG` and `ensure_org_name` in `bin/zitadel-bootstrap` have nothing left to rename on a new
platform; they stay until one has been installed that way.

### `artifacts/zitadel/zitadel-idp-github.enc.yaml`, by you

The agent prints this at C3 and does not run it (operator rules 3 and 4); the values come from GitHub's page for
the OAuth app:

```sh
kubectl create secret generic zitadel-idp-github --namespace zitadel --dry-run=client -o yaml \
  --from-literal=client_id=… --from-file=client_secret=/dev/stdin \
  > artifacts/zitadel/zitadel-idp-github.enc.yaml      # paste the secret, Ctrl-D
sops --encrypt --in-place artifacts/zitadel/zitadel-idp-github.enc.yaml
```

The README's Secrets section has the pipe that keeps the value off the disk before encryption; C3 uses that form.

## How the work is cut

Each step is one branch in one workspace: a git worktree beside the checkout, so two steps can be open at once and
`main` stays clean. The same in both repositories.

```sh
git worktree add ../<repo>.<step> -b <step> main          # the agent, at the start of a step
git -C ../<repo>.<step> -c commit.gpgsign=false commit …  # the agent's commits, unsigned
git merge --squash <step> && git commit -S                # you, on main, when present
git worktree remove ../<repo>.<step> && git branch -D <step>
```

A step ends with a stop: the branch rebased on `main`, its checks green, and a last message saying what you run and
what you should see. A merge alone changes nothing in the cluster: an image reaches the registry and an artifact
the cluster when you push them, one YubiKey touch each, until CI does (`docs/plans/2026-11-gitless.md`).

| Step | Repository | Needs | Agent alone | Needs you |
|---|---|---|---|---|
| G0, what a registered person gets | fabrikk-infra | nothing | all of it, read-only | the merge |
| G1, the repository and the draft | zitadel-seed | nothing | the module from the appendix, `.ko.yaml`, the README, a local `ko build` | a yes to creating the repository on the forge; the first signed commit |
| G2, proven on a throwaway | zitadel-seed | G1 | tests, the live suite, the review and its fixes | the merge |
| G3, the image | zitadel-seed | G2 | the CI workflow, the mirror entry for the base image | the merge, the push, the signature |
| C2, the organization and the default | fabrikk-infra | G0, G3 | the manifests, the health assertions, the decision record | the merge, the push, one registration in a browser |
| C3, GitHub | fabrikk-infra | C2 applied | the manifest changes, the commands to print | the OAuth app, the Secret, the merge, the push, one real login |
| C4, what is left over | both | C3 | reads and docs | whatever it finds |

G0 and G1 can be open at the same time. C2 and C3 are each prepared before you are there and finished in one
sitting with you.

## G0: what a registered person gets today

Read-only, through swamp, and the one step that can change the plan. For each client, what an account in the
default organization with no grant can do the moment it exists:

| Client | To read | With |
|---|---|---|
| Every project | `projectRoleCheck`, `hasProjectCheck`, role assertion | `zitadel-project`, `zitadel-app`, `zitadel-grant` |
| Forgejo | whether the Zitadel source creates an account on first login, and with what rights | the `forgejo` definition |
| Zulip | whether the realm is invite-only | `artifacts/zulip/organization/organization.json` |
| zot | what an authenticated user with no group may read or push | `artifacts/zot/` |
| incus | role assertion is on; what an account with no role gets | the app record; the Incus side by you |

Also settled here:

- That the `iam-admin` Secret's key has no expiry, or when it has.
- That a pod in the `zitadel` namespace reaches `id.dataverket.org:443`, HTTP/2 through Envoy included.
- Whether a project in `Operators` admits a user of `dataverket` with nothing more, and whether a role is granted to
  that user directly or needs the project granted to the organization.
- Whether Zitadel can move a user between organizations (C4).

Done when: the table is filled in under Audit, and every client that hands a stranger more than a login has a line
saying what closes it. Such a client is fixed before C2, since registration is open already.

## G1: the repository and the draft

`dataverket/zitadel-seed` on the forge, public, made with `forgejo repo_ensure private=false`, with its GitHub
twin as the other repositories have. The appendix as its first content, `go.mod` on `zitadel-go` v3.30.0, the
README with what the program does and never does, the license, `.ko.yaml`.

Done when: `go build ./...`, `go vet ./...` and `ko build --push=false` pass in a clean checkout.

## G2: proven on a throwaway

Zitadel v4.15.3 in podman, the instance `~/kode/swamp-extensions/zitadel/smoke/compose.yaml` starts, reached
without TLS through `zitadel.WithInsecure`, which the tests set and `apply` has no flag for.

First a change to the draft: `Applier` takes three narrow interfaces, the calls it makes on the admin, management
and organization services, so unit tests run against strict fakes that fail on any call they were not told to expect.

| Case | Expected |
|---|---|
| First run on a fresh instance | The organization, its own login settings, the default moved, the instance default closed; a provider with a made-up client id, active on `dataverket` only |
| Second run | One write, the provider's; the fakes see no other, and on the live instance the organization's and the settings' change dates are those of the first run |
| A registration with no organization | The user is in `dataverket` |
| Login settings read for the first organization | Registration off, inherited, no provider |
| A field not in the file | Unchanged after the run, on the instance and on the organization |
| A secret file missing or empty | Fails before any provider call; nothing else changed |
| A key that is not `IAM_OWNER` | Fails at the first write with Zitadel's message, exit 1 |
| An unknown provider kind, an unknown field, two defaults | Refused by `Load`, before any login |
| Every log line and error text of every case | The client secret's value appears nowhere |
| `--wait` against an address that answers late | Logs in once it answers; gives up at the deadline, exit 1 |

Then an independent review by a fresh agent with the code and not this plan's reasoning.

Done when: the cases pass and the review's findings are fixed.

## G3: the image

| Change | Where |
|---|---|
| The static base mirrored by digest | the registry's `mirror/`, as `docs/plans/2026-10-registry-mirror.md` does it |
| Test, build, push on a tag | `.forgejo/workflows/`, with the actions the forge's mirror holds (decision 022); the push credential a repository secret a person sets |
| Renovate follows `zitadel-go` and the base | the repository's Renovate config |

Done when: the image is in the registry under a tag and a digest, signed if the key exists, and
`ko build` from a clean checkout of the tag gives the same digest.

## C2: the organization `dataverket`, and the default moved to it

| Change | Where |
|---|---|
| `identity.json` without `providers`; the Job without the `github` volume | `artifacts/zitadel/` |
| The Job and the ConfigMap generator | `artifacts/zitadel/kustomization.yaml` |
| `FirstInstance` | `artifacts/zitadel/release.yaml` |
| Health: the default organization is named `dataverket`; the instance default reports registration and external providers off; `dataverket` reports both on as its own | `workflows/workflow-health.yaml`, read with the reader key |
| A decision record: people register in `dataverket`; the instance is closed by default; Zitadel's identity configuration is `identity.json`, applied by `zitadel-seed` | `docs/decisions/036-…`, an audit line on 034 |
| What each organization is for, and how `identity.json` is changed | `README.md`, `artifacts/zitadel/README.md` |

Done when: the Job is `Complete`, health is green with the new assertions, and a registration in a private window,
at `id.dataverket.org` with no client behind it and again from Forgejo's login, makes a user in `dataverket`.
Rollback: revert and push; then, as the program removes nothing, the default organization set back once as
yourself in Zitadel's console. The organization can stay, empty.

## C3: GitHub

| Who | What |
|---|---|
| You | The OAuth app in `dataverket-org`: homepage `https://id.dataverket.org`, callback `https://id.dataverket.org/idps/callback`, device flow off |
| You | `zitadel-idp-github.enc.yaml`, with the commands above |
| Agent | `providers` in `identity.json`, the `github` volume in the Job, the Secret in `kustomization.yaml` |
| Agent | Health: `zitadel-settings read orgId=<dataverket>` stores an `identity-provider` record named `GitHub`; the same read of the first organization stores none |

Done when: you log in with GitHub in a private window and get an account in `dataverket`; an existing member adds
GitHub from their profile and `zitadel-user idpLinkList` shows it; a GitHub login whose address matches an
operator's is **not** let into that account. Rollback: `allowExternalIdp` false for `dataverket` in the file, which
removes the button and keeps every link.

## C4: what is left over

Small, each its own branch if it turns into work:

- **The seven members in `Operators`.** If Zitadel cannot move a user, they stay. Making them anew in `dataverket`
  gives each a new user id, which Forgejo keys its link on: a relink per person for a tidier list. Proposed: leave
  them, and say so in 036. With the instance default closed they cannot add an external login.
- **Terms and privacy links** on the registration page, since strangers see it by design. One more key in
  `identity.json` and one more function; needs a page to link to.
- **MFA.** A GitHub login skips Zitadel's second factor unless `forceMfa` is set. Left off for `dataverket`.
- **Rotation.** A second secret on the GitHub app, the Secret file re-encrypted by you, `IDP_SECRET_REVISION`
  raised, the first secret deleted at GitHub. One paragraph in `docs/runbooks/`.
- **Removal.** A provider or an organization taken out of the file is taken out of Zitadel by a person; a
  `state: absent` in the file is the later answer if it happens twice.
- **The projects and clients.** Forgejo's, Zulip's and zot's clients are made by hand or through swamp today. They
  are the next thing a new platform lacks, and the next keys of `identity.json`; the Terraform provider's
  `project`, `application_oidc` and `user_grant` resources are the reference.
- **A second platform.** The domain in the Job and the organization's name are literals today, as every other
  per-site value here is until the overlay repository exists; they move with the rest.

## To settle before G1

1. **The name of the program.** `zitadel-seed` says what it does today and less well what the service will do.
2. **The name of the organization.** `dataverket`, lower case, as the tenant is written everywhere else (034).
3. **The instance default closed.** It means a new operator is made by an operator, with `ensureHuman` and the
   passkey link workflow, as the last ones were, and that the seven members keep password and passkey only.
4. **`iam-admin` as what the Job acts as.** It is there at install and nothing else is. A machine user of its own
   with less would need `iam.write` for the default organization all the same.

## Not in this plan

- The site instance and its `dataverket` organization: `docs/plans/2026-11-site-names.md` R4. It gets an
  `identity.json` of its own and the same image when it exists.
- The service. This plan delivers the package it will call and one command that is not it.
- Other identity providers: one more `kind`.
- GitHub as a login to Forgejo, Zulip or zot directly. They keep one issuer, Zitadel.
- New methods in `@dataverket/zitadel`. The reads it has are the ones the health assertions need.

## Audit

Nothing yet.

## Appendix: the draft

Compiled on 2026-11-10 with Go 1.27.3 against `github.com/zitadel/zitadel-go/v3` v3.30.0 and
`github.com/zitadel/oidc/v3` v3.49.2, module `git.dataverket.org/dataverket/zitadel-seed`. G1 moves it into the
repository and this appendix goes.

### `identity/spec.go`

```go
// Package identity brings a Zitadel instance to what a Spec says: its
// organizations, which of them is the default, the login settings and the
// identity providers. Every function reads before it writes and writes only a
// difference, so a second run changes nothing. Nothing is ever removed.
package identity

import (
	"encoding/json"
	"fmt"
	"os"
)

// Spec is identity.json.
type Spec struct {
	Instance      Instance       `json:"instance"`
	Organizations []Organization `json:"organizations"`
}

// Instance holds what applies to every organization without settings of its own.
type Instance struct {
	Login Login `json:"login"`
}

// Organization is one organization and what it should hold.
type Organization struct {
	Name      string     `json:"name"`
	Default   bool       `json:"default"`
	Login     Login      `json:"login"`
	Providers []Provider `json:"providers"`
}

// Login is the part of Zitadel's login settings this file decides. A field
// left out is left as Zitadel has it.
type Login struct {
	AllowUsernamePassword *bool `json:"allowUsernamePassword,omitempty"`
	AllowRegister         *bool `json:"allowRegister,omitempty"`
	AllowExternalIDP      *bool `json:"allowExternalIdp,omitempty"`
	AllowDomainDiscovery  *bool `json:"allowDomainDiscovery,omitempty"`
	ForceMFA              *bool `json:"forceMfa,omitempty"`
}

// Provider is one identity provider of an organization. Secret names a
// directory holding client_id and client_secret; no value is in the file.
type Provider struct {
	Kind    string   `json:"kind"`
	Name    string   `json:"name"`
	Secret  string   `json:"secret"`
	Scopes  []string `json:"scopes"`
	Options Options  `json:"options"`
}

// Options says what a login through a provider may do to an account.
type Options struct {
	IsLinkingAllowed  bool `json:"isLinkingAllowed"`
	IsCreationAllowed bool `json:"isCreationAllowed"`
	IsAutoCreation    bool `json:"isAutoCreation"`
	IsAutoUpdate      bool `json:"isAutoUpdate"`
}

// Load reads and checks a Spec. An unknown field is an error, so a typing
// mistake cannot pass as a setting that was left alone.
func Load(path string) (*Spec, error) {
	file, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer file.Close()

	var spec Spec
	decoder := json.NewDecoder(file)
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&spec); err != nil {
		return nil, fmt.Errorf("%s: %w", path, err)
	}

	defaults := 0
	for _, org := range spec.Organizations {
		if org.Name == "" {
			return nil, fmt.Errorf("%s: an organization has no name", path)
		}
		if org.Default {
			defaults++
		}
		for _, provider := range org.Providers {
			if provider.Kind != "github" {
				return nil, fmt.Errorf("%s: %s: unknown provider kind %q",
					path, org.Name, provider.Kind)
			}
			if provider.Name == "" || provider.Secret == "" {
				return nil, fmt.Errorf("%s: %s: a provider needs name and secret",
					path, org.Name)
			}
		}
	}
	if defaults > 1 {
		return nil, fmt.Errorf("%s: more than one default organization", path)
	}
	return &spec, nil
}
```

### `identity/ensure.go`

```go
package identity

import (
	"context"
	"fmt"
	"log/slog"
	"os"
	"path/filepath"
	"strings"

	"github.com/zitadel/zitadel-go/v3/pkg/client"
	"github.com/zitadel/zitadel-go/v3/pkg/client/middleware"
	"github.com/zitadel/zitadel-go/v3/pkg/client/zitadel/admin"
	"github.com/zitadel/zitadel-go/v3/pkg/client/zitadel/idp"
	"github.com/zitadel/zitadel-go/v3/pkg/client/zitadel/management"
	"github.com/zitadel/zitadel-go/v3/pkg/client/zitadel/object"
	objectv2 "github.com/zitadel/zitadel-go/v3/pkg/client/zitadel/object/v2"
	orgv2 "github.com/zitadel/zitadel-go/v3/pkg/client/zitadel/org/v2"
	"github.com/zitadel/zitadel-go/v3/pkg/client/zitadel/policy"
)

// Applier applies a Spec through one client.
type Applier struct {
	Client *client.Client
	// Secrets holds one directory per provider secret.
	Secrets string
	Log     *slog.Logger
}

// Apply brings the instance to the Spec. Every organization comes first and
// the instance default last, so registration is never closed everywhere
// while the organization people register in is being made.
func (a *Applier) Apply(ctx context.Context, spec *Spec) error {
	for _, org := range spec.Organizations {
		if err := a.organization(ctx, org); err != nil {
			return fmt.Errorf("organization %s: %w", org.Name, err)
		}
	}
	if err := a.instanceLogin(ctx, spec.Instance.Login); err != nil {
		return fmt.Errorf("instance login settings: %w", err)
	}
	return nil
}

func (a *Applier) organization(ctx context.Context, spec Organization) error {
	id, err := a.ensureOrg(ctx, spec.Name)
	if err != nil {
		return err
	}
	inOrg := middleware.SetOrgID(ctx, id)

	if err := a.orgLogin(inOrg, spec.Name, spec.Login); err != nil {
		return err
	}
	for _, provider := range spec.Providers {
		if err := a.github(inOrg, spec.Name, provider); err != nil {
			return fmt.Errorf("provider %s: %w", provider.Name, err)
		}
	}
	if spec.Default {
		return a.defaultOrg(ctx, spec.Name, id)
	}
	return nil
}

// ensureOrg returns the id of the organization with this name, creating it
// when it is missing.
func (a *Applier) ensureOrg(ctx context.Context, name string) (string, error) {
	orgs := a.Client.OrganizationServiceV2()

	found, err := orgs.ListOrganizations(ctx, &orgv2.ListOrganizationsRequest{
		Queries: []*orgv2.SearchQuery{{
			Query: &orgv2.SearchQuery_NameQuery{
				NameQuery: &orgv2.OrganizationNameQuery{
					Name:   name,
					Method: objectv2.TextQueryMethod_TEXT_QUERY_METHOD_EQUALS,
				},
			},
		}},
	})
	if err != nil {
		return "", err
	}
	if len(found.GetResult()) > 0 {
		return found.GetResult()[0].GetId(), nil
	}

	made, err := orgs.AddOrganization(ctx, &orgv2.AddOrganizationRequest{Name: name})
	if err != nil {
		return "", err
	}
	a.Log.Info("created the organization", "organization", name)
	return made.GetOrganizationId(), nil
}

// defaultOrg makes an organization the instance's default.
func (a *Applier) defaultOrg(ctx context.Context, name, id string) error {
	now, err := a.Client.AdminService().GetDefaultOrg(ctx, &admin.GetDefaultOrgRequest{})
	if err != nil {
		return err
	}
	if now.GetOrg().GetId() == id {
		return nil
	}

	_, err = a.Client.AdminService().SetDefaultOrg(ctx, &admin.SetDefaultOrgRequest{OrgId: id})
	if err != nil {
		return err
	}
	a.Log.Info("moved the default organization",
		"from", now.GetOrg().GetName(), "to", name)
	return nil
}

// merge lays the wanted fields over what Zitadel holds and says whether
// anything differs.
func (want Login) merge(now *policy.LoginPolicy) (merged *policy.LoginPolicy, changed bool) {
	merged = &policy.LoginPolicy{
		AllowUsernamePassword:      now.GetAllowUsernamePassword(),
		AllowRegister:              now.GetAllowRegister(),
		AllowExternalIdp:           now.GetAllowExternalIdp(),
		ForceMfa:                   now.GetForceMfa(),
		PasswordlessType:           now.GetPasswordlessType(),
		HidePasswordReset:          now.GetHidePasswordReset(),
		IgnoreUnknownUsernames:     now.GetIgnoreUnknownUsernames(),
		DefaultRedirectUri:         now.GetDefaultRedirectUri(),
		PasswordCheckLifetime:      now.GetPasswordCheckLifetime(),
		ExternalLoginCheckLifetime: now.GetExternalLoginCheckLifetime(),
		MfaInitSkipLifetime:        now.GetMfaInitSkipLifetime(),
		SecondFactorCheckLifetime:  now.GetSecondFactorCheckLifetime(),
		MultiFactorCheckLifetime:   now.GetMultiFactorCheckLifetime(),
		SecondFactors:              now.GetSecondFactors(),
		MultiFactors:               now.GetMultiFactors(),
		AllowDomainDiscovery:       now.GetAllowDomainDiscovery(),
		DisableLoginWithEmail:      now.GetDisableLoginWithEmail(),
		DisableLoginWithPhone:      now.GetDisableLoginWithPhone(),
		ForceMfaLocalOnly:          now.GetForceMfaLocalOnly(),
	}
	set := func(field *bool, wanted *bool) {
		if wanted != nil && *field != *wanted {
			*field = *wanted
			changed = true
		}
	}
	set(&merged.AllowUsernamePassword, want.AllowUsernamePassword)
	set(&merged.AllowRegister, want.AllowRegister)
	set(&merged.AllowExternalIdp, want.AllowExternalIDP)
	set(&merged.AllowDomainDiscovery, want.AllowDomainDiscovery)
	set(&merged.ForceMfa, want.ForceMFA)
	return merged, changed
}

// instanceLogin brings the instance's default login settings to the wanted
// fields.
func (a *Applier) instanceLogin(ctx context.Context, want Login) error {
	now, err := a.Client.AdminService().GetLoginPolicy(ctx, &admin.GetLoginPolicyRequest{})
	if err != nil {
		return err
	}
	p, changed := want.merge(now.GetPolicy())
	if !changed {
		return nil
	}

	_, err = a.Client.AdminService().UpdateLoginPolicy(ctx, &admin.UpdateLoginPolicyRequest{
		AllowUsernamePassword:      p.AllowUsernamePassword,
		AllowRegister:              p.AllowRegister,
		AllowExternalIdp:           p.AllowExternalIdp,
		ForceMfa:                   p.ForceMfa,
		PasswordlessType:           p.PasswordlessType,
		HidePasswordReset:          p.HidePasswordReset,
		IgnoreUnknownUsernames:     p.IgnoreUnknownUsernames,
		DefaultRedirectUri:         p.DefaultRedirectUri,
		PasswordCheckLifetime:      p.PasswordCheckLifetime,
		ExternalLoginCheckLifetime: p.ExternalLoginCheckLifetime,
		MfaInitSkipLifetime:        p.MfaInitSkipLifetime,
		SecondFactorCheckLifetime:  p.SecondFactorCheckLifetime,
		MultiFactorCheckLifetime:   p.MultiFactorCheckLifetime,
		AllowDomainDiscovery:       p.AllowDomainDiscovery,
		DisableLoginWithEmail:      p.DisableLoginWithEmail,
		DisableLoginWithPhone:      p.DisableLoginWithPhone,
		ForceMfaLocalOnly:          p.ForceMfaLocalOnly,
	})
	if err != nil {
		return err
	}
	a.Log.Info("set the instance's login settings")
	return nil
}

// orgLogin gives an organization login settings of its own with the wanted
// fields: made from the inherited ones on the first write, updated after.
func (a *Applier) orgLogin(inOrg context.Context, name string, want Login) error {
	mgmt := a.Client.ManagementService()

	now, err := mgmt.GetLoginPolicy(inOrg, &management.GetLoginPolicyRequest{})
	if err != nil {
		return err
	}
	p, changed := want.merge(now.GetPolicy())

	switch {
	case now.GetPolicy().GetIsDefault():
		_, err = mgmt.AddCustomLoginPolicy(inOrg, &management.AddCustomLoginPolicyRequest{
			AllowUsernamePassword:      p.AllowUsernamePassword,
			AllowRegister:              p.AllowRegister,
			AllowExternalIdp:           p.AllowExternalIdp,
			ForceMfa:                   p.ForceMfa,
			PasswordlessType:           p.PasswordlessType,
			HidePasswordReset:          p.HidePasswordReset,
			IgnoreUnknownUsernames:     p.IgnoreUnknownUsernames,
			DefaultRedirectUri:         p.DefaultRedirectUri,
			PasswordCheckLifetime:      p.PasswordCheckLifetime,
			ExternalLoginCheckLifetime: p.ExternalLoginCheckLifetime,
			MfaInitSkipLifetime:        p.MfaInitSkipLifetime,
			SecondFactorCheckLifetime:  p.SecondFactorCheckLifetime,
			MultiFactorCheckLifetime:   p.MultiFactorCheckLifetime,
			SecondFactors:              p.SecondFactors,
			MultiFactors:               p.MultiFactors,
			AllowDomainDiscovery:       p.AllowDomainDiscovery,
			DisableLoginWithEmail:      p.DisableLoginWithEmail,
			DisableLoginWithPhone:      p.DisableLoginWithPhone,
			ForceMfaLocalOnly:          p.ForceMfaLocalOnly,
		})
	case changed:
		_, err = mgmt.UpdateCustomLoginPolicy(inOrg, &management.UpdateCustomLoginPolicyRequest{
			AllowUsernamePassword:      p.AllowUsernamePassword,
			AllowRegister:              p.AllowRegister,
			AllowExternalIdp:           p.AllowExternalIdp,
			ForceMfa:                   p.ForceMfa,
			PasswordlessType:           p.PasswordlessType,
			HidePasswordReset:          p.HidePasswordReset,
			IgnoreUnknownUsernames:     p.IgnoreUnknownUsernames,
			DefaultRedirectUri:         p.DefaultRedirectUri,
			PasswordCheckLifetime:      p.PasswordCheckLifetime,
			ExternalLoginCheckLifetime: p.ExternalLoginCheckLifetime,
			MfaInitSkipLifetime:        p.MfaInitSkipLifetime,
			SecondFactorCheckLifetime:  p.SecondFactorCheckLifetime,
			MultiFactorCheckLifetime:   p.MultiFactorCheckLifetime,
			AllowDomainDiscovery:       p.AllowDomainDiscovery,
			DisableLoginWithEmail:      p.DisableLoginWithEmail,
			DisableLoginWithPhone:      p.DisableLoginWithPhone,
			ForceMfaLocalOnly:          p.ForceMfaLocalOnly,
		})
	default:
		return nil
	}
	if err != nil {
		return err
	}
	a.Log.Info("set the organization's own login settings", "organization", name)
	return nil
}

// secret reads one file of a provider's secret directory. The value goes
// into a request and nowhere else: never into a log line or an error.
func (a *Applier) secret(dir, file string) (string, error) {
	raw, err := os.ReadFile(filepath.Join(a.Secrets, dir, file))
	if err != nil {
		return "", err
	}
	value := strings.TrimSpace(string(raw))
	if value == "" {
		return "", fmt.Errorf("%s/%s is empty", dir, file)
	}
	return value, nil
}

// github creates or converges one GitHub provider of an organization and
// activates it for login there. Both secret files are read before any call,
// so a missing one changes nothing.
func (a *Applier) github(inOrg context.Context, org string, spec Provider) error {
	mgmt := a.Client.ManagementService()

	clientID, err := a.secret(spec.Secret, "client_id")
	if err != nil {
		return err
	}
	clientSecret, err := a.secret(spec.Secret, "client_secret")
	if err != nil {
		return err
	}
	options := &idp.Options{
		IsLinkingAllowed:  spec.Options.IsLinkingAllowed,
		IsCreationAllowed: spec.Options.IsCreationAllowed,
		IsAutoCreation:    spec.Options.IsAutoCreation,
		IsAutoUpdate:      spec.Options.IsAutoUpdate,
		// Never linked by a matching address: whoever controls an address
		// at GitHub would take the account that has it here.
		AutoLinking: idp.AutoLinkingOption_AUTO_LINKING_OPTION_UNSPECIFIED,
	}

	found, err := mgmt.ListProviders(inOrg, &management.ListProvidersRequest{
		Queries: []*management.ProviderQuery{
			{Query: &management.ProviderQuery_IdpNameQuery{
				IdpNameQuery: &idp.IDPNameQuery{
					Name:   spec.Name,
					Method: object.TextQueryMethod_TEXT_QUERY_METHOD_EQUALS,
				},
			}},
			{Query: &management.ProviderQuery_OwnerTypeQuery{
				OwnerTypeQuery: &idp.IDPOwnerTypeQuery{
					OwnerType: idp.IDPOwnerType_IDP_OWNER_TYPE_ORG,
				},
			}},
		},
	})
	if err != nil {
		return err
	}

	var id string
	if len(found.GetResult()) == 0 {
		made, err := mgmt.AddGitHubProvider(inOrg, &management.AddGitHubProviderRequest{
			Name:            spec.Name,
			ClientId:        clientID,
			ClientSecret:    clientSecret,
			Scopes:          spec.Scopes,
			ProviderOptions: options,
		})
		if err != nil {
			return err
		}
		id = made.GetId()
		a.Log.Info("created the provider", "organization", org, "provider", spec.Name)
	} else {
		// The secret is sent on every run: Zitadel cannot say which one it
		// holds, and this is what makes a rotation one new run.
		id = found.GetResult()[0].GetId()
		_, err := mgmt.UpdateGitHubProvider(inOrg, &management.UpdateGitHubProviderRequest{
			Id:              id,
			Name:            spec.Name,
			ClientId:        clientID,
			ClientSecret:    clientSecret,
			Scopes:          spec.Scopes,
			ProviderOptions: options,
		})
		if err != nil {
			return err
		}
	}

	active, err := mgmt.ListLoginPolicyIDPs(inOrg, &management.ListLoginPolicyIDPsRequest{})
	if err != nil {
		return err
	}
	for _, link := range active.GetResult() {
		if link.GetIdpId() == id {
			return nil
		}
	}
	_, err = mgmt.AddIDPToLoginPolicy(inOrg, &management.AddIDPToLoginPolicyRequest{
		IdpId:     id,
		OwnerType: idp.IDPOwnerType_IDP_OWNER_TYPE_ORG,
	})
	if err != nil {
		return err
	}
	a.Log.Info("activated the provider for login", "organization", org, "provider", spec.Name)
	return nil
}
```

### `cmd/zitadel-seed/main.go`

```go
// Command zitadel-seed brings a Zitadel instance to what a file says.
//
//	zitadel-seed apply --domain id.example.org --key key.json --file identity.json
//
// It reaches Zitadel at its public address, as every other client does, and
// acts as the machine user whose key it is given. With --wait it keeps trying
// until the instance answers, for a Job applied together with Zitadel itself.
package main

import (
	"context"
	"flag"
	"fmt"
	"log/slog"
	"os"
	"time"

	"github.com/zitadel/oidc/v3/pkg/oidc"
	"github.com/zitadel/zitadel-go/v3/pkg/client"
	"github.com/zitadel/zitadel-go/v3/pkg/zitadel"

	"git.dataverket.org/dataverket/zitadel-seed/identity"
)

func main() {
	log := slog.New(slog.NewJSONHandler(os.Stdout, nil))
	if len(os.Args) < 2 || os.Args[1] != "apply" {
		fmt.Fprintln(os.Stderr, "usage: zitadel-seed apply --domain D --key FILE --file FILE [--secrets DIR] [--wait DURATION]")
		os.Exit(2)
	}
	if err := apply(log, os.Args[2:]); err != nil {
		log.Error("the instance is not as the file says", "error", err.Error())
		os.Exit(1)
	}
}

func apply(log *slog.Logger, args []string) error {
	flags := flag.NewFlagSet("apply", flag.ContinueOnError)
	domain := flags.String("domain", os.Getenv("ZITADEL_DOMAIN"), "the instance's public domain")
	key := flags.String("key", os.Getenv("ZITADEL_KEY"), "a machine key JSON holding IAM_OWNER")
	file := flags.String("file", os.Getenv("IDENTITY"), "identity.json")
	secrets := flags.String("secrets", "/secrets", "a directory per provider secret")
	wait := flags.Duration("wait", 0, "how long to keep trying until the instance answers")
	if err := flags.Parse(args); err != nil {
		return err
	}
	if *domain == "" || *key == "" || *file == "" {
		return fmt.Errorf("--domain, --key and --file are all needed")
	}

	spec, err := identity.Load(*file)
	if err != nil {
		return err
	}

	ctx, cancel := context.WithTimeout(context.Background(), *wait+2*time.Minute)
	defer cancel()

	api, err := connect(ctx, log, *domain, *key, *wait)
	if err != nil {
		return err
	}
	defer api.Close()

	applier := &identity.Applier{Client: api, Secrets: *secrets, Log: log}
	if err := applier.Apply(ctx, spec); err != nil {
		return err
	}
	log.Info("the instance is as the file says", "file", *file)
	return nil
}

// connect logs in with the key, trying again until the deadline when the
// instance does not answer yet.
func connect(ctx context.Context, log *slog.Logger, domain, key string, wait time.Duration) (*client.Client, error) {
	deadline := time.Now().Add(wait)
	for {
		api, err := client.New(ctx, zitadel.New(domain),
			client.WithAuth(client.DefaultServiceUserAuthentication(key,
				oidc.ScopeOpenID, client.ScopeZitadelAPI())))
		if err == nil {
			return api, nil
		}
		if time.Now().After(deadline) {
			return nil, fmt.Errorf("no login at %s: %w", domain, err)
		}
		log.Info("the instance does not answer yet", "domain", domain)
		select {
		case <-ctx.Done():
			return nil, ctx.Err()
		case <-time.After(10 * time.Second):
		}
	}
}
```

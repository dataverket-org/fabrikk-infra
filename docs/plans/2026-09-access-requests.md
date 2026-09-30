# Plan: access requests

Written 2026-09-29, after the invariants in decision 001 and the tier 1 session that
`docs/plans/2026-09-credential-tiers.md` builds. That plan makes this repository's credentials obey the tiers.
This one
generalises the way a person enters tier 1, from five tasks that know one cluster and one cloud by name into a
request over a list of services. Nothing is applied.

It is deliberately a second plan. The first is finishable and worth finishing before this one starts: the request
model should be written against tasks that have been used for a while, not against tasks that have never been run.

## The request

A session starts with a sentence rather than a command: I am `<name>`, and I need `<level>` access to these
services. The name is the operator's own, the one their age key and their kube contexts already carry. The level
is `read` or `admin`, and `read` is what you get when you do not say. The array is services, each an endpoint spec
and not a word: a Keystone `auth_url` with a project and a region, an Omni instance with a cluster, a Talos
endpoint behind that Omni's proxy, and whatever this repository later learns to ask for.

Saying it does three things. It puts the session's scope in the open before anything is minted, so that `admin` is
something a person asks for and not what the code happens to default to. It makes the session answerable
afterwards: who asked, for what, at what level, and for how long. And it is the same sentence a grants engine
evaluates later, when `swamp serve` holds the policy, so nothing about the shape changes when enforcement moves
off this host.

A service is whatever a person names when they say where they are going, and that is coarser than the credentials
behind it. A cluster is one service, not three, although admitting you to it writes a kube context, a talos
context and an Omni key file. An OpenStack project at one API endpoint is one service. A set of bare metal hosts
reached over SSH is one service. The person says `dataverket-prod`, and the entry behind that name knows what has
to exist for the sentence to be true. Least privilege would rather have each artifact asked for separately; that
narrowing belongs to a policy engine deciding whether to grant the sentence, not to the sentence itself, which
should stay something a person would actually say.

What there is to name is whatever has been built. The units are a function of the infrastructure and services that
exist at the human surface at a given time, so the list is a description of that surface at a moment and not a
taxonomy settled in advance. It grows when a cluster or a site is built and shrinks when one is retired, the
entry is born with the thing it names, and the kinds below are what exists here now rather than a set to complete.
Designing entries for services nobody operates yet would be inventing a surface instead of describing one.

That gives the list a second job: it is the answer to "what can a person get access to here", which means it can
be checked against reality rather than trusted. An entry naming a cluster Omni does not have, or an Omni cluster
no entry names, is drift, and `task admin:status` is where it should be reported, the same way it already reports
a context it did not make.

Two levels, because a person has two intentions. `read` means nothing changes. `admin` means something may. Each
entry translates that into what its own service calls it, and the translation is the reason the list exists. What
follows is today's surface, plus the one kind we can already see coming:

| Kind | `read` | `admin` | What it writes |
|---|---|---|---|
| `omni` (a cluster through Omni) | Omni `Reader`, kube group `fabrikk-readers` | Omni `Operator`, kube `system:masters` | Kube contexts, the talos context, an Omni key file |
| `openstack` (a project at one API endpoint) | role `reader` | role `member`, or the roles the entry names | A `clouds.yaml` entry and the application credential behind it |
| `ssh` (bare metal, not built yet) | the unprivileged principal | the privileged principal | An SSH certificate with a validity interval, in `~/.ssh/` |

Levels are cumulative: `admin` is the `read` set plus what only `admin` gets, because the read-only models keep
naming the readers context while you hold the admin one. The talos context does not vary by level at all, since
it carries no credential; what varies is which Omni key file `talosctl` authenticates with.

The SSH row is a test of the invariants and not a plan: the metal under the cluster is the provider's, our root
begins at the OpenStack API, and there is no rack of our own to reach. It stays out of the list until there are
hosts and a CA behind them. Bare metal joins tier 2 only as a certificate with a
lifetime, which means a CA that signs one for the session; a permanent private key in `~/.ssh/` would be a
permanent credential on disk, which invariant 2 forbids outright. A host that can only be reached with a permanent
key is not tier 2 at all: it is tier 3 with a human owner, reached the way break-glass is reached, and saying so
is more useful than pretending the key is short-lived.

## The mechanisms, and what the repository may hold

Tier 1 has no credentials of its own. It has mechanisms, and a mechanism authenticates a human without the thing
that authenticates them ever being on this host: a YubiKey that signs without revealing its key, a browser session
at an OIDC provider, a password manager behind a web login (Proton Pass here, Bitwarden or passwordstore.org for
someone else), sops with an age key on that YubiKey. Each service entry names the mechanism its human access goes
through. Adding one is a function beside the existing ones and not a new design: the OpenStack password is already
a `pass://` reference resolved for the length of one run, and another backend resolves a different reference the
same way.

That separates two things this repository is otherwise tempted to confuse. A reference says where a value lives: a
`pass://` id, a Bitwarden item, a pass-store path, an issuer and a client id, a YubiKey serial, an `auth_url`. It
is useless without the mechanism, so it is not a secret, and it belongs in the plain service list where it can be
read and reviewed. A value authenticates. Invariant 1 is the line between them.

## Then a human-only store, for tier 1 as well?

`vaults/operator/` is plain sops: age, the two YubiKeys as its only recipients, and no swamp vault config, so no
process can read it (decision 016). That makes it one instance of one of the mechanisms and not a tier of its own, and it is a convenience rather than a
requirement. Tier 1 does not depend on it. A service's human-only material may sit wherever that
service's access is naturally guarded: in Proton Pass or Bitwarden behind a web login, in a pass store, with the
identity provider, in a safe. Which source a given service uses follows from what access it guards, and the
request names the mechanism, not the store.

What `vaults/operator/` is good for is the material that is already about this repository's own infrastructure and
gains from travelling with it: the Omni break-glass talosconfig and kubeconfig, and the same for other services
later. It is reviewable, `.sops.yaml` states its recipients in the open, encryption needs only public keys so a
workflow can still write there, and a read needs a touch. All of it is tier 3 by invariant 2, since none of it can be
minted with a lifetime, and all of it is read by a person and never by a process.

Two lines keep it honest, and they hold for any source, not only this one. Nothing in it may complete a routine
login: if the everyday way into a service could be rebuilt from the repository plus a touch, tier 1 would be
reconstructible without the mechanism it is supposed to rest on. Break-glass passes that test because it goes
around the service instead of logging in to it, and because using it is an incident that leaves a trace; a stored
identity-provider password would fail it. And nothing may go in it that would be needed to recover what hosts it:
the forge's own break-glass, or anything else whose absence would make this repository unreachable, belongs in a
source that does not depend on the forge being up.

## A service built later

Most of what these invariants will govern has not been built. A network API of our own, a service someone stands
up next quarter, any other not yet built: each time the question is not which tier it goes in, which is settled,
but whether it can be tier 2 at all. That turns out to be a requirement on the service rather than on this
repository, and it is far cheaper to state while the service is still a design than to discover at the first
session that wants it.

What a service has to provide to be reachable at tier 2:

1. **A name people already use for it**, the same in the service list as in the thing itself.
2. **A human login through a mechanism that already exists.** For anything we build that is the identity provider
   Dataverket runs, as a browser session. A service that arrives with its own password file has broken
   invariant 1 before it is installed.
3. **A credential it can mint with a lifetime, on the authority of that login.** This is the requirement, and the
   one that has to be designed in rather than bolted on: tokens that carry an expiry and are refused after it,
   issued per session, listable and revocable, so the service can answer who holds one right now. A service that
   can only issue a permanent token cannot be tier 2, and every session that touches it becomes an exception
   carried as tier 3 with a named human owner.
4. **Roles that `read` and `admin` can map onto.** Two is enough for a person to say, and the entry translates.
5. **A config file of its own for the artifact**, the one its CLI or its swamp model already reads, mode 0600.
   Then invariants 3 and 4 need nothing special: the model names the file, never the value.

That is also a review checklist for anything Dataverket builds. A service that cannot answer point 3 will
cost a permanent credential somewhere, and it is worth knowing which one before it is built.

The services are data, not code. One file lists every service this repository can ask for, an entry each: a plain
name, the kind, the endpoint spec, what each level maps to there, the artifacts it produces and the files they
land in, and the mechanism that unlocks the human's own access to it. The shape, not the schema:

```yaml
services:
  dataverket-prod:            # a cluster, named the way a person names it
    kind: omni
    endpoint: https://dataverket.eu-central-1.omni.siderolabs.io
    cluster: dataverket-prod
    unlock: omni-browser
  fabrikk-infra:              # one OpenStack project at one API endpoint
    kind: openstack
    endpoint: https://<keystone>/v3
    project: <project>
    unlock: pass://<share>/<item>/password
  <site>-hosts:               # bare metal over SSH, when there is a CA to sign for it
    kind: ssh
    hosts: [<host>, <host>]
    ca: <ssh ca>
    unlock: yubikey
```

The tasks then carry no cluster name, no Omni URL and no cloud name of their own: `CLUSTER` and `OMNI_URL` stop
being settings of the scripts and become fields of an entry, and a second cluster, a second cloud or a first rack
of machines is a new entry rather than a new script.

A request produces exactly the artifacts its services and levels call for, under the one lifetime, and nothing
else. That settles by principle what the tiers plan has to carry as a special case, a task you remember to run: the
Omni Operator key is minted when, and only when, the request said `admin` for that Omni, and a `read` session
cannot change a cluster because it never holds a credential that could. The narrowing is in time and in what you
declared, not in how finely you can slice a service.

And the request is the authority for what may exist, not only for what gets minted. A session that asks for
`read` where yesterday's asked for `admin` removes yesterday's admin artifacts rather than leaving them to expire,
so a downgrade actually downgrades. `task admin:status` shows the request beside what is on disk, hand-made items
included and left alone as always, and `task admin:logout` drops what the request created. In the tasks this is
two settings and no new vocabulary, for example
`WHO=beddari NEED="fabrikk-infra:admin dataverket-prod:read" task admin:login`, which is the everyday session:
volumes get changed, the cluster only gets looked at.

The request is worth signing later. The YubiKey that signs this repository's commits can sign the sentence too
(`ssh-keygen -Y sign`), which turns "who asked for admin on the production cluster on Tuesday" from a line the
asker wrote into one only the asker could have written. Not in this plan; the request is only shaped so that it
can be.

## Steps

1. **Write the service list**, from the infrastructure that exists on the day and no further: one entry per
   service, with its kind, its endpoint spec, what each level maps to there, the artifacts it produces and the
   files they land in, and the mechanism that unlocks a human's access to it. Today that is one Omni cluster and
   one OpenStack project.
2. **Keep it alive with the infrastructure.** An entry appears when the thing it names is built, `bootstrap.sh`
   being the
   natural place for a cluster's, and goes when the thing is retired. Without that the list becomes fiction.
3. **Take `WHO` and `NEED` in `admin:login`** and record the request for the session, so that the session has a
   scope before anything is minted and an answer afterwards to who asked for what.
4. **Let the request drive the session.** `admin:renew` mints what the request calls for and nothing else,
   `admin:status` shows the request beside what is on disk, and both remove artifacts the current request no
   longer covers, so that a downgrade downgrades. The Omni Operator key is the first thing this settles: it exists
   only in a session whose request said `admin` for that Omni.
5. **Report drift in `admin:status`:** an entry naming a cluster Omni does not have, or an Omni cluster no entry
   names, beside the hand-made items it already reports.
6. **Take the cluster name, the Omni URL and the cloud name out of the scripts.** They become fields of an entry,
   and a second cluster or a second cloud stops being a code change.

Signing the request is the step after these, and not in this plan.

## Not in this plan

- The tiers themselves and the steps that make this repository obey them: `docs/plans/2026-09-credential-tiers.md`.
- A machine identity for unattended work. Until `swamp serve` has one, a request is a person's and so is
  everything that runs inside it.
- Per-artifact requests. The narrowing beyond `read` and `admin` belongs to a policy engine deciding whether to
  grant a sentence, not to the sentence.

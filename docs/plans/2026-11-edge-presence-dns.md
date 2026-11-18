# Plan: presence across member sites, and the names that find it

Written 2026-11-18, from a conversation about a DNS layer that keeps the blog and the static sites reachable while
Dataverket grows onto dispersed member sites, homelabs included, and while any one site, osl1 first of all, is down
for a while. Rewritten the same day around a hidden primary: our PowerDNS decides the zone, independent providers
publish it. Work in progress: the certificate question at the end decides the first goal's shape. Nothing is applied.
The blog itself is `docs/plans/2026-11-blogg-writefreely-media.md`; this plan is where its public pages are served
from, and how `blogg.dataverket.org` finds them.

## Status, 2026-11-18

**Not started.** Every public name is one A record, `91.242.200.101`, the osl1 egress, TTL 1800, in DirectAdmin at
Nordhost (`ns1.nordkapp.net`, `ns2.nordkapp.net`); `www.dataverket.org` is a CNAME to the apex. `dvkt.no` is
DNSSEC-signed, `dataverket.org` is not; `dataverket.org` has MX at Nordhost and no AAAA. The www site is two nginx
pods with the site built into an image by digest (`artifacts/www/`). There is no second site serving anything
public; hov1 is a backup endpoint reached by address (decision 020). The deSEC plan (`2026-10-dns-desec.md`) is not
started, and its provider cannot serve this plan: deSEC's minimum TTL is 3600 s.

## Why

Three reasons, in the order they came:

1. **Presence that outlives a site.** When osl1 is down, the blog's posts and the website should still be readable.
   Authoring, identity, git and chat may pause; the published word should not.
2. **Growth onto member sites.** Decision 034 names three layers: the upstream that publishes, sites that run things,
   tenants. A member site should be able to carry Dataverket's public content by running one artifact set, with
   nothing to configure but its own address, and the organization's names should start pointing at it when it is up.
   Seven homelabs on 500 Mbit lines serve more static pages than this organization will publish for years.
3. **The names must not depend on osl1 either.** A failover that is driven from the site that failed is not one. The
   decision has to be made elsewhere, and the answer published by operators whose outage is not ours.

## Shape

| Layer | Does | Runs where |
|---|---|---|
| Publishing | Builds the content and signs it: the www site image as today, the documentation, and a static snapshot of the blog's public pages with the images they reference. Pushes each as an artifact into the registry, the gitless plan's shape, pinned by digest and signed | One place at a time; osl1 today |
| Presence | Pulls the artifacts by digest, verifies the signature against the organization's key, serves them over TLS for the organization's names and on its own site alias. Stateless: no login, no database, no federation | Every member site that wants to carry it: a Flux artifact in a cluster, or the same images under podman and systemd on one machine |
| Names | One hidden primary, PowerDNS, whose controller probes the presence nodes and writes the healthy sets into the zone; two or three public DNS providers serve the zone as secondaries and are the published name servers | The primary and its standby at two member sites, never osl1; the published servers at providers |

What stays at the publishing site: WriteFreely's authoring, its database, its ActivityPub inbox and outbox, `/api`,
`/.well-known/webfinger`. When that site is down, nobody posts and federation pauses, which Mastodon tolerates for
days of retries; the posts and images stay readable from presence. Identity, git and Zulip are not presence
content; their names fail to a status page the same nodes serve.

## The names

### One delegated zone, published by others

A dedicated zone, `edge.dvkt.no`, delegated from `dvkt.no` at Nordhost: its NS records name the public secondaries,
not us. The registrar, the apexes and mail stay where they are, and nothing of ours listens on port 53 to the world.

| Name | Record | Lives | TTL |
|---|---|---|---|
| `www.edge.dvkt.no`, `blogg.edge.dvkt.no`, `docs.edge.dvkt.no` | A and AAAA: the presence nodes currently up, as the controller last wrote them | Our zone, served by the providers | 300 |
| `_acme-challenge.www.edge.dvkt.no` and the like | TXT, written by a presence node's ACME client for the minutes a challenge lasts | Our zone | 60 |
| `www.dataverket.org`, `blogg.dataverket.org`, `docs.dataverket.org` | CNAME into `edge.dvkt.no` | Nordhost, static | 3600 or more |
| `_acme-challenge.www.dataverket.org` and the like | CNAME to the matching name in `edge.dvkt.no`, so a DNS-01 challenge for the organization's names is answered from our zone | Nordhost, static | 3600 |
| `www.<site>.dvkt.no` | A and AAAA of that site's presence node | The site's zone, static (decision 031) | 3600 |
| `dataverket.org` | A of two or three presence nodes that only redirect to www | Nordhost, static | 1800 |

Resolvers cache the CNAME and re-resolve its target on the target's own TTL, so the dynamic part is entirely ours
and Nordhost is in no hot path: its part is a handful of records that change when a provider or a presence node
joins or leaves, which DirectAdmin handles well. What it handles badly, frequent writes and bounded tokens, never
reaches it. The apex cannot be a CNAME; it keeps static addresses and a redirect, or the whole `dataverket.org`
zone moves to the same hidden primary later, which the deSEC plan already lists as its last step and which would
also remove the one dependency left: Nordhost's own servers answering for `dvkt.no` and `dataverket.org`, the risk
every zone has today.

`dvkt.no` is signed, so `edge.dvkt.no` is either signed too, with a DS record in the parent, or delegated insecure,
with no DS, which a signed parent allows and validating resolvers accept as unsigned. The delegation starts insecure:
the names people use are the CNAMEs in `dataverket.org`, which is unsigned anyway. Signing later is a key on the
primary and its standby only, a pre-signed zone transferred as it is, and one DS record at Nordhost; no change of
software.

### The software: PowerDNS Authoritative as a hidden primary, decided

Decided 2026-11-18. Health is decided in one place and published by many:

- **The primary** runs PowerDNS Authoritative with the edge zone in its own backend and the HTTP API on. Beside it
  runs the controller, a small Go program of ours: every interval it probes every presence node, computes the healthy
  set per name, and when the set differs from the zone writes plain A and AAAA records through the API, which bumps
  the serial (`SOA-EDIT-API`) and sends NOTIFY. Nothing else writes the zone but ACME challenges, through the same
  API.
- **The standby** is a PowerDNS secondary of the primary with the controller installed and idle, at another site.
  It takes the primary role by configuration; the providers list both addresses as primaries where they allow it, so a
  takeover changes nothing at the providers.
- **The public secondaries** are DNS providers that serve a zone transferred from a customer's primary with NOTIFY:
  Hetzner DNS and Hurricane Electric both do, at no cost; Nordhost joins if it offers the same, which is a question to
  its support, not an assumption. AXFR is allowed only from the providers' transfer addresses, with TSIG where a
  provider takes it. The NS records in the parent name these servers, two or three operators with nothing in common
  with each other or with us.

| Weighed | Why not, or why |
|---|---|
| gdnsd on member-run public servers | Built for health-driven answers and simple, but its HTTP monitor speaks plain HTTP/1.0, it has no DNSSEC and no API, its release cadence is unclear, and every server is a home link on port 53 |
| PowerDNS Lua records on member-run public servers | The first version of this plan: `ifurlup()` deciding at answer time on each server. Honest and without shared state, but each server has its own view, each homelab needs a stable address as glue and takes the floods, and the set of servers has to be curated |
| Knot DNS with a controller writing the zone | Signs zones and is solid; the controller is the same program as below, and PowerDNS's API saves writing a zone file and reloading |
| **PowerDNS as a hidden primary, providers as public secondaries** | Chosen. One writer, one view, no inconsistency between name servers; the member-run part is two small servers with no public exposure; answers come from operators whose outage is not ours; the API gives DNS-01 for free; DNSSEC when wanted; standard zone transfer, packaged everywhere, maintained |

### The numbers

| Setting | Value | Why |
|---|---|---|
| Probe interval | 15 s | Seven nodes probed by one controller is a request every two seconds |
| Probe | HTTPS to the node's site alias, certificate verified, `GET /healthz` 200, the served artifact digest read from the body and compared with the current one | A node is up when it serves the right thing, not when it answers TCP |
| Down after | 3 failures in a row | A minute of detection |
| Up after | 5 successes in a row | Asymmetric, so a flapping node stays out |
| Change rate | At most one write per name per minute, and the whole zone at most 20 writes an hour | A provider's transfer path is not a message bus; flapping is damped before it becomes NOTIFYs |
| TTL on the failover names | 300 s | Under 60 many resolvers clamp; 300 gives about six minutes to a converged failover with one-minute detection, and six times today's query load, which is trivial |
| Propagation | NOTIFY and IXFR to the providers, seconds | Measured in goal 4; a provider that only polls on the SOA refresh is not used for this zone |
| Floor | Never fewer than one address per name; when every node fails, the zone is left as it was | An empty answer is the one outcome worse than a stale one |
| Canary | When every node fails at once, the controller fetches a name outside our estate; if that fails too, it is the controller's network, and it writes nothing | One vantage point must know when it is the one that is blind |
| Stale but healthy | A node on an older digest is written after the current ones, and dropped only when a current one exists | Behind is better than absent |
| Primary down | The zone freezes at its last state; the standby takes over by configuration after a human looks, or after an hour by itself if that is wanted (question 4) | Fail-static is the behaviour the floor already asks for |

The one vantage point is the design's honest weakness: the controller's network decides for everyone. The canary and
the floor bound what a blind controller can do, and the standby at another site is the second opinion when a human
asks for it.

### What a member site must have to run the primary or the standby

- A stable public address the providers can transfer from; nothing listens on it but AXFR for the providers' addresses
  and the API on a private interface.
- Outbound HTTPS to every presence node and to the registry, for the controller and for the artifact.
- The announcer artifact, pulled by digest and verified: PowerDNS, the controller, the zone with its names, and the
  provider list. Its only local inputs are its own address and its role.
- The same age key handling as a cluster node for the TSIG keys and, later, the zone signing key.

### What a member site must have to run a presence node

- Upload bandwidth is what counts: a symmetric 500 Mbit line serves tens of thousands of static pages a second; a
  line with 50 Mbit up does a tenth of that. DNS round-robin sends every node an equal share, so the weakest upload
  sets the comfortable ceiling.
- A stable address, published as its site alias.
- The presence artifact: nginx-unprivileged with the content images mounted, a `/healthz` that reports the served
  digests, an ACME client that renews through the primary's API, and a puller that fetches new digests from the
  registry, verifies them and swaps. Nothing else listens.

## Publishing

- **www and docs**: the site image exists (`artifacts/www/site.sh`); docs are the same pattern.
- **The blog snapshot**: WriteFreely has no webhook, so publishing polls the blog's feed and, on change, crawls the
  public pages and the images they reference into one image, keeping WriteFreely's URLs (`/<alias>/<slug>`), and
  pushes it. A few minutes behind a post at most. The paths that need the live WriteFreely answer 503 from
  presence, or proxy to the publishing site while it is up.
- Every artifact is signed with the organization's key (the gitless plan's goal 3, `@dataverket/cosign`), and a
  presence node serves nothing it cannot verify. That is the cooperative shape: the organization publishes, members
  carry, and neither can put words in the other's mouth.

## Certificates

Every presence node must present a certificate for `www.dataverket.org` and the other organization names. With the
primary's API in hand, each node gets its own: its ACME client asks for one certificate covering the organization
names it serves and its own site alias, answers the DNS-01 challenge by writing the TXT through the API, which the
`_acme-challenge` CNAMEs in `dataverket.org` lead to, and renews on its own schedule. The site alias in the name set
keeps every node's certificate distinct, so Let's Encrypt's limit on duplicate certificates, five a week for one
exact set of names, is never met even when seven nodes start on the same day. No private key for the organization's
names leaves the node that uses it, and publishing holds none.

The alternative, publishing issuing one certificate per name and sealing its key to every node, needs no API and
would have been the start under the earlier design; it puts the same key on every member's machine and is kept only
as the fallback if the API path fails in goal 2.

## Goals, in order

1. **Nordhost asked** whether it serves secondary zones from an external primary with NOTIFY and TSIG; and a kind
   cluster showing PowerDNS's API writing a record with the serial bumped, a NOTIFY received by a secondary, an IXFR
   done, and the controller's loop against two fake nodes. Days of work, nothing public.
2. **The primary and the standby** at two member sites, with Hetzner DNS and Hurricane Electric as secondaries and the
   insecure delegation of `edge.dvkt.no` from Nordhost, with one name in it that nothing depends on. Propagation
   timed. The first ACME certificate issued through the API for a test name.
3. **The presence artifact**, served on a site alias at hov1 or a homelab: www and docs first, `/healthz` with
   digests, the puller, the certificate from the API. Probed by an `@dataverket/http` endpoint model, as `www` is
   today.
4. **One name moved**: `docs.dataverket.org` as a CNAME into the edge zone, where nothing but readers notice.
   Watched for weeks: a node taken down on purpose, the failover timed, the controller's writes counted.
5. **The blog snapshot** into presence, once the blog plan's goal 2 has a WriteFreely to snapshot; then `www` and
   `blogg` moved. More presence nodes as members join; the checklists above are what a member reads first.
6. **Later, if at all**: the `dataverket.org` apex and zone onto the same hidden primary, mail included; signing the
   edge zone with a pre-signed transfer and a DS record at Nordhost.

## What must be settled

1. **Certificates**, as above: the API path is the plan; the sealed-key fallback is kept until goal 2 has issued one.
2. **The zone name**: `edge.dvkt.no` is a proposal. It sits in the sites' zone because it is infrastructure of the
   sites, not a tenant's name (034); a name under `dataverket.org` would put the registrar back in the hot path.
3. **The providers**: Hetzner and Hurricane Electric are the proposals, Nordhost the question; whether either clamps a
   TTL of 300 or 60 on a transferred zone, and how each takes TSIG, is checked in goal 1. Three operators is the aim.
4. **Primary takeover**: by a person after a look, or by the standby itself after an hour without the primary; and
   whether the providers accept two primary addresses, which decides how much a takeover touches.
5. **The apex.** Static addresses with a redirect, accepting that `dataverket.org` typed bare can be down while
   `www` is up; or the whole zone moved, with mail.
6. **The status page** for the names that are not presence content: whether presence serves it, and what it says.
7. **Who runs the primary and the standby.** A presence node can be anyone's; the primary decides the organization's
   answers, so the two sites are chosen and named in this repository.

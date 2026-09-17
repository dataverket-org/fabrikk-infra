# 004: The cluster fetches its own registry through the Service, not the public name

Accepted 2026-09-17. Refines 003.

**Context.** The first pointer used `registry.dataverket.org`. Its first lookup ran before external-dns had created
the record, and the zone's negative TTL is three hours, so the upstream resolver kept answering NXDOMAIN. That
exposed the real problem: the registry's own config depended on external DNS, the LoadBalancer, and the certificate.

**Decision.** `apps/zot/source.yaml` pulls from `zot.zot.svc.cluster.local:5000` with `insecure: true`. This is the
one deliberate exception to "one name for the registry": it exists to survive the edge being broken. Everything
that consumes artifacts, on this cluster or elsewhere, uses the public name; pushes use the public name; cosign
signatures are made against it.

**Consequences.** Plain HTTP inside the cluster network for this one fetch until zot gets an internal certificate.
The internal name is a per-cluster fact and is recorded in the README's names table. When a second cluster exists,
per-cluster names move into a ConfigMap under `clusters/<name>/` and `postBuild.substituteFrom`; not before.

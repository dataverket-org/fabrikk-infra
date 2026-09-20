# backup/hov1: the hov1 site

The backup target for dataverket-prod: the versitygw stack of `../versitygw` at `213.128.185.82:443`, written to by
the CNPG Barman Cloud plugin and by restic. It is the copy that lives in a different building, on a different network,
under a different provider's mistakes. The stack, its scripts and the account handover are documented in
`../versitygw/README.md`; this directory is what makes it hov1: `.env` (from `.env.example`, never committed),
`certs/ca.crt` (committed, pinned by the cluster). What is written here, by whom, into which bucket, is the table in
`../README.md`.

The site's public facts, root, endpoint and region, are `hov1-s3` in each writing namespace. On the host:
`cp .env.example .env`, fill it in, create the two directories on an xattr filesystem, forward 443, then
`../versitygw/bin/cert`, and the stack is up. If the address ever changes, the certificate and the `hov1-s3` Secrets
change with it, a plaintext diff; a name (`s3.hov1.dvkt.no`, set through DirectAdmin's DNS API for `dvkt.no`) is the
day that stops being true, and is not needed before.

Backups of the gateway itself: none, it is the backup. If the host or the disk under `DATA_DIR` is lost, the cluster
still runs; the runbook in `../versitygw/README.md` brings a new one up, and the next base backup refills the buckets.
A second copy elsewhere is a decision for the plan, not for this directory.

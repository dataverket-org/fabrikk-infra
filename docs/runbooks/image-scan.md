# Runbook: read a red image scan, and answer it

Written 2026-11-22. `bin/image-scan` ran that day against every image `main` names; the workflow has not yet run on
the forge.

## Why

The cluster runs upstream images, and an image is as old as the day it was built. `bin/image-scan` scans every
image the artifacts name with grype, and the workflow `image-scan` runs it every morning at 05:23 UTC, on a change
to an artifact, and by hand. It fails on two kinds of finding and on nothing else: one on the known-exploited
list, and a Critical one its distribution has fixed. Those are the two a person can and should act on. This is
how each red line is answered.

## What it touches

| What | Read or written | Needs |
|---|---|---|
| The registries of every image under `artifacts/`, and grype's database | Read | Nothing; no login, no cluster |
| `share/image-scan-accepted` | Written when a finding is accepted, in a pull request | Nothing; the merge is signed |
| The cluster, any image, any `*.enc.yaml` | Never touched | |

## Steps

1. Read the run on the forge, or run it here; it needs `grype` and `jq` on `PATH`, which `brew bundle` installs:

   ```sh
   bin/image-scan                 # every image
   bin/image-scan --list          # the images, nothing scanned
   bin/image-scan <image>         # one, as it is written in the manifest
   ```

   A line per finding that counts, then one line per image:

   ```
     OPEN      CVE-2026-4738 zlib 1.3.2-r1 -> 1.4-r0 (critical-fixable)
     accepted  GO-2026-6612 golang.org/x/net v0.58.0 -> 0.60.0 (critical-fixable; until 2026-12-22: ...)
   !!! code.forgejo.org/forgejo/runner:13.2.2: 1 open, 1 accepted
   ```

2. For each `OPEN` line, ask whether a newer release of the image is free of it:

   ```sh
   bin/image-scan <the same image at its newest tag>
   ```

   If it is, the answer is the upgrade: Renovate's pull request for that image if there is one
   (`renovate-pull-request.md`), or the service's own runbook (`forge-upgrade.md`, `runner-upgrade.md`,
   `postgres-minor-upgrade.md`). A known-exploited finding does not wait for Renovate's seven days: on the
   dashboard issue of the repository, tick the update under "Pending Status Checks" and Renovate opens it on its
   next run.

3. If no release is free of it, read the finding itself, by its id at `https://osv.dev/vulnerability/<id>` or
   `https://nvd.nist.gov/vuln/detail/<id>`, and decide whether the way the image is used here reaches it. Then
   one of two:

   - It is reached, or you cannot tell, and it is known-exploited: the service is changed so that it is not (a
     feature turned off, a route closed), or stopped. That is a decision for the operators together, today.
   - It is not reached, or it is and the fix is days away: accept it for a time. One line in
     `share/image-scan-accepted`, in a pull request, so the merge that accepts it is signed:

     ```
     <finding> <image without tag> <last day, YYYY-MM-DD> <reason>
     ```

     The last day is at most 31 days away; the scan does not take a line with a later day, or with anything but
     a date. On the day after, the scan fails on the finding again and this step is taken again, with what is
     known by then.

4. `the scan itself failed!` beside an image is not a finding. The scan tries each image twice; a second failure
   is a registry that does not answer, an image that is gone, or grype's database not downloaded. Run that one
   image by hand and read grype's own message.

## Proof

```sh
bin/image-scan; echo "exit $?"
```

`>>> <n> images scanned, nothing open` and exit 0. On 2026-11-22 that was the result for the forge's four upgraded
images, with seven findings accepted to 2026-12-22. An accepted line whose last day had passed was open again, and
so was one whose last day was a year away or the word `never`; a line for one image did not cover another; a
registry that did not answer counted as a failure. The workflow itself ran once that day, in kind on runner
13.2.2: 33 images in seven minutes, no scan failed.

On that day `main` itself was far from it: every one of its 31 images had an open finding, and six carried a
known-exploited one, brotli in all six. The workflow is red until those images are moved, and that is the truth
it is there to tell.

## What a green scan does not say

- **Postgres itself.** grype does not match Postgres's own CVEs against the server package: 18.4 and 18.7 scan
  alike in that respect, though 80 CVEs lie between them. The Postgres minor is read at
  `https://www.postgresql.org/support/security/` (`postgres-minor-upgrade.md`).
- **What has no fix.** A Critical finding its distribution has not fixed is not counted, since no upgrade answers
  it. `grype registry:<image>` lists them all.
- **Forgejo's own flaws.** The Forgejo project publishes its security fixes in release notes without CVE ids, so
  no scanner knows them. A new patch release on the LTS line is read the day it comes (`forge-upgrade.md`).
- **What runs.** The scan reads the manifests in git. An image named `:latest` is scanned as it is today, and the
  cluster may run an older pull of it.
- **An image named some other way.** The scan finds an image in `image:`, `imageName:`, the `reference:` of an image
  volume and an argument that ends in `-image=`. `bin/image-scan --list` shows what it found.

## Not part of this

Moving grype: its version and SHA-256 are in `.forgejo/workflows/image-scan.yaml`, and Renovate proposes both
together. Scanning source code or Go modules of our own repositories, which Renovate does through OSV in each
repository. Signing or verifying an image.

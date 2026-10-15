# /// script
# requires-python = ">=3.12"
# dependencies = ["boto3==1.43.74"]
# ///
"""Puts the avatar policy on Zulip's osl1 buckets and runs the S3 proofs of docs/plans/2026-10-zulip.md, decision B.

Run as the `zulip` account with boto3 1.43.74, the version Zulip 12.3 pins; the secret in the environment, never an
argument:

    AWS_ACCESS_KEY_ID=zulip \
    AWS_SECRET_ACCESS_KEY="$(sops -d --extract '["stringData"]["SECRET_ACCESS_KEY"]' artifacts/zulip/s3-zulip.enc.yaml)" \
    uv run artifacts/zulip/s3.py policy|prove [--big]

`prove` writes only under `proof/` and deletes it; `--big` adds one 2 GiB PUT in a single request, the S3 plan's
step 4. Not part of the artifact.
"""

import io
import json
import os
import sys
import urllib.error
import urllib.request

import boto3
from botocore.config import Config

ENDPOINT = "https://dataverket.s3.osl1.dvkt.no"
REGION = "us-east-1"
UPLOADS = "zulip-uploads"
AVATARS = "zulip-avatars"
PREFIX = "proof/"

checks = []


def client(checksum="when_supported"):
    """Returns a client configured as Zulip's get_bucket() configures it, with the given checksum mode."""
    return boto3.client(
        "s3",
        endpoint_url=ENDPOINT,
        region_name=REGION,
        config=Config(
            s3={"addressing_style": "path"},
            signature_version="s3v4",
            request_checksum_calculation=checksum,
        ),
    )


def check(name, ok, detail=""):
    """Records one proof and prints it."""
    checks.append(ok)
    print(("PASS " if ok else "FAIL ") + name + (": " + detail if detail else ""), flush=True)


def fetch(url, headers=None):
    """Fetches a URL without credentials and returns the status and the response headers."""
    request = urllib.request.Request(url, headers=headers or {})
    try:
        with urllib.request.urlopen(request) as response:
            response.read()
            return response.status, response.headers
    except urllib.error.HTTPError as error:
        return error.code, error.headers


def policy():
    """Puts the world-readable policy on the avatar bucket."""
    # versitygw v1.9.0 combines a policy with the ACL (#2495), so the owner's rights stay in the ACL.
    document = {
        "Version": "2012-10-17",
        "Statement": [{
            "Effect": "Allow",
            "Principal": {"AWS": "*"},
            "Action": ["s3:GetObject"],
            "Resource": ["arn:aws:s3:::%s/*" % AVATARS],
        }],
    }
    client().put_bucket_policy(Bucket=AVATARS, Policy=json.dumps(document))
    print(json.dumps(json.loads(client().get_bucket_policy(Bucket=AVATARS)["Policy"]), indent=2))


def prove(big):
    """Runs the proofs and deletes what they wrote."""
    s3 = client()

    # versitygw #2398.
    s3.put_object(Bucket=UPLOADS, Key=PREFIX + "plain.txt", Body=b"zulip proof\n", ContentType="text/plain")
    encoding = s3.head_object(Bucket=UPLOADS, Key=PREFIX + "plain.txt").get("ContentEncoding", "")
    check("put without aws-chunked", "aws-chunked" not in encoding, "Content-Encoding=%r" % encoding)

    s3.put_object(Bucket=UPLOADS, Key=PREFIX + "six.bin", Body=os.urandom(6 * 1024 * 1024))
    url = s3.generate_presigned_url("get_object", ExpiresIn=300, Params={
        "Bucket": UPLOADS, "Key": PREFIX + "six.bin",
        "ResponseContentDisposition": 'attachment; filename="six.bin"'})
    status, headers = fetch(url)
    check("presigned get", status == 200 and "six.bin" in (headers.get("Content-Disposition") or ""),
          "%s %s" % (status, headers.get("Content-Disposition")))
    status, _ = fetch(url, {"Range": "bytes=0-5242879"})
    check("presigned range", status == 206, str(status))

    s3.put_object(Bucket=AVATARS, Key=PREFIX + "avatar.png", Body=b"\x89PNG proof", ContentType="image/png")
    status, _ = fetch("%s/%s/%savatar.png" % (ENDPOINT, AVATARS, PREFIX))
    check("anonymous get on avatars", status == 200, str(status))
    status, _ = fetch("%s/%s/%splain.txt" % (ENDPOINT, UPLOADS, PREFIX))
    check("anonymous get on uploads refused", status == 403, str(status))
    for bucket in (UPLOADS, AVATARS):
        keys = [o["Key"] for o in s3.list_objects_v2(Bucket=bucket, Prefix=PREFIX).get("Contents", [])]
        check("owner lists " + bucket, len(keys) > 0, "%d keys" % len(keys))

    # Zulip's tusd hook rewrites headers this way (zerver/views/tusd.py).
    s3.copy_object(Bucket=UPLOADS, Key=PREFIX + "plain.txt",
                   CopySource={"Bucket": UPLOADS, "Key": PREFIX + "plain.txt"}, MetadataDirective="REPLACE",
                   ContentType="text/markdown", ContentDisposition='inline; filename="plain.md"')
    head = s3.head_object(Bucket=UPLOADS, Key=PREFIX + "plain.txt")
    check("copy onto itself", head.get("ContentType") == "text/markdown" and
          "plain.md" in head.get("ContentDisposition", ""), "%s, %s" % (head.get("ContentType"),
                                                                       head.get("ContentDisposition")))

    s3.upload_fileobj(io.BytesIO(os.urandom(20 * 1024 * 1024)), UPLOADS, PREFIX + "twenty.bin")
    etag = s3.head_object(Bucket=UPLOADS, Key=PREFIX + "twenty.bin")["ETag"]
    check("multipart upload", "-" in etag, etag)

    for n in range(5):
        s3.put_object(Bucket=UPLOADS, Key=PREFIX + "page/%d" % n, Body=b"x")
    pages = list(s3.get_paginator("list_objects_v2").paginate(Bucket=UPLOADS, Prefix=PREFIX + "page/",
                                                               PaginationConfig={"PageSize": 2}))
    check("list pages", len(pages) == 3 and sum(p.get("KeyCount", 0) for p in pages) == 5, "%d pages" % len(pages))

    # The S3 plan's step 4: one request through Envoy, which a route request timeout would cut.
    if big:
        size = 2 * 1024 * 1024 * 1024
        chunk = os.urandom(1024 * 1024)

        class Stream(io.RawIOBase):
            """Yields 2 GiB of one random MiB, repeated."""
            left = size

            def readable(self):
                return True

            def readinto(self, buffer):
                n = min(len(buffer), self.left, len(chunk))
                buffer[:n] = chunk[:n]
                self.left -= n
                return n

        client("when_required").put_object(Bucket=UPLOADS, Key=PREFIX + "big.bin", Body=Stream(),
                                           ContentLength=size)
        length = s3.head_object(Bucket=UPLOADS, Key=PREFIX + "big.bin")["ContentLength"]
        check("2 GiB in one PUT", length == size, str(length))

    for bucket in (UPLOADS, AVATARS):
        keys = [{"Key": o["Key"]} for o in s3.list_objects_v2(Bucket=bucket, Prefix=PREFIX).get("Contents", [])]
        if keys:
            deleted = s3.delete_objects(Bucket=bucket, Delete={"Objects": keys}).get("Deleted", [])
            check("delete_objects in " + bucket, len(deleted) == len(keys), "%d of %d" % (len(deleted), len(keys)))

    print("%d of %d passed" % (sum(checks), len(checks)))
    return all(checks)


if __name__ == "__main__":
    if sys.argv[1:2] == ["policy"]:
        policy()
    elif sys.argv[1:2] == ["prove"]:
        sys.exit(0 if prove("--big" in sys.argv) else 1)
    else:
        sys.exit("usage: s3.py policy|prove [--big]")

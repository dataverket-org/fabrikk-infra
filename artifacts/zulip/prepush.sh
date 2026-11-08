#!/bin/sh
# Before the artifact is pushed: the Postgres image, built and pushed by postgres-image.sh (bin/artifact sets user and password).
exec ./postgres-image.sh --push

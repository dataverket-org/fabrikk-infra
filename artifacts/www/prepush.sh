#!/bin/sh
# Before the artifact is pushed: the www-site image, built and pushed by site.sh (bin/artifact sets user and password).
exec ./site.sh --push

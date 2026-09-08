#!/bin/sh

set -xeu

kubectl create secret -n kube-system generic cloud-config --from-file=./cloud.conf

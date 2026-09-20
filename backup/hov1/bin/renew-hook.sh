#!/bin/bash
# Run by step-renew after each renewal: versitygw reads its certificate at start, so restart it over the socket.
curl -sf --unix-socket /var/run/docker.sock -X POST http://localhost/containers/hov1-versitygw/restart

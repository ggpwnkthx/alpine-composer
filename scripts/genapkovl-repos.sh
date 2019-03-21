#!/bin/sh -e

# Get shared functions and unpack any existing overlays
source $(dirname $0)/shared_functions.sh

# Establish repositories
makefile root:root 0644 "$tmp"/etc/apk/repositories <<EOF
/media/cdrom/apks
http://dl-cdn.alpinelinux.org/alpine/edge/main
http://dl-cdn.alpinelinux.org/alpine/edge/community
http://dl-cdn.alpinelinux.org/alpine/edge/testing
EOF

# Repackage the overlay file
overlay_repack

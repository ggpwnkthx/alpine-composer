#!/bin/sh -e

# Get shared functions and unpack any existing overlays
source $(dirname $0)/shared_functions.sh

# Message of the Day
makefile root:root 0644 "$tmp"/etc/motd <<EOF
Welcome to Alpine!

You can install to a disk with the command: install-os

You may change this message by editing /etc/motd.

EOF

# Repackage the overlay file
overlay_repack
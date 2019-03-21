#!/bin/sh -e

# Remove old overlay files
if [ -f $(dirname $(pwd))/*.apkovl.tar.gz ] ; then
	rm $(dirname $(pwd))/*.apkovl.tar.gz
fi

# Get shared functions
source $(dirname $0)/shared_functions.sh

# Add APKs
apk_add alpine-base alpine-mirrors busybox kbd-bkeymaps chrony e2fsprogs network-extras libressl openssh tzdata

# OpenRC services
rc_add devfs sysinit
rc_add dmesg sysinit
rc_add mdev sysinit
rc_add hwdrivers sysinit
rc_add modloop sysinit

rc_add hwclock boot
rc_add modules boot
rc_add sysctl boot
rc_add hostname boot
rc_add bootmisc boot
rc_add syslog boot

rc_add networking default

rc_add mount-ro shutdown
rc_add killprocs shutdown
rc_add savecache shutdown

# Repackage the overlay file
overlay_repack

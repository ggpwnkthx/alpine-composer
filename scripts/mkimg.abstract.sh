build_uboot() {
	set -x
	# FIXME: Fix apk-tools to extract packages directly
	local pkg pkgs="$(apk fetch  --simulate --root "$APKROOT" --recursive u-boot-all | sed -ne "s/^Downloading \([^0-9.]*\)\-.*$/\1/p")"
	for pkg in $pkgs; do
		[ "$pkg" = "u-boot-all" ] || apk fetch --root "$APKROOT" --stdout $pkg | tar -C "$DESTDIR" -xz usr
	done
	mkdir -p "$DESTDIR"/u-boot
	mv "$DESTDIR"/usr/sbin/update-u-boot "$DESTDIR"/usr/share/u-boot/* "$DESTDIR"/u-boot
	rm -rf "$DESTDIR"/usr
}

section_uboot() {
	[ -n "$uboot_install" ] || return 0
	build_section uboot $ARCH $(apk fetch --root "$APKROOT" --simulate --recursive u-boot-all | sort | checksum)
}

profile_abstract() {
	profile_base
	arch="x86_64 x86 ppc64le s390x aarch64 armhf armv7"
	kernel_addons="xtables-addons"
	case "$ARCH" in
	x86 | x86_64 | s390x | ppc64le)
		image_ext="iso"
		output_format="iso"
		;;
	aarch64 | armhf | armv7)
		image_ext="tar.gz"
		initfs_features="base bootchart squashfs ext4 kms mmc raid scsi usb"
		uboot_install="yes"
		;;
	esac
	
	case "$ARCH" in
	s390x)
		apks="$apks s390-tools"
		initfs_features="$initfs_features dasd_mod qeth"
		initfs_cmdline="modules=loop,squashfs,dasd_mod,qeth quiet"
		;;
	ppc64le)
		initfs_cmdline="modules=loop,squashfs,sd-mod,usb-storage,ibmvscsi quiet"
		;;
	esac
}
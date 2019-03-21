#!/bin/sh -e

source $(dirname $0)/shared_functions.sh

# Installer
mkdir -p "$tmp"/sbin
makefile root:root 0755 "$tmp"/sbin/install-disk <<EOF
#!/bin/sh

PREFIX=
. "\$PREFIX/lib/libalpine.sh"
. "\$PREFIX/lib/dasd-functions.sh"

MBR=\${MBR:-"/usr/share/syslinux/mbr.bin"}
ROOTFS=\${ROOTFS:-ext4}
BOOTFS=\${BOOTFS:-ext4}
VARFS=\${VARFS:-ext4}
BOOTLOADER=\${BOOTLOADER:-syslinux}
DISKLABEL=\${DISKLABEL:-dos}

# default location for mounted root
SYSROOT=\${SYSROOT:-/mnt}

# machine arch
ARCH=\$(apk --print-arch)

in_list() {
	local i="\$1"
	shift
	while [ \$# -gt 0 ]; do
		[ "\$i" = "\$1" ] && return 0
		shift
	done
	return 1
}

all_in_list() {
	local needle="\$1"
	local i
	[ -z "\$needle" ] && return 1
	shift
	for i in \$needle; do
		in_list "\$i" \$@ || return 1
	done
	return 0
}

# wrapper to only show given device
_blkid() {
	blkid | grep "^\$1:"
}

# if given device have an UUID display it, otherwise return the device
uuid_or_device() {
	local i=
	case "\$1" in
		/dev/md*) echo "\$1" && return 0;;
	esac
	for i in \$(_blkid "\$1"); do
		case "\$i" in
			UUID=*) eval \$i;;
		esac
	done
	if [ -n "\$UUID" ]; then
		echo "UUID=\$UUID"
	else
		echo "\$1"
	fi
}

# generate an fstab from a given mountpoint. Convert to UUID if possible
enumerate_fstab() {
	local mnt="\$1"
	local fs_spec= fs_file= fs_vfstype= fs_mntops= fs_freq= fs_passno=
	[ -z "\$mnt" ] && return
	local escaped_mnt=\$(echo \$mnt | sed -e 's:/*\$::' -e 's:/:\\/:g')
	awk "\\\$2 ~ /^\$escaped_mnt(\/|\\\$)/ {print \\\$0}" /proc/mounts | \
		sed "s:\$mnt:/:g; s: :\t:g" | sed -E 's:/+:/:g' | \
		while read fs_spec fs_file fs_vfstype fs_mntops fs_freq fs_passno; do
			if [ "\$fs_file" = / ]; then
				fs_passno=1
			else
				fs_passno=2
			fi
			echo -e "\$(uuid_or_device \$fs_spec)\t\${fs_file}\t\${fs_vfstype}\t\${fs_mntops} \${fs_freq} \${fs_passno}"
		done
}

is_vmware() {
	grep -q VMware /proc/scsi/scsi 2>/dev/null \
		|| grep -q VMware /proc/ide/hd*/model 2>/dev/null
}

# return true (0) if given device is lvm
is_lvm() {
	lvs "\$1" >/dev/null 2>&1
}

is_efi() {
	[ -d "/sys/firmware/efi" ] && return 0
	return 1
}

# Find the disk device from given partition
disk_from_part() {
	local path=\${1%/*}
	local dev=\${1##*/}
	echo \$path/\$(basename "\$(readlink -f "/sys/class/block/\$dev/..")")
}

# \$1 partition type (swap,linux,raid,lvm,prep,esp)
# return partition type id based on table type
partition_id() {
	local id
	if [ "\$DISKLABEL" = "gpt" ]; then
		case "\$1" in
			swap)	id=0657FD6D-A4AB-43C4-84E5-0933C84B4F4F ;;
			linux)	id=0FC63DAF-8483-4772-8E79-3D69D8477DE4 ;;
			raid)	id=A19D880F-05FC-4D3B-A006-743F0F84911E ;;
			lvm)	id=E6D6D379-F507-44C2-A23C-238F2A3DF928 ;;
			prep)	id=9E1A2d38-C612-4316-AA26-8B49521E5A8B ;;
			esp)	id=C12A7328-F81F-11D2-BA4B-00A0C93EC93B ;;
			*)	die "Partition id \"\$1\" is not supported!" ;;
		esac
	elif [ "\$DISKLABEL" = "dos" ]; then
		case "\$1" in
			swap)	id=82 ;;
			linux)	id=83 ;;
			raid)	id=fd ;;
			lvm)	id=8e ;;
			prep)	id=41 ;;
			esp)	id=EF ;;
			*)	die "Partition id \"\$1\" is not supported!" ;;
		esac
	elif [ "\$DISKLABEL" = "eckd" ]; then
		case "\$1" in
			native|lvm|swap|raid|gpfs)	id="\$1" ;;
		esac
	else
		die "Partition label \"\$DISKLABEL\" is not supported!"
	fi
	echo \$id
}

# find partitions based on partition type from specified disk
# type can be any type from partition_id or the literal string "boot"
find_partitions() {
	local dev="\$1" type="\$2" search=
	if is_dasd "\$dev" eckd; then
		case "\$type" in
			boot) echo "\$dev"1 ;;
			*) fdasd -p "\$dev" | grep "Linux \$(partition_id "\$type")" | awk '{print \$1}' | tail -n 1 ;;
		esac
		return 0
	fi
	case "\$type" in
		boot)
			search=bootable
			[ -n "\$USE_EFI" ] && search=\$(partition_id esp)
			sfdisk -d "\$dev" | awk '/'\$search'/ {print \$1}'
			;;
		*)
			search=\$(partition_id "\$type")
			sfdisk -d "\$dev" | awk '/type='\$search'/ {print \$1}'
			;;
	esac
}

unpack_apkovl() {
	local ovl="\$1"
	local dest="\$2"
	local suffix=\${ovl##*.}
	local i
	ovlfiles=/tmp/ovlfiles
	if [ "\$suffix" = "gz" ]; then
		if ! tar -C "\$dest" --numeric-owner -zxvf "\$ovl" > \$ovlfiles; then
			echo -n "Continue anyway? [Y/n]: "
			read i
			case "\$i" in
				n*|N*) return 1;;
			esac
		fi
		return 0
	fi

	apk add --quiet openssl

	if ! openssl list-cipher-commands | grep "^\$suffix\$" > /dev/null; then
		errstr="Cipher \$suffix is not supported"
		return 1
	fi
	local count=0
	# beep
	echo -e "\007"
	while [ \$count -lt 3 ]; do
		openssl enc -d -\$suffix -in "\$ovl" | tar --numeric-owner \
			-C "\$dest" -zxv >\$ovlfiles 2>/dev/null && return 0
		count=\$(( \$count + 1 ))
	done
	ovlfiles=
	return 1
}

# find filesystem of given mounted dir
find_mount_fs() {
	local mount_point="\$1"
	awk "\\\$2 == \"\$mount_point\" {print \\\$3}" /proc/mounts | tail -n 1
}

# find device for given mounted dir
find_mount_dev() {
	local mnt="\$1"
	awk "\\\$2 == \"\$mnt\" { print \\\$1 }" /proc/mounts | tail -n 1
}

supported_boot_fs() {
	local supported="ext2 ext3 ext4 btrfs xfs vfat"
	local fs=
	for fs in \$supported; do
		[ "\$fs" = "\$1" ] && return 0
	done
	echo "\$1 is not supported. Only supported are: \$supported" >&2
	return 1
}

supported_part_label() {
	case "\$1" in
		dos|gpt|eckd) return 0 ;;
		*) die "Partition label \"\$DISKLABEL\" is not supported!" ;;
	esac
}

find_volume_group() {
	local lv=\${1##*/}
	lvs --noheadings "\$1" | awk '{print \$2}'
}

find_pvs_in_vg() {
	local vg="\$1"
	pvs --noheadings | awk "\\\$2 == \"\$vg\" {print \\\$1}"
}

# echo current grsecurity option and set new
set_grsec() {
	local key="\$1" value="\$2"
	if ! [ -e /proc/sys/kernel/grsecurity/\$key ]; then
		return 0
	fi
	cat /proc/sys/kernel/grsecurity/\$key
	echo \$value > /proc/sys/kernel/grsecurity/\$key
}

init_chroot_mounts() {
	local mnt="\$1" i=
	for i in proc dev; do
		mkdir -p "\$mnt"/\$i
		mount --bind /\$i "\$mnt"/\$i
	done
}

cleanup_chroot_mounts() {
	local mnt="\$1" i=
	for i in proc dev; do
		umount "\$mnt"/\$i
	done
}

get_bootopt() {
	local opt="\$1"
	set -- \$(cat /proc/cmdline)
	for i; do
		case "\$i" in
			"\$opt"|"\$opt"=*) echo "\${i#*=}"; break;;
		esac
	done
}

# setup GRUB bootloader
setup_grub() {
	local mnt="\$1" root="\$2" modules="\$3" kernel_opts="\$4" bootdev="\$5"
	# install GRUB efi mode
	if [ -n "\$USE_EFI" ]; then
		local target fwa
		case "\$ARCH" in
			x86_64)		target=x86_64-efi ; fwa=x64 ;;
			x86)		target=i386-efi ; fwa=ia32 ;;
			arm*)		target=arm-efi ; fwa=arm ;;
			aarch64)	target=arm64-efi ; fwa=aa64 ;;
		esac
		# currently disabling nvram so grub doesnt call efibootmgr
		# installing to alpine directory so other distros dont overwrite it
		grub-install --target=\$target --efi-directory="\$mnt"/boot/efi \
			--bootloader-id=alpine --boot-directory="\$mnt"/boot --no-nvram
		# fallback mode will use boot/boot\${fw arch}.efi
		install -D "\$mnt"/boot/efi/EFI/alpine/grub\$fwa.efi \
			"\$mnt"/boot/efi/EFI/boot/boot\$fwa.efi
	# install GRUB for ppc64le
	elif [ "\$ARCH" = "ppc64le" ]; then
		shift 5
		local disks="\${@}"
		for disk in \$disks; do
			prep=\$(find_partitions "\$disk" "prep")
			echo "Installing grub on \$prep"
			grub-install --boot-directory="\$mnt"/boot \$prep
		done
	# install GRUB in bios mode
	else
		local bootdisk=\$(disk_from_part \$bootdev)
		case "\$ARCH" in
			x86|x86_64) grub-install --boot-directory="\$mnt"/boot \
				--target=i386-pc \$bootdisk ;;
			*) die "Cannot install GRUB in BIOS mode for \$ARCH" ;;
		esac
	fi

	# setup GRUB config. trigger will generate final grub.cfg
	install -d "\$mnt"/etc/default/
	cat > "\$mnt"/etc/default/grub <<- EOF
	GRUB_DISTRIBUTOR="Alpine"
	GRUB_TIMEOUT=2
	GRUB_DISABLE_SUBMENU=y
	GRUB_DISABLE_RECOVERY=true
	GRUB_CMDLINE_LINUX_DEFAULT="modules=\$modules \$kernel_opts"
	EOF
}

# setup syslinux bootloader
setup_syslinux() {
	local mnt="\$1" root="\$2" modules="\$3" kernel_opts="\$4" bootdev="\$5"
	local exlinux_raidopt=

	sed -e "s:^root=.*:root=\$root:" \
		-e "s:^default_kernel_opts=.*:default_kernel_opts=\"\$kernel_opts\":" \
		-e "s:^modules=.*:modules=\$modules:" \
		/etc/update-extlinux.conf > "\$mnt"/etc/update-extlinux.conf
	if [ "\$(rc --sys)" = "XEN0" ]; then
		sed -i -e "s:^default=.*:default=xen-grsec:" \
			"\$mnt"/etc/update-extlinux.conf
	fi

	# Check if we boot from raid so we can pass proper option to
	# extlinux later.
	if [ -e "/sys/block/\${bootdev#/dev/}/md" ]; then
		extlinux_raidopt="--raid"
	fi

	extlinux \$extlinux_raidopt --install "\$mnt"/boot
}

install_mounted_root() {
	local mnt="\$1"
	shift 1
	local disks="\${@}" mnt_boot= boot_fs= root_fs=
	local initfs_features="ata base ide scsi usb virtio"
	local pvs= dev= rootdev= bootdev= extlinux_raidopt= root= modules=
	local kernel_opts="quiet"
	[ "\$ARCH" = "s390x" ] && initfs_features="\$initfs_features qeth dasd_mod"

	rootdev=\$(find_mount_dev "\$mnt")
	if [ -z "\$rootdev" ]; then
		echo "\$mnt does not seem to be a mount point" >&2
		return 1
	fi
	root_fs=\$(find_mount_fs "\$mnt")
	initfs_features="\$initfs_features \$root_fs"

	if is_lvm "\$rootdev"; then
		initfs_features="\$initfs_features lvm"
		local vg=\$(find_volume_group "\$rootdev")
		pvs=\$(find_pvs_in_vg \$vg)
	fi


	bootdev=\$(find_mount_dev "\$mnt"/boot)
	if [ -z "\$bootdev" ]; then
		bootdev=\$rootdev
		mnt_boot="\$mnt"
	else
		mnt_boot="\$mnt"/boot
	fi
	boot_fs=\$(find_mount_fs "\$mnt_boot")
	supported_boot_fs "\$boot_fs" || return 1

	# check if our root is on raid so we can feed mkinitfs and
	# bootloader conf with the proper kernel module params
	for dev in \$rootdev \$pvs; do

		# check if we need hardware raid drivers
		case \$dev in
		/dev/cciss/*)
			initfs_features="\${initfs_features% raid} raid"
			;;
		/dev/nvme*)
			initfs_features="\${initfs_features% nvme} nvme"
			;;
		/dev/mmc*)
			initfs_features="\${initfs_features% mmc} mmc"
			;;
		esac

		[ -e "/sys/block/\${dev#/dev/}/md" ] || continue

		local md=\${dev#/dev/}
		initfs_features="\${initfs_features% raid} raid"
		local level=\$(cat /sys/block/\$md/md/level)
		case "\$level" in
			raid1) raidmod="\${raidmod%,raid1},raid1";;
			raid[456]) raidmod="\${raidmod%,raid456},raid456";;
		esac
	done


	if [ -n "\$VERBOSE" ]; then
		echo "Root device:     \$rootdev"
		echo "Root filesystem: \$root_fs"
		echo "Boot device:     \$bootdev"
		echo "Boot filesystem: \$boot_fs"
	fi

	if [ -z "\$APKOVL" ]; then
		ovlfiles=/tmp/ovlfiles
		lbu package - | tar -C "\$mnt" -zxv > "\$ovlfiles"
		# comment out local repositories
		if [ -f "\$mnt"/etc/apk/repositories ]; then
			sed -i -e 's:^/:#/:' "\$mnt"/etc/apk/repositories
		fi
	else
		echo "Restoring backup from \$APKOVL to \$rootdev..."
		unpack_apkovl "\$APKOVL" "\$mnt" || return 1
	fi

	# we should not try start modloop on sys install
	rm -f "\$mnt"/etc/runlevels/*/modloop

	# generate mkinitfs.conf
	mkdir -p "\$mnt"/etc/mkinitfs/features.d
	echo "features=\"\$initfs_features\"" > "\$mnt"/etc/mkinitfs/mkinitfs.conf
	if [ -n "\$raidmod" ]; then
		echo "/sbin/mdadm" > "\$mnt"/etc/mkinitfs/features.d/raid.files
		echo "/etc/mdadm.conf" >> "\$mnt"/etc/mkinitfs/features.d/raid.files
	fi

	# generate update-extlinux.conf
	root=\$(uuid_or_device \$rootdev)
	kernel_opts="\$kernel_opts rootfstype=\$root_fs"
	if is_vmware; then
		kernel_opts="pax_nouderef \$kernel_opts"
	fi
	if [ -n "\$(get_bootopt nomodeset)" ]; then
		kernel_opts="nomodeset \$kernel_opts"
	fi
	modules="sd-mod,usb-storage,\${root_fs}\${raidmod}"

	# generate the fstab
	if [ -f "\$mnt"/etc/fstab ]; then
		mv "\$mnt"/etc/fstab "\$mnt"/etc/fstab.old
	fi
	enumerate_fstab "\$mnt" >> "\$mnt"/etc/fstab
	if [ -n "\$SWAP_DEVICES" ]; then
		local swap_dev
		for swap_dev in \$SWAP_DEVICES; do
			echo -e "\$(uuid_or_device \${swap_dev})\tswap\tswap\tdefaults\t0 0" \
				>> "\$mnt"/etc/fstab
		done
	fi
	cat >>"\$mnt"/etc/fstab <<-__EOF__
		/dev/cdrom	/media/cdrom	iso9660	noauto,ro 0 0
		/dev/usbdisk	/media/usb	vfat	noauto	0 0
	__EOF__
	# remove the installed db in case its there so we force re-install
	rm -f "\$mnt"/var/lib/apk/installed "\$mnt"/lib/apk/db/installed
	echo "Installing system on \$rootdev:"
	case "\$BOOTLOADER" in
		grub) setup_grub "\$mnt" "\$root" "\$modules" "\$kernel_opts" "\$bootdev" \$disks ;;
		syslinux) setup_syslinux "\$mnt" "\$root" "\$modules" "\$kernel_opts" "\$bootdev" ;;
		zipl) setup_zipl "\$mnt" "\$root" "\$modules" "\$kernel_opts" ;;
		*) die "Bootloader \"\$BOOTLOADER\" not supported!" ;;
	esac

	# apk reads config from target root so we need to copy the config
	mkdir -p "\$mnt"/etc/apk/keys/
	cp /etc/apk/keys/* "\$mnt"/etc/apk/keys/

	local apkflags="--initdb --quiet --progress --update-cache --clean-protected"
	local pkgs=\$(grep -h -v -w sfdisk "\$mnt"/etc/apk/world \
		"\$mnt"/var/lib/apk/world 2>/dev/null)

	pkgs="\$pkgs acct linux-\$KERNEL_FLAVOR alpine-base"
	if [ "\$(rc --sys)" = "XEN0" ]; then
		pkgs="\$pkgs xen-hypervisor"
	fi
	local repos=\$(sed -e 's/\#.*//' /etc/apk/repositories)
	local repoflags=
	for i in \$repos; do
		repoflags="\$repoflags --repository \$i"
	done

	chroot_caps=\$(set_grsec chroot_caps 0)
	init_chroot_mounts "\$mnt"
	apk add --root "\$mnt" \$apkflags --overlay-from-stdin \
		\$repoflags \$pkgs <\$ovlfiles
	local ret=\$?
	cleanup_chroot_mounts "\$mnt"
	set_grsec chroot_caps \$chroot_caps > /dev/null
	return \$ret
}

unmount_partitions() {
	local mnt="\$1"

	# unmount the partitions
	umount \$(awk '{print \$2}' /proc/mounts | egrep "^\$mnt(/|\\\$)" | sort -r)
}

# figure out decent default swap size in mega bytes
find_swap_size() {
	local memtotal_kb=\$(awk '\$1 == "MemTotal:" {print \$2}' /proc/meminfo)
	# use 2 * avaiable ram or no more than 1/3 of smallest disk space
	local size=\$(( \$memtotal_kb * 2 / 1024 ))
	local disk= disksize=
	for disk in \$@; do
		local sysfsdev=\$(echo \${disk#/dev/} | sed 's:/:!:g')
		local sysfspath=/sys/block/\$sysfsdev/size
		# disksize = x * 512 / (1024 * 1024) = x / 2048
		# maxsize = \$disksize / 4 = x / (2048 * 4) = x / 8192
		maxsize=\$(awk '{ printf "%i", \$0 / 8192 }' \$sysfspath )
		if [ \$size -gt \$maxsize ]; then
			size=\$maxsize
		fi
	done
	if [ \$size -gt 4096 ]; then
		# dont ever use more than 4G
		size=4096
	elif [ \$size -lt 64 ]; then
		# dont bother create swap smaller than 64MB
		size=0
	fi
	echo \$size
}

has_mounted_part() {
	local p
	local sysfsdev=\$(echo \${1#/dev/} | sed 's:/:!:g')
	# parse /proc/mounts for mounted devices
	for p in \$(awk '\$1 ~ /^\/dev\// {gsub("/dev/", "", \$1); gsub("/", "!", \$1); print \$1}' \
			/proc/mounts); do
		[ "\$p" = "\$sysfsdev" ] && return 0
		[ -e /sys/block/\$sysfsdev/\$p ] && return 0
	done
	return 1
}

has_holders() {
	local i
	# check if device is used by any md devices
	for i in \$1/holders/* \$1/*/holders/*; do
		[ -e "\$i" ] && return 0
	done
	return 1
}

is_available_disk() {
	local dev=\$1
	local b=\$(echo \$p | sed 's:/:!:g')

	# check if its a "root" block device and not a partition
	[ -e /sys/block/\$b ] || return 1

	# check so it does not have mounted partitions
	has_mounted_part \$dev && return 1

	# check so its not part of an md setup
	if has_holders /sys/block/\$b; then
		[ -n "\$USE_RAID" ] && echo "Warning: \$dev is part of a running raid" >&2
		return 1
	fi

	# check so its not an md device
	[ -e /sys/block/\$b/md ] && return 1

	return 0
}

find_disks() {
	local p=
	# filter out ramdisks (major=1)
	for p in \$(awk '\$1 != 1 && \$1 ~ /[0-9]+/ {print \$4}' /proc/partitions); do
		is_available_disk \$p && echo -n " \$p"
	done
}

stop_all_raid() {
	local rd
	for rd in /dev/md*; do
		[ -b \$rd ] && mdadm --stop \$rd
	done
}

select_bootloader() {
	local bootloader=syslinux
	if [ "\$ARCH" = "ppc64le" ]; then
		bootloader=grub-ieee1275
	elif [ "\$ARCH" = "s390x" ]; then
		bootloader=s390-tools
	elif [ -n "\$USE_EFI" ]; then
		bootloader=grub-efi
	elif [ "\$BOOTLOADER" = "grub" ]; then
		bootloader=grub-bios
	fi
	echo "\$bootloader"
}

# install needed programs
init_progs() {
	local raidpkg= lvmpkg= fs= fstools= grub=
	[ -n "\$USE_RAID" ] && raidpkg="mdadm"
	[ -n "\$USE_LVM" ] && lvmpkg="lvm2"
	for fs in \$BOOTFS \$ROOTFS \$VARFS; do
		# we need load btrfs module early to avoid the error message:
		# 'failed to open /dev/btrfs-control'
		if ! grep -q -w "\$fs" /proc/filesystems; then
			modprobe \$fs
		fi

		case \$fs in
		xfs) fstools="\$fstools xfsprogs";;
		ext*) fstools="\$fstools e2fsprogs";;
		btrfs) fstools="\$fstools btrfs-progs";;
		vfat) fstools="\$fstools dosfstools";;
		esac
	done
	apk add --quiet sfdisk \$lvmpkg \$raidpkg \$fstools \$@
}

show_disk_info() {
	local disk= vendor= model= d= size= busid=
	for disk in \$@; do
		local dev=\${disk#/dev/}
		d=\$(echo \$dev | sed 's:/:!:g')
		vendor=\$(cat /sys/block/\$d/device/vendor 2>/dev/null)
		model=\$(cat /sys/block/\$d/device/model 2>/dev/null)
		busid=\$(readlink -f /sys/block/\$d/device 2>/dev/null)
		size=\$(awk '{gb = (\$1 * 512)/1000000000; printf "%.1f GB\n", gb}' /sys/block/\$d/size 2>/dev/null)
		if is_dasd \$dev eckd; then
			echo "  \$dev	(\$size \$vendor \${busid##*/})"
		else
			echo "  \$dev	(\$size \$vendor \$model)"
		fi
	done
}

confirm_erase() {
	local answer=
	local erasedisks="\$@"
	if [ "\$ERASE_DISKS" = "\$erasedisks" ]; then
		return 0
	fi
	echo "WARNING: The following disk(s) will be erased:"
	show_disk_info \$@
	echo -n "WARNING: Erase the above disk(s) and continue? [y/N]: "

	read answer
	case "\$answer" in
		y*|Y*) return 0;;
	esac
	return 1
}

# setup partitions on given disk dev in \$1.
# usage: setup_partitions <diskdev> size1,type1 [size2,type2 ...]
setup_partitions() {
	local diskdev="\$1" start=1M line=
	shift
	supported_part_label "\$DISKLABEL" || return 1

	# initialize MBR for syslinux only
	if [ "\$BOOTLOADER" = "syslinux" ] && [ -f "\$MBR" ]; then
		cat "\$MBR" > \$diskdev
	fi

	# create new partitions
	(
		for line in "\$@"; do
			case "\$line" in
			0M*) ;;
			*) echo "\$start,\$line"; start= ;;
			esac
		done
	) | sfdisk --quiet --label \$DISKLABEL \$diskdev

	# create device nodes if not exist
	mdev -s
}

# set up optional raid and create filesystem on boot device.
setup_boot_dev() {
	local disks="\$@" disk= bootdev= mkfs_args=
	[ "\$BOOTFS" != "vfat" ] && mkfs_args="-q"
	local part=\$(for disk in \$disks; do find_partitions "\$disk" "boot"; done)
	set -- \$part
	bootdev=\$1
	[ -z "\$bootdev" ] && return 1

	if [ "\$ARCH" = "ppc64le" ]; then
		# Change bootable partition to PReP partition
		for disk in \$disks; do
			echo ',,,*' | sfdisk --quiet \$disk -N1
			echo ',,,-' | sfdisk --quiet \$disk -N2
			mdev -s
		done
	fi

	echo "Creating file systems..."
	if [ -n "\$USE_RAID" ]; then
		local missing=
		local num=\$#
		if [ \$# -eq 1 ]; then
			missing="missing"
			num=2
		fi
		# we only use raid level 1 for boot devices
		mdadm --create /dev/md0 --level=1 --raid-devices=\$num \
			--metadata=0.90 --quiet --run \$@ \$missing || return 1
		bootdev=/dev/md0
	fi
	case "\$BOOTFS" in
	btrfs) mkfs_args="";;
	ext4) mkfs_args="\$mkfs_args -O ^64bit";; # pv-grub does not support 64bit
	esac
	mkfs.\$BOOTFS \$MKFS_OPTS_BOOT \$mkfs_args \$bootdev
	BOOT_DEV="\$bootdev"
}

# \$1 = index
# \$2 = partition type
# \$3... = disk devices
find_nth_non_boot_parts() {
	local idx=\$1 id=\$2 disk= type=bootable
	shift 2
	local disks="\$@"
	[ -n "\$USE_EFI" ] && type=\$(partition_id esp)
	for disk in \$disks; do
		if is_dasd \$disk eckd; then
			fdasd -p \$disk | grep "Linux \$id" | awk '{print \$1}' | tail -n 1
		else
			sfdisk -d \$disk | grep -v \$type \
				| awk "/(Id|type)=\$id/ { i++; if (i==\$idx) print \\\$1 }"
		fi
	done
}

setup_non_boot_raid_dev() {
	local md_dev=\$1
	local idx=\${md_dev#/dev/md}
	[ -z "\$md_dev" ] && return 0
	if [ "\$ARCH" = "ppc64le" ]; then
		# increment idx as PReP partition is
		# the bootable partition in ppc64le
		idx=\$((idx+1))
	fi
	shift
	local level=1
	local missing=
	local pid=\$(partition_id raid)
	local raid_parts=\$(find_nth_non_boot_parts \$idx \$pid \$@)
	set -- \$raid_parts
	# how many disks do we have?
	case \$# in
		0) echo "No Raid partitions found" >&2; return 1;;
		1) level=1; missing="missing"; num=2;;
		2) level=1; missing=  ; num=2;;
		*) level=5; missing=  ; num=\$#;;
	esac
	mdadm --create \$md_dev --level=\$level --raid-devices=\$num \
		--quiet --run \$@ \$missing || return 1
}

# setup device for lvm, create raid array if needed
setup_lvm_volume_group() {
	local vgname="\$1"
	shift
	local lvmdev=

	if [ -n "\$USE_RAID" ]; then
		setup_non_boot_raid_dev /dev/md1 \$@ || return 1
		lvmdev=/dev/md1
	else
		lvmdev=\$(find_partitions "\$1" "lvm")
	fi

	# be quiet on success
	local errmsg=\$(dd if=/dev/zero of=\$lvmdev bs=1k count=1 2>&1) \
		|| echo "\$errmsg"
	pvcreate --quiet \$lvmdev \
		&& vgcreate --quiet \$vgname \$lvmdev >/dev/null
}

# set up swap on given device(s)
setup_swap_dev() {
	local swap_dev=
	sed -i -e '/swap/d' /etc/fstab
	SWAP_DEVICES=
	for swap_dev in "\$@"; do
		mkswap \$swap_dev >/dev/null
		echo -e "\$(uuid_or_device \$swap_dev)\tswap\t\tswap\tdefaults 0 0" >> /etc/fstab
		SWAP_DEVICES="\$SWAP_DEVICES \$swap_dev"
	done
	swapon -a
	rc-update --quiet add swap boot
}

# setup and enable swap on given volumegroup if needed
setup_lvm_swap() {
	local vgname="\$1"
	local swapname=lv_swap
	if [ -z "\$SWAP_SIZE" ] || [ "\$SWAP_SIZE" -eq 0 ]; then
		return
	fi
	lvcreate --quiet -n \$swapname -L \${SWAP_SIZE}MB \$vgname
	setup_swap_dev /dev/\$vgname/\$swapname
}

# if /var is mounted, move out data and umount it
reset_var() {
	[ -z "\$(find_mount_dev /var)" ] && return 0
	mkdir /.var
	mv /var/* /.var/ 2>/dev/null
	umount /var && 	rm -rf /var && mv /.var /var && rm -rf /var/lost+found
}

# set up /var on given device
setup_var() {
	local var_dev="\$1"
	local varfs=\${VARFS}
	echo "Creating file systems..."
	mkfs.\$varfs \$MKFS_OPTS_VAR \$var_dev >/dev/null || return 1
	sed -i -e '/[[:space:]]\/var[[:space:]]/d' /etc/fstab
	echo -e "\$(uuid_or_device \${var_dev})\t/var\t\t\${varfs}\tdefaults 1 2" >> /etc/fstab

	mv /var /.var
	mkdir /var
	mount /var
	mv /.var/* /var/
	rmdir /.var

	service syslog --quiet condrestart
	setup_mdadm_conf
}

setup_mdadm_conf() {
	local mods= mod=
	if [ -n "\$USE_RAID" ]; then
		mdadm --detail --scan > /etc/mdadm.conf
		rc-update --quiet add mdadm-raid boot
		mods=\$(awk '/^raid/ {print \$1}' /proc/modules)
		for mod in \$mods; do
			if ! grep -q "^\$mod" /etc/modules; then
				echo \$mod >> /etc/modules
			fi
		done
	fi
}

data_only_disk_install_lvm() {
	local diskdev=
	local vgname=vg0
	local var_dev=/dev/\$vgname/lv_var
	local lvm_part_type=\$(partition_id lvm)
	local size=
	unset BOOTLOADER

	init_progs || return 1
	confirm_erase \$@ || return 1

	if [ "\$USE_RAID" ]; then
		lvm_part_type=\$(partition_id raid)
		stop_all_raid
	fi

	for diskdev in "\$@"; do
		setup_partitions \$diskdev "\${size}\${size:+M},\$lvm_part_type" || return 1
	done

	setup_lvm_volume_group \$vgname \$@ || return 1
	setup_lvm_swap \$vgname
	lvcreate --quiet -n \${var_dev##*/} -l 100%FREE \$vgname
	setup_mdadm_conf
	rc-update add lvm boot
	setup_var \$var_dev
}

data_only_disk_install() {
	local diskdev=
	local var_dev=
	local var_part_type=\$(partition_id linux)
	local swap_part_type=\$(partition_id swap)
	local size=
	local swap_dev= var_dev=
	unset BOOTLOADER

	init_progs || return 1
	confirm_erase \$@ || return 1

	if [ "\$USE_RAID" ]; then
		var_part_type=\$(partition_id raid)
		swap_part_type=\$(partition_id raid)
		stop_all_raid
	fi

	for diskdev in "\$@"; do
		setup_partitions \$diskdev \
			"\${SWAP_SIZE}M,\$swap_part_type" \
			"\${size}\${size:+M},\$var_part_type" || return 1
	done

	if [ "\$USE_RAID" ]; then
		if [ \$SWAP_SIZE -gt 0 ]; then
			swap_dev=/dev/md1
			var_dev=/dev/md2
		else
			swap_dev=
			var_dev=/dev/md1
		fi
		setup_non_boot_raid_dev "\$swap_dev" \$@ || return 1
		setup_non_boot_raid_dev "\$var_dev" \$@ || return 1
	else
		swap_dev=\$(find_nth_non_boot_parts 1 "\$swap_part_type" \$@)
		var_dev=\$(find_nth_non_boot_parts 1 "\$var_part_type" \$@)
	fi
	[ \$SWAP_SIZE -gt 0 ] && setup_swap_dev \$swap_dev
	setup_var \$var_dev
}

# setup
setup_root() {
	local root_dev="\$1" boot_dev="\$2"
	shift 2
	local disks="\$@" mkfs_args="-q"
	[ "\$ROOTFS" = "btrfs" ] && mkfs_args=""
	mkfs.\$ROOTFS \$MKFS_OPTS_ROOT \$mkfs_args "\$root_dev"
	mkdir -p "\$SYSROOT"
	mount -t \$ROOTFS \$root_dev "\$SYSROOT" || return 1
	if [ -n "\$boot_dev" ] && [ -z "\$USE_EFI" ]; then
		mkdir -p "\$SYSROOT"/boot
		mount -t \$BOOTFS \$boot_dev "\$SYSROOT"/boot || return 1
	fi
	if [ -n "\$boot_dev" ] && [ -n "\$USE_EFI" ]; then
		mkdir -p "\$SYSROOT"/boot/efi
		mount -t \$BOOTFS \$boot_dev "\$SYSROOT"/boot/efi || return 1
	fi
	
	for ovl in \$(find / -name *.apkovl.tar.gz) ; do
		tar -xzf \$ovl -C "\$SYSROOT"/
	done

	setup_mdadm_conf
	install_mounted_root "\$SYSROOT" "\$disks" || return 1
	unmount_partitions "\$SYSROOT"
	swapoff -a

	echo ""
	echo "Installation is complete. Please reboot."
}

native_disk_install_lvm() {
	local diskdev= vgname=vg0
	local lvm_part_type=\$(partition_id lvm)
	local boot_part_type=\$(partition_id linux)
	local boot_size=\${BOOT_SIZE:-100}
	local lvm_size=
	local root_dev=/dev/\$vgname/lv_root

	init_progs \$(select_bootloader) || return 1
	confirm_erase \$@ || return 1

	if [ -n "\$USE_RAID" ]; then
		boot_part_type=\$(partition_id raid)
		lvm_part_type=\$(partition_id raid)
		stop_all_raid
	fi

	if [ -n "\$USE_EFI" ]; then
		boot_part_type=\$(partition_id esp)
	fi

	for diskdev in "\$@"; do
		if is_dasd \$diskdev eckd; then
			root_part_type="lvm"
			setup_partitions_eckd \$diskdev \
				\$boot_size 0 \$root_part_type || return 1
		else
			setup_partitions \$diskdev \
				"\${boot_size}M,\$boot_part_type,*" \
				"\${lvm_size}\${lvm_size:+M},\$lvm_part_type" || return 1
		fi
	done

	# will find BOOT_DEV for us
	setup_boot_dev \$@

	setup_lvm_volume_group \$vgname \$@ || return 1
	setup_lvm_swap \$vgname
	lvcreate --quiet -n \${root_dev##*/} -l 100%FREE \$vgname
	rc-update add lvm boot
	setup_root \$root_dev \$BOOT_DEV
}

native_disk_install() {
	local prep_part_type=\$(partition_id prep)
	local root_part_type=\$(partition_id linux)
	local swap_part_type=\$(partition_id swap)
	local boot_part_type=\$(partition_id linux)
	local prep_size=8
	local boot_size=\${BOOT_SIZE:-100}
	local swap_size=\${SWAP_SIZE}
	local root_size=
	local root_dev= boot_dev= swap_dev=
	init_progs \$(select_bootloader) || return 1
	confirm_erase \$@ || return 1

	if [ -n "\$USE_RAID" ]; then
		boot_part_type=\$(partition_id raid)
		root_part_type=\$(partition_id raid)
		swap_part_type=\$(partition_id raid)
		stop_all_raid
	fi

	if [ -n "\$USE_EFI" ]; then
		boot_part_type=\$(partition_id esp)
	fi

	for diskdev in "\$@"; do
		if [ "\$ARCH" = "ppc64le" ]; then
			setup_partitions \$diskdev \
				"\${prep_size}M,\$prep_part_type" \
				"\${boot_size}M,\$boot_part_type,*" \
				"\${swap_size}M,\$swap_part_type" \
				"\${root_size}\${root_size:+M},\$root_part_type" \
				|| return 1
		elif is_dasd \$diskdev eckd; then
			swap_part_type="swap"
			root_part_type="native"
			setup_partitions_eckd \$diskdev \
				\$boot_size \$swap_size \$root_part_type || return 1
		else
			setup_partitions \$diskdev \
				"\${boot_size}M,\$boot_part_type,*" \
				"\${swap_size}M,\$swap_part_type" \
				"\${root_size}\${root_size:+M},\$root_part_type" \
				|| return 1
		fi
	done

	# will find BOOT_DEV for us
	setup_boot_dev \$@

	if [ "\$USE_RAID" ]; then
		if [ \$SWAP_SIZE -gt 0 ]; then
			swap_dev=/dev/md1
			root_dev=/dev/md2
		else
			swap_dev=
			root_dev=/dev/md1
		fi
		setup_non_boot_raid_dev "\$swap_dev" \$@ || return 1
		setup_non_boot_raid_dev "\$root_dev" \$@ || return 1
	else
		swap_dev=\$(find_nth_non_boot_parts 1 "\$swap_part_type" \$@)
		local index=
		case "\$ARCH" in
			# use the second non botable partition on ppc64le,
			# as PReP partition is the bootable partition
			ppc64le) index=2;;
			*) index=1;;
		esac
		root_dev=\$(find_nth_non_boot_parts \$index "\$root_part_type" \$@)
	fi

	[ \$SWAP_SIZE -gt 0 ] && setup_swap_dev \$swap_dev
	setup_root \$root_dev \$BOOT_DEV \$@
}

diskselect_help() {
	cat <<-__EOF__

		The disk you select can be used for a traditional disk install or for a
		data-only install.

		The disk will be erased.

		Enter 'none' if you want to run diskless.

	__EOF__
}

diskmode_help() {
	cat <<-__EOF__

		You can select between 'sys', 'data', 'lvm', 'lvmsys' or 'lvmdata'.

		sys:
		  This mode is a traditional disk install. The following partitions will be
		  created on the disk: /boot, / (filesystem root) and swap.

		  This mode may be used for development boxes, desktops, virtual servers, etc.

		data:
		  This mode uses your disk(s) for data storage, not for the operating system.
		  The system itself will run from tmpfs (RAM).

		  Use this mode if you only want to use the disk(s) for a mailspool, databases,
		  logs, etc.

		lvm:
		  Enable logical volume manager and ask again for 'sys' or 'data'.

		lvmsys:
		  Same as 'sys' but use logical volume manager for partitioning.

		lvmdata:
		  Same as 'data' but use logical volume manager for partitioning.

	__EOF__
}

# ask for a root or data disk
# returns answer in global variable \$answer
ask_disk() {
	local prompt="\$1"
	local help_func="\$2"
	local i=
	shift 2
	answer=
	local default_disk=\${DEFAULT_DISK:-\$1}

	while ! all_in_list "\$answer" \$@ "none" "abort"; do
		echo "Available disks are:"
		show_disk_info "\$@"
		echon "\$prompt [\$default_disk] "
		default_read answer \$default_disk
		case "\$answer" in
			'abort') exit 0;;
			'none') return 0;;
			'?') \$help_func;;
			*) for i in \$answer; do
				if ! [ -b "/dev/\$i" ]; then
					echo "/dev/\$i is not a block device" >&2
					answer=
				fi
			done;;
		esac
	done
}

usage() {
	cat <<-__EOF__
		usage: setup-disk [-hLqrv] [-k kernelflavor] [-m MODE] [-o apkovl] [-s SWAPSIZE]
		                  [MOUNTPOINT | DISKDEV...]

		Install alpine on harddisk.

		If MOUNTPOINT is specified, then do a traditional disk install with MOUNTPOINT
		as root.

		If DISKDEV is specified, then use the specified disk(s) without asking. If
		multiple disks are specified then set them up in a RAID array. If there are
		mode than 2 disks, then use raid level 5 instead of raid level 1.

		options:
		 -h  Show this help
		 -m  Use disk for MODE without asking, where MODE is either 'data' or 'sys'
		 -o  Restore system from given apkovl file
		 -k  Use kernelflavor instead of \$KERNEL_FLAVOR
		 -L  Use LVM to manage partitions
		 -q  Exit quietly if no disks are found
		 -r  Enable software raid1 with single disk
		 -s  Use SWAPSIZE MB instead of autodetecting swap size (Use 0 to disable swap)
		 -v  Be more verbose about what is happening

		If BOOTLOADER is specified, the specified bootloader will be used.
		If no bootloader is specified, the default bootloader is syslinux(extlinux)
		except when EFI is detected or explicitly set by USE_EFI which will select grub.
		Supported bootloaders are: grub, syslinux

		If DISKLABEL is specified, the specified partition label will be used.
		if no partition label is specified, the default label will be dos
		except when EFI is detected or explicitly set by USE_EFI which will select gpt.
		Supported partition labels are: dos, gpt

		If BOOTFS, ROOTFS, VARFS are specified, then format a partition with specified
		filesystem. If not specified, the default filesystem is ext4.
		Supported filesystems for
		  boot: ext2, ext3, ext4, btrfs, xfs, vfat(EFI)
		  root: ext2, ext3, ext4, btrfs, xfs
		   var: ext2, ext3, ext4, btrfs, xfs
	__EOF__
	exit 1
}

kver=\$(uname -r)
case \$kver in
	*-rc[0-9]*) KERNEL_FLAVOR=vanilla;;
	*-[a-z]*) KERNEL_FLAVOR=\${kver##*-};;
	*) KERNEL_FLAVOR=vanilla;;
esac

DISK_MODE=
USE_LVM=
# Parse args
while getopts "hk:Lm:o:qrs:v" opt; do
	case \$opt in
		m) DISK_MODE="\$OPTARG";;
		k) KERNEL_FLAVOR="\$OPTARG";;
		L) USE_LVM="_lvm";;
		o) APKOVL="\$OPTARG";;
		q) QUIET=1;;
		r) USE_RAID=1;;
		s) SWAP_SIZE="\$OPTARG";;
		v) VERBOSE=1;;
		*) usage;;
	esac
done
shift \$(( \$OPTIND - 1))

if [ -d "\$1" ]; then
	# install to given mounted root
	apk add --quiet syslinux
	install_mounted_root "\${1%/}" \
		&& echo "You might need fix the MBR to be able to boot" >&2
	exit \$?
fi

reset_var
swapoff -a

# stop all volume groups in use
vgchange --ignorelockingfailure -a n >/dev/null 2>&1

if [ -n "\$USE_RAID" ]; then
	stop_all_raid
fi

check_dasd

disks=\$(find_disks)
diskdevs=

# no disks so lets exit quietly.
if [ -z "\$disks" ]; then
	[ -z "\$QUIET" ] && echo "No disks found." >&2
	exit 0
fi

if [ \$# -gt 0 ]; then
	# check that they are
	for i in "\$@"; do
		j=\$(readlink -f "\$i" | sed 's:^/dev/::; s:/:!:g')
		if ! [ -e "/sys/block/\$j/device" ]; then
			die "\$i is not a suitable for partitioning"
		fi
		diskdevs="\$diskdevs /dev/\${j//!//}"
	done
else
	ask_disk "Which disk(s) would you like to use? (or '?' for help or 'none')" \
		diskselect_help \$disks
	if [ "\$answer" != none ]; then
		for i in \$answer; do
			diskdevs="\$diskdevs /dev/\$i"
		done
	else
		DISK_MODE="none"
	fi
fi

if [ -n "\$diskdevs" ] && [ -z "\$DISK_MODE" ]; then
	answer=
	disk_is_or_disks_are="disk is"
	it_them="it"
	set -- \$diskdevs
	if [ \$# -gt 1 ]; then
		disk_is_or_disks_are="disks are"
		it_them="them"
	fi

	while true; do
		echo "The following \$disk_is_or_disks_are selected\${USE_LVM:+ (with LVM)}:"
		show_disk_info \$diskdevs
		_lvm=\${USE_LVM:-", 'lvm'"}
		echon "How would you like to use \$it_them? ('sys', 'data'\${_lvm#_lvm} or '?' for help) [?] "
		default_read answer '?'
		case "\$answer" in
		'?') diskmode_help;;
		sys|data) break;;
		lvm) USE_LVM="_lvm" ;;
		nolvm) USE_LVM="";;
		lvmsys|lvmdata)
			answer=\${answer#lvm}
			USE_LVM="_lvm"
			break
			;;
		esac
	done
	DISK_MODE="\$answer"
fi

if [ -z "\$SWAP_SIZE" ]; then
	SWAP_SIZE=\$(find_swap_size \$diskdevs)
fi

set -- \$diskdevs
if is_dasd \$1 eckd; then
	DISKLABEL=eckd
fi
if [ \$# -gt 1 ]; then
	USE_RAID=1
fi

if is_efi || [ -n "\$USE_EFI" ]; then
	USE_EFI=1
	DISKLABEL=gpt
	BOOTLOADER=grub
	BOOT_SIZE=512
	BOOTFS=vfat
fi

case "\$ARCH" in
	ppc64le) BOOTLOADER=grub;;
	s390x) BOOTLOADER=zipl;;
esac

dmesg -n1

# native disk install
case "\$DISK_MODE" in
sys) native_disk_install\$USE_LVM \$diskdevs;;
data) data_only_disk_install\$USE_LVM \$diskdevs;;
none) exit 0;;
*) die "Not a valid install mode: \$DISK_MODE" ;;
esac

RC=\$?
echo "\$DISK_MODE" > /tmp/alpine-install-diskmode.out
exit \$RC
EOF

overlay_repack

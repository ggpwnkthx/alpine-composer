profile_EXAMPLE() {
	# Include build profiles
	# These will be compiled in order
	profile_abstract	# Abstracted base profile for all supported architectures.
	
	# Metadata
	title="EXAMPLE Linux"
	desc="EXAMPLE Linux, just enough to get you started."
	profile_abbrev="EXAMPLE"
	
	# Add APKs
	apks="$apks apache2"
	
	# Process overlays
	apkovl="$apkovl genapkovl-EXAMPLE.sh"
	
	# Overlay hostname (this is passed to the apkovl scripts as $1)
	hostname="EXAMPLE"
	
	# GRUB (For booting with EFI)
	grub_mod="$grub_mod "
	
	# SYSLINUX (For booting with Legacy BIOS)
	syslinux_serial="$syslinux_serial "
	
	# Kernel 
	kernel_addons="$kernel_addons "
	kernel_flavors="$kernel_flavors "
	kernel_cmdline="$kernel_cmdline "
	
	# InitFS
	initfs_features="$initfs_features "
	initfs_cmdline="$initfs_cmdline "
	
	# Outputs
	image_ext="iso"
	output_format="iso"
}
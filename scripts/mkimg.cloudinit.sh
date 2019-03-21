profile_cloudinit() {
	title="Cloud-Init"
	desc="Alpine with cloud-init.
		Just enough to get you started.
		Network connection is required."
	#profile_abstract
	profile_abbrev="ci"
	apks="$apks cloud-init"
	apkovl="$apkovl genapkovl-cloudinit.sh"
	kernel_cmdline="$kernel_cmdline ds=nocloud-net"
	hostname="cloudinit"
}
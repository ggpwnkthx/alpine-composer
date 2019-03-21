profile_aldoqe() {
	# Metadata
	title="Aldoqe"
	desc="Alpine docker and qemu host.
		Just enough to get you started.
		Network connection is required."
	profile_abbrev="aldoqe"
	# Include build profiles
	profile_abstract
	#profile_cloudinit
	profile_fabric
	# Add APKs
	apks="$apks ceph dbus docker docker-compose libvirt libvirt-daemon ncurses polkit qemu-system-x86_64 qemu-img util-linux"
	# Process overlays
	apkovl="$apkovl genapkovl-aldoqe.sh"
	# Temporary hostname
	hostname="aldoqe"
}
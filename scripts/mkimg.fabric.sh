profile_fabric() {
	title="Cloud-Init Fabric Stitching"
	desc="Alpine w/ cloudinit and fabric stitching.
		Just enough to get you started.
		Network connection is required."
	profile_cloudinit
	profile_abbrev="acifs"
	apks="$apks bonding bridge py3-netifaces"
	apkovl="$apkovl genapkovl-fabric.sh"
	hostname="fabric"
}
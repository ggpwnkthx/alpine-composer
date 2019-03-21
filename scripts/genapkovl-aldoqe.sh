#!/bin/sh -e

source $(dirname $0)/shared_functions.sh

docker_cache() {
	if [ ! -z "$(command -v docker)" ] ; then
		for image in $@ ; do
			if [ ! -f /var/lib/docker/tar/$image.tar ] ; then
				docker pull $image
				if [ ! -d /var/lib/docker/tar ] ; then
					mkdir -p /var/lib/docker/tar
				fi
				if [ ! -d "$tmp"/var/lib/docker/tar ] ; then
					mkdir -p "$tmp"/var/lib/docker/tar
				fi
				docker save -o /var/lib/docker/tar/$image.tar $image
				cp /var/lib/docker/tar/$image.tar "$tmp"/var/lib/docker/tar/$image.tar
			fi
		done
	fi
}

# Add init.d scripts
mkdir -p "$tmp"/etc/init.d
# Load KVM modules appropriate for the system
makefile root:root 0755 "$tmp"/etc/init.d/modules-kvm <<EOF
#!/sbin/openrc-run
depend() {
	after modules
}
start() {
	if [ -z "\$(lsmod | grep 'kvm ')" ] ; then
		modprobe kvm
	fi
	if [ ! -z "\$(grep vmx /proc/cpuinfo)" ] ; then
		if [ -z "\$(lsmod | grep 'kvm_intel')" ] ; then
			modprobe kvm_intel
		fi
	fi
	if [ ! -z "\$(grep svm /proc/cpuinfo)" ] ; then
		if [ -z "\$(lsmod | grep 'kvm_amd')" ] ; then
			modprobe kvm_amd
		fi
	fi
	#modprobe tun
}
stop() {
	if [ ! -z "\$(lsmod | grep 'kvm_amd')" ] ; then
		modprobe -r kvm_amd
	fi
	if [ ! -z "\$(lsmod | grep 'kvm_intel')" ] ; then
		modprobe -r kvm_intel
	fi
	if [ ! -z "\$(lsmod | grep 'kvm ')" ] ; then
		modprobe -r kvm
	fi
	#if [ ! -z "\$(lsmod | grep 'tun ')" ] ; then
	#	modprobe -r tun
	#fi
}
EOF
# Make sure all the services needed for Aldoqe are running
makefile root:root 0755 "$tmp"/etc/init.d/aldoqe-assurance <<EOF
#!/sbin/openrc-run
depend() {
	after fabric-assurance dbus docker libvirtd
}
start() {
	ebegin "Aldoqe - Service Assurance"
	i=0
	while [ true ] ; do
		docker ps > /dev/null 2> /dev/null
		ret=\$?
		if [ \$ret -eq 0 ] ; then
			break
		fi
		if [ \$i -gt 20 ] ; then
			break
		fi
		i=\$((\$i + 1))
		sleep 1
	done
	eend \$ret
}
EOF
# Load in any cached docker images to minimize required RAM in live mode
makefile root:root 0755 "$tmp"/etc/init.d/docker-import-images <<EOF
#!/sbin/openrc-run
depend() {
	after docker
}
start() {
	ebegin "Loading cached docker images"
	if [ -d /var/lib/docker/tar ] ; then
		for image in \$(ls /var/lib/docker/tar) ; do
			docker load -i /var/lib/docker/tar/\$image
		done
	fi
	eend \$ret
}
EOF
# Use YAML to compose docker
mkdir -p "$tmp"/etc/docker/compose
makefile root:root 0755 "$tmp"/etc/init.d/docker-compose <<EOF
#!/sbin/openrc-run

INSTANCE_NAME="\${SVCNAME#*.}"
DOCKER_COMPOSE_BINARY="/usr/bin/docker-compose"
DOCKER_COMPOSE_CONFIG_FILE="/etc/docker/compose/\${INSTANCE_NAME}.yaml"

description="Runs docker-compose instances."

dirname="\$(dirname "\$(realpath "\${DOCKER_COMPOSE_CONFIG_FILE}")")"
basename="\$(basename "\$(realpath "\${DOCKER_COMPOSE_CONFIG_FILE}")")"

depend() {
	after aldoqe-assurance docker-load-images
}

checkconfig() {
	if ! [ -f "\${DOCKER_COMPOSE_CONFIG_FILE}" ]
	then
		eerror "You need a docker-compose configuration file in the directory"
		eerror "/etc/docker/compose. The configuration file \${DOCKER_COMPOSE_CONFIG_FILE}"
		eerror "was not found."
		return 1
	fi
}

start() {
	checkconfig || return 1

	ebegin "Starting ${SVCNAME}"
	cd "\$dirname" || return 1
	"\${DOCKER_COMPOSE_BINARY}" --project-name="\${INSTANCE_NAME}" --file "\$basename" up -d
	eend \$?
}

stop() {
	if [ "\${RC_CMD}" = "restart" ]
	then
		checkconfig || return 1
	fi

	ebegin "Stopping \${SVCNAME}"
	cd "\$dirname" || return 1
	"\${DOCKER_COMPOSE_BINARY}" --project-name="\${INSTANCE_NAME}" --file "\$basename" down
	eend \$?
}
EOF
# For each service, a symbolic link in etc/init.d has to be created, 
# which links to /etc/init.d/docker-compose, named docker-compose.$SERVICE_NAME, 
# where $SERVICE_NAME is the docker-compose YAML configuration file, omitting the extension .yaml.
# EXAMPLE: 
#ln -sf /etc/init.d/docker-compose "$tmp"/etc/init.d/docker-compose.portainer
#makefile root:root 0755 "$tmp"/etc/docker/compose/portainer.yaml <<EOF
#version: '3.7'
#services:
#  portainer:
#    image: portainer/portainer
#    restart: always
#    volumes:
#      - /var/run/docker.sock:/var/run/docker.sock
#      - portainer_data:/data portainer/portainer
#    ports:
#      - "9000:9000"
#volumes:
#  portainer_data:
#EOF

# To minimize the RAM capacity requirements when running in live mode, pre-download the docker images
# EXAMPLE:
#docker_cache mongo:3.2 rabbitmq:3.6.6-management memcached

# Add apks to world
apk_add ceph dbus docker docker-compose libvirt libvirt-daemon ncurses polkit qemu-system-x86_64 qemu-img util-linux

# Polkit
mkdir -p "$tmp"/etc/polkit-1/localauthority/50-local.d
makefile root:root 0644 "$tmp"/etc/polkit-1/localauthority/50-local.d/50-libvirt-ssh-remote-access-policy.pkla <<EOF
[Remote libvirt SSH access]
Identity=unix-group:libvirt
Action=org.libvirt.unix.manage
ResultAny=yes
ResultInactive=yes
ResultActive=yes
EOF

rc_add modules-kvm boot

rc_add libvirtd default
rc_add dbus default
rc_add docker default
rc_add aldoqe-assurance default
rc_add docker-import-images default

overlay_repack
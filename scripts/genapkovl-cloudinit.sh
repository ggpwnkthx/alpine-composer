#!/bin/sh -e

source $(dirname $0)/shared_functions.sh

# Add init.d scripts
mkdir -p "$tmp"/etc/init.d
makefile root:root 0755 "$tmp"/etc/init.d/cloud-dhcp-all <<EOF
#!/sbin/openrc-run
depend() {
	before cloud-init-local
}
start() {
	CLOUDCFG="/etc/cloud/cloud.cfg.d/networking.cfg"
	if [ ! -f \$CLOUDCFG ] ; then
		ebegin "Setting all interfaces to DHCP"
		
		echo "network:" > \$CLOUDCFG
		echo "  version: 2" >> \$CLOUDCFG
		echo "  ethernets:" >> \$CLOUDCFG
	
		INTERFACES="\$(ip link show | awk -F': ' '{print \$2}' | grep -v lo | grep -v docker | grep -v virbr | xargs)"
		for i in \$INTERFACES; do
			if [ -z "\$(cat \$CLOUDCFG | grep \$i)" ] ; then
				sed -i -e "/^  ethernets:/a\ \ \ \ \$i:" \$CLOUDCFG
				sed -i -e "/^    \$i:/a\ \ \ \ \ \ dhcp4: true" \$CLOUDCFG
			fi
		done
		
		eend 0
	fi
}
stop() {
	echo
}
EOF
installer_append <<EOF
if [ -f /etc/cloud/cloud.cfg.d/networking.cfg ] ; then
	rm /etc/cloud/cloud.cfg.d/networking.cfg
fi
EOF
makefile root:root 0755 "$tmp"/etc/init.d/cloud-gen <<EOF
#!/sbin/openrc-run
depend() {
	after modules
	before cloud-init-local
}
start() {
	if [ ! -f /etc/cloud/cloud.cfg.d/seedfile.cfg ] ; then
		ebegin "Checking all interfaces for DHCP cloudinit data"
		
		INTERFACES="\$(ip link show | awk -F': ' '{print \$2}' | grep -v lo | grep -v docker | grep -v virbr | xargs)"
		for i in \$INTERFACES; do
			ip link set \$i up
			opt214=\$(/usr/bin/dhcp-option-query \$i 214)
			echo \$i : \$opt214
			ip link set \$i down
			if [ ! -z "\$opt214" ] ; then
				echo "datasource:" > /etc/cloud/cloud.cfg.d/seedfile.cfg
				echo "  NoCloud:" >> /etc/cloud/cloud.cfg.d/seedfile.cfg
				echo "    seedfrom: \$opt214" >> /etc/cloud/cloud.cfg.d/seedfile.cfg
			fi
		done
		
		eend 0
	fi
}
stop() {
	echo
}
EOF
installer_append <<EOF
if [ -f /etc/cloud/cloud.cfg.d/seedfile.cfg ] ; then
	rm /etc/cloud/cloud.cfg.d/seedfile.cfg
fi
EOF

makefile root:root 0755 "$tmp"/etc/init.d/modules-infiniband <<EOF
#!/sbin/openrc-run

mods="mlx4_core mlx4_ib rdma_ucm ib_umad ib_uverbs ib_ipoib"

depend() {
	before modules
}
start() {
	if [ ! -z "/usr/sbin/lspci" ] ; then
		if [ ! -z "\$(lspci | grep 0c06)" ] ; then
			ebegin "Enabling infiniband modules"
			for m in \$mods ; do
				if [ -z "\$(lsmod | grep \$m)" ] ; then
					modprobe \$m
				fi
			done
			eend 0
		fi
	fi
}
stop() {
	for m in \$mods ; do
		if [ ! -z "\$(lsmod | grep \$m)" ] ; then
			ebegin "Disabling infiniband modules"
			modprobe -r \$m
			eend 0
		fi
	done
}
EOF

# Add apks
apk_add cloud-init

# cloud-init helper scripts
mkdir -p "$tmp"/usr/bin
makefile root:root 0755 "$tmp"/usr/bin/dhcp-option-query <<EOF
#!/bin/sh
tmp=\$(mktemp)
udhcpc -i \$1 -s /usr/bin/dump-env-vars -t 1 -T 2 -A 5 -n -O \$2 -V aldoqe -R >>\$tmp 2>/dev/null
source "\$tmp"
case \$2 in
	1) echo \$subnet ;;
	3) echo \$router ;;
	6) echo \$dns ;;
	9) echo \$lprsrv ;;
	12) echo \$hostname ;;
	13) echo \$bootsize ;;
	15) echo \$domain ;;
	16) echo \$swapsrv ;;
	17) echo \$rootpath ;;
	23) echo \$ipttl ;;
	26) echo \$mtu ;;
	28) echo \$broadcast ;;
	33) echo \$routes ;;
	40) echo \$nisdomain ;;
	41) echo \$nissrv ;;
	42) echo \$ntpsrv ;;
	44) echo \$wins ;;
	51) echo \$lease ;;
	54) echo \$serverid ;;
	56) echo \$message ;;
	66) echo \$tftp ;;
	67) echo \$bootfile ;;
	119) echo \$search ;;
	120) echo \$sipsrv ;;
	121) echo \$staticroutes ;;
	132) echo \$vlanid ;;
	133) echo \$vlanpriority ;;
	209) echo \$pxeconffile ;;
	210) echo \$pxepathprefix ;;
	211) echo \$reboottime ;;
	212) echo \$ip6rd ;;
	249) echo \$msstaticroutes ;;
	252) echo \$wpad ;;
	*)
		eval "opt=\\\$opt\$2"
		if [ ! -z "\$opt" ] ; then
			# UTF-8 String Test
			str=\$(echo \$opt | awk '{print toupper(\$0)}' | sed 's/\([0-9A-F]\{2\}\)/\\\\\\\\\\\\x\1/gI' | xargs printf)
			if [ "\$str" == "\$(echo \$str | iconv -f utf8 -t utf-8 -c)" ] ; then
				echo \$str
			else
				if [ \$(( \$(expr length \$opt) % 8 )) == 0 ] ; then
					hex=\$(echo \$opt | fold -w8)
					for oct in \$hex ; do
						ip=""
						for i in \$(echo \$oct | fold -w2) ; do
							ip="\$ip.\$(printf '%d\n' 0x\$i)"
						done
						IP_ARRAY="\$IP_ARRAY \${ip:1}"
					done
					echo \${IP_ARRAY:1}
				fi
			fi
		fi
		;;
esac
rm -rf \$tmp
EOF
makefile root:root 0755 "$tmp"/usr/bin/dump-env-vars <<EOF
#!/bin/sh
cat /proc/self/environ | \
	sed -e ':a;N;$!ba;s/\([^=]\+\)=\([^\x00]*\)\x00/\1\n/g' | \
	sed -e 's/=\([^" >][^ >]*\)/="\1/g' | \
	sed 's/$/"\n/' 
EOF

# Make sure the interface file is removed when installing to disk
installer_append <<EOF
if [ -f /etc/network/interfaces ] ; then
	rm /etc/network/interfaces
fi
EOF

rc_add modules-infiniband boot

rc_add cloud-gen default
rc_add cloud-dhcp-all default
rc_add cloud-init-local default
rc_add cloud-init default
rc_add cloud-config default
rc_add cloud-final default

overlay_repack
#!/bin/sh -e

source $(dirname $0)/shared_functions.sh

# Add init.d scripts
mkdir -p "$tmp"/etc/init.d

mkdir -p "$tmp"/etc/cloud/fabric
makefile root:root 0755 "$tmp"/etc/init.d/fabric-assignment <<EOF
#!/sbin/openrc-run
map_path=/etc/cloud/fabric/fabric-map
dhcp_query=/usr/bin/dhcp-option-query
config_path=/etc/cloud/cloud.cfg.d/networking.cfg
ceol=[K
depend() {
	before cloud-gen
}
start() {
	timeout=15
	if [ ! -f \$map_path ] ; then
		echo " * Starting Fabric Assignments ..."
		echo "{" > \$map_path
		echo "  \"ifaces\": [" >> \$map_path
		INTERFACES="\$(ip link show | awk -F': ' '{print \$2}' | grep -v lo | xargs)"
		#INTERFACES="\$(ip link show | awk -F': ' '{print \$2}' | grep -v lo | grep -v docker | grep -v virbr | xargs)"
		for i in \$INTERFACES; do
			if [ "\$(cat /sys/class/net/\$i/operstate)" == "down" ] ; then
				echo -ne "   Bringing up \$i."
				ip link set \$i up
				tries=0
				while [ true ] ; do
					tries=\$((\$tries + 1))
					echo -ne "\r   Waiting for \$i to come up (\$tries/\$timeout) ... \${ceol}"
					if [ ! -f /sys/class/net/\$i/speed ] ; then
						sleep 1
					else
						if [ \$(cat /sys/class/net/\$i/speed) -lt 0 ] ; then
							sleep 1
						else
							echo -ne "\r   \$i is up.\${ceol}"
							search=1
							break
						fi
					fi
					if [ \$tries -ge \$timeout ] ; then
						search=0
						break
					fi
				done
			fi
			
			echo "    {" >> \$map_path
			echo "      \"name\"    : \"\$i\"," >> \$map_path
			echo "      \"arphdr\"  : \"\$(cat /sys/class/net/\$i/type)\"," >> \$map_path 2>/dev/null
			echo "      \"speed\"   : \"\$(cat /sys/class/net/\$i/speed)\"," >> \$map_path 2>/dev/null
			echo "      \"mtu\"     : \"\$(cat /sys/class/net/\$i/mtu)\"," >> \$map_path 2>/dev/null
			if [ \$search -eq 1 ] ; then
				echo -ne "\r   Checking DHCP on interface \$i for fabric ID.\${ceol}"
				#opt215=\$(\$dhcp_query \$i 215)
				if [ ! -z "\$opt215" ] ; then
					echo -e "\r * DHCP found on interface \$i with the fabric ID \$opt215.\${ceol}"
					echo "      \"fabric\"	: \"\$opt215\"," >> \$map_path
					subnet=\$(\$dhcp_query \$i 1)
					router=\$(\$dhcp_query \$i 3)
					dns=\$(\$dhcp_query \$i 6)
					echo "      \"network\" : \"\$(ipcalc -n \$router \$subnet | awk -F= '{print \$2}')\"," >> \$map_path
					echo "      \"bitmask\" : \"\$(ipcalc -p \$router \$subnet | awk -F= '{print \$2}')\"," >> \$map_path
					echo "      \"netmask\" : \"\$subnet\"," >> \$map_path
					echo "      \"gateway\" : \"\$router\"," >> \$map_path
					echo "      \"dns\"     : [\"\$(echo \$dns | awk '{\$1=\$1}1' OFS='","')\"]," >> \$map_path
				else
					echo -ne "\r   No fabric ID found on interface \$i. Switching to discovery mode.\${ceol}"
					fabric=\$(udhcpc -i \$i -n -R 2>/dev/null && echo NOCONFIG || echo NODHCP)
					echo "      \"fabric\"	: \"\$fabric\"," >> \$map_path
					if [ "\$fabric" == "NODHCP" ] ; then
						echo -e "\r o No DHCP found on interface \$i.\${ceol}"
					else
						echo -e "\r * DHCP found on interface \$i without a fabric ID.\${ceol}"
						subnet=\$(\$dhcp_query \$i 1)
						router=\$(\$dhcp_query \$i 3)
						dns=\$(\$dhcp_query \$i 6)
						echo "      \"network\" : \"\$(ipcalc -n \$router \$subnet | awk -F= '{print \$2}')\"," >> \$map_path
						echo "      \"bitmask\" : \"\$(ipcalc -p \$router \$subnet | awk -F= '{print \$2}')\"," >> \$map_path
						echo "      \"netmask\" : \"\$subnet\"," >> \$map_path
						echo "      \"gateway\" : \"\$router\"," >> \$map_path
						echo "      \"dns\"     : [\"\$(echo \$dns | awk '{\$1=\$1}1' OFS='","')\"]," >> \$map_path
					fi
				fi
			else
				echo -e "\r ! \$i appears to be unplugged.\${ceol}"
				echo "      \"fabric\"	: \"UNPLUGGED\"," >> \$map_path
				ip link set \$i down
			fi
			sed -i '$ s/.$//' \$map_path
			echo "    }," >> \$map_path
		done
		sed -i '$ s/.$//' \$map_path
		echo "  ]" >> \$map_path
		echo "}" >> \$map_path
		touch \$(dirname \$map_path)/map-was-generated
	else 
		echo " * Fabric map already exists."
	fi
	/etc/cloud/fabric/fabric-stitcher.py \$map_path > \$config_path
}
stop() {
	if [ -f \$(dirname \$map_path)/map-was-generated ] ; then
		rm \$map_path
		rm \$(dirname \$map_path)/map-was-generated
	fi
	rm \$config_path
}
EOF
installer_append <<EOF
if [ -f \$map_path ] ; then
	rm \$map_path
fi
EOF
makefile root:root 0755 "$tmp"/etc/cloud/fabric/fabric-stitcher.py <<EOF
#!/usr/bin/python3
import sys
import os.path
import json
import yaml
import importlib.util

if os.path.isfile(sys.argv[1]):
	fabrics = {}
	
	stitched = {}
	stitched["network"] = {}
	stitched["network"]["version"] = 1
	stitched["network"]["config"] = []
	
	with open(sys.argv[1]) as f:
		data = json.load(f)

	if len(data["ifaces"]) > 0:
		for iface in data["ifaces"]:
			arphdr = iface["arphdr"]
			id = iface["fabric"]
			if id == "NOCONFIG":
				id = iface["network"]+"/"+iface["bitmask"];
			if id == "UNPLUGGED":
				id = ""
			
			if id != "":
				try:
					fabrics[arphdr]
				except KeyError:
					fabrics[arphdr] = {}
				try:
					fabrics[arphdr][id]
				except KeyError:
					fabrics[arphdr][id] = []
				
				fabrics[arphdr][id].append(iface["name"])
		
		i = 0
		if len(fabrics) > 0:
			for _arphdr, _bonds in fabrics.items():
				for _id, _interfaces in _bonds.items():
					config = {}
					if len(_interfaces) == 1:
						config["type"]	= "physical"
						config["name"]	= _interfaces[0]
					else:
						config["type"]				= "bond"
						config["name"]				= "bond"+str(i)
						config["bond_interfaces"]	= _interfaces
						config["params"]			= {}
						
						i += 1
						
					# If a DHCP server was found, set the subnet type to DHCP
					if _id != "NODHCP":
						config["subnets"]	= [
							{
								"type"	: "dhcp"
							}
						]
						
					# Dynamically import configuration modifiers based on the ARP Hardware ID
					# This will automatically load modules from a directory with this file's name, at this file's absolute path,
					#	using the ARP Hardware ID prefixed by "arphdr_"
					module_path = os.path.abspath(sys.argv[0])[:-3]+"/arphdr_"+_arphdr+".py"
					module_name = "arphdr_"+_arphdr
					if os.path.isfile(module_path):
						if module_name not in sys.modules:
							spec = importlib.util.spec_from_file_location(module_name, module_path)
							module = importlib.util.module_from_spec(spec)
							spec.loader.exec_module(module)
						config = module.update(config)
						
					stitched["network"]["config"].append(config)
	
	print(yaml.dump(stitched, default_flow_style=False))
EOF
mkdir -p "$tmp"/etc/cloud/fabric/fabric-stitcher
makefile root:root 0644 "$tmp"/etc/cloud/fabric/fabric-stitcher/arphdr_1.py <<EOF
def update(config):
	if config["type"] == "bond":
		config["params"]["bond-mode"] = "802.3ad"
		config["params"]["bond-miimon"] = 100
		config["params"]["bond-xmit-hash-policy"] = "layer2+3"
	return config
EOF
makefile root:root 0644 "$tmp"/etc/cloud/fabric/fabric-stitcher/arphdr_32.py <<EOF
def update(config):
	if config["type"] == "physical":
		config["mtu"] = 65520
		config["pre-up"] = "echo connected > /sys/class/net/"+config["name"]+"/mode"
	if config["type"] == "bond":
		config["params"]["bond-mode"] = "active-backup"
		config["mtu"] = 65520
		for _iface in config["bond-interfaces"]:
			preup += "echo connected > /sys/class/net/"+_iface+"/mode &&"
		config["pre-up"] = preup[:-3]
	return config
EOF

makefile root:root 0755 "$tmp"/etc/init.d/fabric-assurance <<EOF
#!/sbin/openrc-run
confif_path=/etc/cloud/cloud.cfg.d/networking.cfg
depend() {
	after net
	before cloud-init
}
start() {
	ebegin "Assuring fabric TCP/IP communication"
	/etc/cloud/fabric/fabric-assurance.py \$config_path
	eend \$?
}
stop() {
	echo
}
EOF
makefile root:root 0755 "$tmp"/etc/cloud/fabric/fabric-assurance.py <<EOF
#!/usr/bin/python3
import os
import sys
import yaml
from netifaces import AF_INET, AF_INET6, AF_LINK, AF_PACKET, AF_BRIDGE
import netifaces as ni
import time

if os.path.isfile(sys.argv[1]):
	with open(sys.argv[1], 'r') as stream:
		config = yaml.load(stream)["network"]["config"]
	for _iface in config:
		try:
			if {"type":"dhcp"} in _iface["subnets"]:
				while True:
					try:
						ni.ifaddresses(_iface["name"])[AF_INET][0]['addr']
						break
					except KeyError:
						time.sleep(1)
		except KeyError:
			break
EOF

# Add apks to world
apks="bonding bridge py3-netifaces"
for a in $apks ; do
	if [ -z "$(cat $tmp/etc/apk/world | grep $a)" ] ; then
		echo $a >> "$tmp"/etc/apk/world
	fi
done

rc_add fabric-assignment default
rc_add fabric-assurance default

overlay_repack
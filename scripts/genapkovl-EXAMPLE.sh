#!/bin/sh -e

rm -rf /tmp/*

# Get shared functions and unpack any existing overlays
source $(dirname $0)/shared_functions.sh

# $tmp/ is / in the overlay
# Let make a file there owned by the root user (using the makefile function from the shared_functions.sh file)
makefile root:root 0644 "$tmp"/test.txt << EOF
This is the content of the file /test.txt
EOF

# You must create a directory if it doesn't already exist in the overlay (even if it does exist in the rootfs)
mkdir -p "$tmp"/var/www
makefile root:root 0644 "$tmp"/var/www/index.html << EOF
<html>
  <head>
    <title>Hello</title>
  </head>
  <body>
    <p>Hello, world!</p>
  </body>
<html>
EOF

# Let's create a simple OpenRC service that will start up a boot
# First let's create the script itself. Note, this time 0755 is used to make sure the file is executable.
# For more information about OpenRC syntax: https://github.com/OpenRC/openrc/blob/master/service-script-guide.md
mkdir -p "$tmp"/etc/init.d
makefile root:root 0755 "$tmp"/etc/init.d/example-service << EOF
#!/sbin/openrc-run
depend() {
	after net
}
start() {
	if [ ! -d /var/log/example-service ] ; then
		mkdir -p /var/log/example-service
	fi
	echo "The EXAMPLE service was started." >> /var/log/example-service/log.0
}
stop() {
	echo "The EXAMPLE service was stopped." >> /var/log/example-service/log.0
}
EOF
# Then we need to add it to the default runlevel (using the rc_add function from the shared_functions.sh file)
rc_add example-service default

# Let's add another service that will set all out network interfaces get IP addresses vis DHCP
# Note: Variables can be passed inside the EOF tags.
#       To make sure variables inside the script are used properly, escape the $ with a \ 
#       Look at how $config_path is defined outside of the EOF tags and is not escaped.
#       Also look at how $iface is defined inside the EOF tags and is escaped.
mkdir -p "$tmp"/etc/init.d
config_path=/etc/network/interfaces
makefile root:root 0755 "$tmp"/etc/init.d/dhcp-all-interfaces << EOF
#!/sbin/openrc-run
depend() {
	before net
}
start() {
	ebegin "Setting all interfaces to DHCP"
	# Backup the existing config
	if [ -f "$config_path" ] ; then
		cp "$config_path" "$config_path.bak"
	fi
	echo "# DHCP all interfaces" > "$config_path"
	echo "auto lo" >> "$config_path"
	echo "iface lo inet loopback"  >> "$config_path"
	echo  >> "$config_path"
	INTERFACES="\$(ip link show | awk -F': ' '{print \$2}' | grep -v lo | xargs)"
	for iface in \$INTERFACES ; do
		echo "auto \$iface" >> "$config_path"
		echo "iface \$iface inet dhcp" >> "$config_path"
		echo  >> "$config_path"
	done
	eend 0
}
stop() {
	ebegin "Returning interfaces to previous config"
	rm "$config_path"
	if [ -f "$config_path.bak" ] ; then
		mv "$config_path.bak" "$config_path"
	fi
	eend 0
}
EOF
rc_add dhcp-all-interfaces default

# Let's set up a basic HTML server
www_path=/var/www

# Let's add some files that we cloned using git
git clone https://github.com/mdn/beginner-html-site-styled.git
cp -r beginner-html-site-styled "$tmp""$www_path"

# We'll use nginx as the service provider
# Adding packages that should be included when the system is booted
# Be sure you also have these listed in the apks variable in the profile
apk_add nginx

# We should make sure it starts at the correct runlevel
rc_add nginx default

# We should give nginx a simple config file
# Note: We need to use the escape chacater \ when ever there is a $
mkdir -p "$tmp"/etc/nginx/
makefile root:root 0644 "$tmp"/etc/nginx/nginx.conf << EOF
user  nginx;
worker_processes  1;

error_log  /var/log/nginx/error.log warn;
pid        /var/run/nginx.pid;

events {
    worker_connections  1024;
}

http {
    include       /etc/nginx/mime.types;
    default_type  application/octet-stream;

    log_format  main  '\$remote_addr - \$remote_user [$time_local] "\$request" '
                      '\$status \$body_bytes_sent "\$http_referer" '
                      '"\$http_user_agent" "\$http_x_forwarded_for"';

    access_log  /var/log/nginx/access.log  main;
    sendfile        on;
    keepalive_timeout  65;

    include /etc/nginx/conf.d/*.conf;
}
EOF

# Let's make sure its configured to look in our $www_path directory for it's default site
mkdir -p "$tmp"/etc/nginx/conf.d
makefile root:root 0644 "$tmp"/etc/nginx/conf.d/default.conf << EOF
server {
    listen         80 default_server;
    server_name    example.com www.example.com;
    root           $www_path/beginner-html-site-styled;
    index          index.html;
    try_files \$uri /index.html;
}
EOF

# Let's make sure the nginx user can access the files we want
# Note: In this case the user id for nginx is 101 and the group id for nginx is 102
chown -R 101:102 "$tmp""$www_path"
chmod -R 0755 "$tmp""$www_path"

# Repackage the overlay file
overlay_repack
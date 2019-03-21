#!/bin/sh -e

# Get shared functions and unpack any existing overlays
source $(dirname $0)/shared_functions.sh

# $tmp/ is / in the overlay
# Let make a file there owned by the root user (using the makefile function from the shared_functions.sh file)
makefile root:root 0644 "$tmp"/test.txt << EOF
This is the content of the file /test.txt
EOF

# You must create a directory if it doesn't already exist in the overlay (even if it does exist in the rootfs)
mkdir -p /var/www/html
makefile root:root 0644 "$tmp"/var/www/html/index.html << EOF
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
mkdir -p /etc/init.d
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

# Let's add some files that we cloned using git
git clone https://github.com/mdn/beginner-html-site-styled.git
cp -r beginner-html-site-styled "$tmp"/var/www/html

# Adding packages that should be included when the system is booted
# Be sure you also have these listed in the apks variable in the profile
apk_add nginx


# Repackage the overlay file
overlay_repack
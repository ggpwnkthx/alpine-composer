#!/bin/sh -e

HOSTNAME="$1"
if [ -z "$HOSTNAME" ]; then
	echo "usage: $0 hostname"
	exit 1
fi

cleanup() {
	rm -rf "$tmp"
}

makefile() {
	OWNER="$1"
	PERMS="$2"
	FILENAME="$3"
	cat > "$FILENAME"
	chown "$OWNER" "$FILENAME"
	chmod "$PERMS" "$FILENAME"
}

rc_add() {
	mkdir -p "$tmp"/etc/runlevels/"$2"
	ln -sf /etc/init.d/"$1" "$tmp"/etc/runlevels/"$2"/"$1"
}

apk_add() {
	if [ ! -d "$tmp"/etc/apk ] ; then
		mkdir -p "$tmp"/etc/apk
	fi
	if [ ! -f "$tmp"/etc/apk/world ] ; then
		makefile root:root 0644 "$tmp"/etc/apk/world <<EOF
EOF
	fi
	for a in $@ ; do
		if [ -z "$(cat $tmp/etc/apk/world | grep $a)" ] ; then
			echo $a >> "$tmp"/etc/apk/world
		fi
	done
}

overlay_unpack() {
	tmp="$(mktemp -d)"
	ovl=$(dirname $(pwd))/$HOSTNAME.apkovl.tar.gz
	if [ -f $ovl ] ; then
		tar -xzf $ovl -C "$tmp"
	fi
	echo $tmp
}
overlay_repack() {
	tar -c -C "$tmp" . | gzip -9n > $HOSTNAME.apkovl.tar.gz
	if [ -f $(dirname $(pwd))/$HOSTNAME.apkovl.tar.gz ] ; then
		rm $(dirname $(pwd))/$HOSTNAME.apkovl.tar.gz
	fi
	cp $HOSTNAME.apkovl.tar.gz $(dirname $(pwd))/$HOSTNAME.apkovl.tar.gz
	rm -rf "$tmp"
}

installer_prefix() {
	if [ ! -f "$tmp"/sbin/install-os ] ; then
		mkdir -p "$tmp"/sbin
		makefile root:root 0755 "$tmp"/sbin/install-os
		echo "#!/bin/sh" | tee -a "$tmp"/sbin/install-os > /dev/null
		echo "install-disk" | tee -a "$tmp"/sbin/install-os > /dev/null
	fi
	old=$(mktemp)
	cp "$tmp"/sbin/install-os $old
	echo "#!/bin/sh" > "$tmp"/sbin/install-os
	cat /dev/stdin >> "$tmp"/sbin/install-os
	cat $old | grep -v "#!/bin/sh" >> "$tmp"/sbin/install-os
	rm $old
}
installer_append() {
	if [ ! -f "$tmp"/sbin/install-os ] ; then
		mkdir -p "$tmp"/sbin
		makefile root:root 0755 "$tmp"/sbin/install-os
		echo "#!/bin/sh" | tee -a "$tmp"/sbin/install-os > /dev/null
		echo "install-disk" | tee -a "$tmp"/sbin/install-os > /dev/null
	fi
	sed -i '$d' "$tmp"/sbin/install-os
	cat /dev/stdin >> "$tmp"/sbin/install-os
	echo "install-disk" | tee -a "$tmp"/sbin/install-os > /dev/null
}

tmp=$(overlay_unpack)

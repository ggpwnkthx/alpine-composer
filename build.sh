#!/bin/sh

# DON'T CHANGE
returnto=$(pwd)
DIR="$( cd "$( dirname "$0" )" > /dev/null && pwd )"

# CHANGE THESE
PROFILE=EXAMPLE			# Profile to build
VERSION=edge			# Options: edge, latest-stable, v3.9, ..., v2.4
ARCH=x86_64			# Options: x86_64, x86, ppc64le, s390x, aarch64, armhf, armv7

# DON'T CHANGE IF USING DOCKER
WORK_DIR=$DIR/work		# Directory to work in
ISO_DIR=$DIR/iso		# Directory to put the final ISO in

# Make sure we have everything we need to build (unless we're in a container, then assume we do)
if [ -z "$(grep 'docker\|lxc' /proc/1/cgroup)" ] ; then

	# If we docker is installed use it instead of building locally to establish consistency
	if [ ! -z "$(command -v docker)" ] ; then
		echo Building with docker ...
		
		./docker-build.sh
		exit 0
	fi
	
	# Make sure we're running on an Alpine distrobution
	if [ -f /etc/os-release ] ; then
		source /etc/os-release
		if [ "$NAME" != "Alpine Linux" ] ; then
			echo "Alpine Linux (or Docker) is a required."
			exit 2
		fi
	else
		echo "Alpine Linux (or Docker) is a required."
		exit 2
	fi
	
	# Set up repositories
	repo_version=$(cat /etc/alpine-release | head -n 1 | awk -F. '{print "v"$1"."$2}')
	if [ ! -z "$(echo $repo_version | grep '_')" ] ; then
		repo_version="edge"
	fi
	branches="main community"
	if [ "$repo_version" == "edge" ] ; then
		branches="$branches testing"
	fi
	for repo in $repo_version; do
		for branch in $branches; do
			if [ -z "$(cat /etc/apk/repositories | grep $repo/$branch)" ] ; then
				echo "http://dl-cdn.alpinelinux.org/alpine/$repo/$branch" >> /etc/apk/repositories
			else
				sed -i "/$repo\/$branch/s/^#//g" /etc/apk/repositories
			fi
		done
	done
	
	# Install required APKs
	requirements="alpine-sdk build-base apk-tools alpine-conf busybox fakeroot syslinux xorriso squashfs-tools mtools dosfstools grub-efi git shadow"
	for app in $requirements ; do
		if [ -z "$updated" ] ; then
			apk update 2>/dev/null
			updated=1
		fi
		if [ -z "$(apk info -e $app)" ] ; then
			apk add $app
		fi
	done

	# Add ourselves to the abuild group
	if [ -z "$(cat /etc/group | grep abuild: | grep $USER)" ] ; then
		if [ "$(cat /etc/group | grep abuild: | tail -c 2)" == ":" ] ; then
			sed -i -e "s/^abuild:.*/&$USER/" /etc/group
		else
			sed -i -e "s/^abuild:.*/&,$USER/" /etc/group
		fi
	fi
	
fi

# Download the aports from Alpine
clone=0
if [ ! -d $DIR/aports ] ; then
	clone=1
else
	if [ -z "$(ls $DIR/aports)" ] ; then
		clone=1
	fi
fi
if [ $clone == 1 ] ; then
	git clone git://git.alpinelinux.org/aports
fi

# Copy the customs scripts to aports/scripts
chmod -R 0755 scripts
cp -f $DIR/scripts/* $DIR/aports/scripts

# Create a key if necessary
if [ -d $DIR/keys ] ; then
	if [ ! -d /root/.abuild ] ; then
		mkdir -p /root/.abuild
	fi
	cp -r $DIR/keys/* /root/.abuild/
	cp /root/.abuild/*.pub /etc/apk/keys/
else
	mkdir -p $DIR/keys
fi	
if [ -z "$(ls /etc/apk/keys/ | grep $USER-.*.rsa.pub)" ] ; then	
	abuild-keygen -i -a -q -n
	cp -r /root/.abuild/* $DIR/keys/
fi

# Move to the aports/scripts directory
cd $DIR/aports/scripts

# Clean up previous builds
rm -f *.apkovl.tar.gz

# Establish the command to be run
make_cmd="./mkimage.sh \
	--tag $VERSION \
	--arch $ARCH \
	--repository http://dl-cdn.alpinelinux.org/alpine/$VERSION/main \
	--repository http://dl-cdn.alpinelinux.org/alpine/$VERSION/community \
	--profile $PROFILE \
	--outdir $ISO_DIR/ \
	--workdir $WORK_DIR"
if [ "$VERSION" == "edge" ] ; then 
	make_cmd="$make_cmd \
	--repository http://dl-cdn.alpinelinux.org/alpine/$VERSION/testing"
fi

# Run the command
if [ -z "$(id -Gn | grep abuild)" ]
then
	sg abuild -c "$make_cmd"
else
	$make_cmd
fi

# Return to the directory we started from
cd $returnto

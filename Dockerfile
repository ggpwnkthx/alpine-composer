FROM alpine:3.9
MAINTAINER Isaac Jessup "ibjessup@gmail.com"

RUN apk --no-cache add alpine-sdk build-base apk-tools alpine-conf busybox fakeroot syslinux xorriso squashfs-tools mtools dosfstools grub-efi git shadow

ENV USER root

WORKDIR /alpine-composer
CMD ["/alpine-composer/build.sh"]
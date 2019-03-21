# alpine-composer

## Requirements

For the most part, assume this must be run on Alpine Linux. You can either boot a VM with the alpine-standard image, or it can be run inside an Alpine container

## Setup

### One-liner
This will clone this repo and run the build script with default values.
```
git clone https://github.com/ggpwnkthx/alpine-composer.git && cd alpine-composer && ./build.sh
```

### build.sh
The build script has a few variable that can be changed to suite your needs.

#### PROFILE
This is the profile that the mkimage platform will start from.

#### VERSION
This is the Alpine version to build with. It can be different than the version that is running the builder.

#### ARCH
This is the architecture to build for.

#### WORK_DIR
This is the directory that will be used to cache downloads. The mkimage platform works intelligently enough that it won't do the same work twice.

#### ISO_DIR
This is the directory that will be used to place the output of the build process.

When using the "abstract" profile, the output file is determined by the architecture. For x86, x86_64, s390x, and ppc64le an ISO file is created. For aarch64, armhf, and armv7 a tar.gz file is created. However, this can easily be overwriten by setting the "image_ext" and "output_format" variables in your own profile.
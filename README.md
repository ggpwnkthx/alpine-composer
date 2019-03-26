# alpine-composer
## Requirements
For the most part, assume this must be run on Alpine Linux. You can either boot a VM with the alpine-standard image, or it can be run inside an Alpine container. If you have docker already installed, the one-liner script will automatically detect it and build your image using a docker container.
### Running from a Live ISO
If you are going to run this from a a live ISO, keep in mind that you will need twice as much RAM as your expected build size since the tmpfs will not allow more than half of RAM used for files. You will need a minimum of 4GB of RAM for the EXAMPLE profile.

Frankly, running this from a live ISO isn't an ideal way to use this. I would highly recommend using a container.
## Setup
The following command will download the required scripts and run the build process using the EXAMPLE profile. Running the build process for the first time will download, build, and cache all the required items to boot Alpine Linux on an x86_64 machine. See the build.sh section for other architectures.
### One-liner
This will clone this repo and run the build script with default values.
```
git clone https://github.com/ggpwnkthx/alpine-composer.git && cd alpine-composer && ./build.sh
```
Or if you don't have git:
```
wget https://github.com/ggpwnkthx/alpine-composer/archive/master.zip && unzip master.zip && cd alpine-composer-master && ./build.sh
```
If docker is installed, it will automatically use a docker container to run the build process.
## build.sh
### Usage
TODO: Add input arguments instead of relying on 
### Variables
The build script has a few variable that can be changed to suite your needs. Normally, these are set-and-forget, with PROFILE being the only one you'd actually want to change.
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
## Profiles
### Naming Convention
#### File Names
The filename for all profiles must be prefixed with "mkimage." and have the file extension ".sh" or they will not be recognized. For example, the correct filename format is: mkimage.profilename.sh

Although not a hard requirement, any overlay scripts should be prefixed with "genapkovl-" for consistency.


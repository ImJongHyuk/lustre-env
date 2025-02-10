#!/bin/bash

if [[ ! -d "$LUSTRE_HOME" ]]; then
    echo "Error: LUSTRE_HOME (=$LUSTRE_HOME) does not set."
    return 1
fi


# Update package list
sudo apt update

# Install required packages in alphabetical order
sudo apt install -y \
    bison \
    flex \
    libmount-dev \
    libnl-3-dev \
    libopenmpi-dev \
    libselinux1-dev \
    libssl-dev \
    libtool \
    libyaml-dev \
    libzfslinux-dev \
    module-assistant \
    pkg-config \
    quilt \
    swig \
    zfs-dkms \
    zfsutils-linux \
    zlib1g-dev


LUSTRE_RELEASE_DIR=$LUSTRE_HOME/lustre-release

# Check whether the Lustre repository is cloned.
if [ -d "$LUSTRE_RELEASE_DIR/.git" ] && git -C "$LUSTRE_RELEASE_DIR" rev-parse --is-inside-work-tree > /dev/null 2>&1; then
    echo "Lustre repository already exists at $LUSTRE_RELEASE_DIR, skipping clone."
else
    echo "Cloning Lustre repository... -> $LUSTRE_RELEASE_DIR"
    git clone git://git.whamcloud.com/fs/lustre-release.git "$LUSTRE_RELEASE_DIR"
fi

cd $LUSTRE_RELEASE_DIR
. autogen.sh
./configure --with-zfs


cd $LUSTRE_HOME

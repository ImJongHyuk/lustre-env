#!/bin/bash
# install-server.sh

set -e

if [[ ! -d "$LUSTRE_HOME" ]]; then
    echo "Error: LUSTRE_HOME (=$LUSTRE_HOME) does not set."
    return 1
fi

USER=$(whoami)
if [ "$USER" = "root" ]; then
    SUDO=""
else
    SUDO="sudo"
fi

# Update package list
$SUDO apt update

# Install required packages in alphabetical order
$SUDO apt install -y \
    bison \
    build-essential \
    debhelper \
    dkms \
    flex \
    libkeyutils-dev \
    libmount-dev \
    libnl-3-dev \
    libnl-genl-3-dev \
    libopenmpi-dev \
    libreadline-dev \
    libselinux1-dev \
    libssl-dev \
    libtool \
    libyaml-dev \
    libzfslinux-dev \
    rsync \
    module-assistant \
    pkg-config \
    python3-dev \
    python3-distutils \
    python3-setuptools \
    quilt \
    swig \
    zfs-dkms \
    zfsutils-linux \
    zlib1g-dev

# $SUDO dkms remove zfs/2.1.5 --all
$SUDO dkms install zfs/2.1.5 -k $(uname -r)
$SUDO modprobe zfs

LUSTRE_RELEASE_DIR=$LUSTRE_HOME/lustre-release

# Check whether the Lustre repository is cloned.
if [ -d "$LUSTRE_RELEASE_DIR/.git" ] && git -C "$LUSTRE_RELEASE_DIR" rev-parse --is-inside-work-tree > /dev/null 2>&1; then
    echo "Lustre repository found at $LUSTRE_RELEASE_DIR; skipping clone."
else
    echo "Cloning Lustre repository at $LUSTRE_RELEASE_DIR..."
    retries=0
    max_retries=3
    while true; do
        if git clone git://git.whamcloud.com/fs/lustre-release.git "$LUSTRE_RELEASE_DIR"; then
            break
        else
            retries=$((retries+1))
            if [ "$retries" -ge "$max_retries" ]; then
                echo "git clone failed after ${retries} attempts. Exiting."
                exit 1
            fi
            echo "git clone failed. Retrying (${retries}/${max_retries})..."
            sleep 5
        fi
    done
fi

cd $LUSTRE_RELEASE_DIR
. autogen.sh
./configure --enable-server --with-zfs
make debs -j$(nproc)

cd $LUSTRE_RELEASE_DIR/debs
dpkg -i lustre-server-*.deb
modprobe lustre
cd -

cd $LUSTRE_HOME

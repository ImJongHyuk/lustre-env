FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive
RUN apt update && apt install -y \
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
    zlib1g-dev \
    git \
    && rm -rf /var/lib/apt/lists/*

RUN dkms install zfs/2.1.5 -k $(uname -r) || true
RUN modprobe zfs || true

WORKDIR /workspace

CMD ["/bin/bash"]
FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive
RUN apt update && apt install -y \
    bison \
    build-essential \
    debhelper \
    dkms \
    flex \
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

RUN apt install git \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /workspace

CMD ["/bin/bash"]
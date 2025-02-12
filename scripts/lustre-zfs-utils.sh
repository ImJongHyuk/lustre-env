#!/bin/bash
# lustre-zfs-utils.sh
# Minimal Lustre management utility using ZFS/ZPOOL.
# All logs are in English (minimal information).
# This script mimics the lvcreate-based sequence for Lustre using ZFS, ZPOOL and mkfs.lustre.
#
# Commands:
#   create_pool <POOL> <DEVICE>
#   remove_pool
#   create_mgt
#   remove_mgt
#   create_fs <FS> <MDT_SIZE_IN_GB> <MDT_NUM> <OST_SIZE_IN_GB> <OST_NUM>
#   remove_fs <FS>
#   start_mgs
#   stop_mgs
#   start_fs <FS>
#   stop_fs <FS>
#   status

MGSNODE=$(hostname)
DEBUG=1  # Set to 1 to enable debug logs
POOL=""

error() {
  echo "ERROR: $1" >&2
  exit 1
}

info() {
  echo "INFO: $1"
}

debug() {
  if [ "$DEBUG" -ne 0 ]; then
    echo "DEBUG: $1"
  fi
}

# read_pool: Read pool name from /lustre/.pool.
read_pool() {
  if [ ! -f /lustre/.pool ]; then
    error "Pool file not found"
  fi
  POOL=$(cat /lustre/.pool)
  debug "Pool = ${POOL}"
}

create_pool() {
  local pool="$1"
  shift
  local devices=("$@")
  
  # 전달된 모든 디바이스가 블록 디바이스인지 확인합니다.
  for device in "${devices[@]}"; do
    if [ ! -b "$device" ]; then
      error "Block device $device not found"
    fi
  done
  
  if [ -f /lustre/.pool ]; then
    local exist_pool
    exist_pool=$(cat /lustre/.pool)
    error "Pool already exists: ${exist_pool}"
  fi
  
  # 여러 디바이스를 전달받아 ZFS 풀 생성
  zpool create -f "$pool" "${devices[@]}" || error "Failed to create pool"
  mkdir -p /lustre || error "Failed to create /lustre directory"
  echo "$pool" > /lustre/.pool
  info "Pool ${pool} created on devices: ${devices[*]}"
}

remove_pool() {
  read_pool
  if ! zpool list "$POOL" >/dev/null 2>&1; then
    rm -f /lustre/.pool
    error "Pool ${POOL} not found"
  fi
  zpool destroy "$POOL" || error "Failed to destroy pool"
  rm -rf /lustre
  info "Pool ${POOL} removed"
}

create_mgt() {
  read_pool
  local mgt_vol="${POOL}/mgt"
  if zfs list "$mgt_vol" >/dev/null 2>&1; then
    error "MGT already exists: $mgt_vol"
  fi
  info "Creating MGT zvol..."
  # Create 1G zvol for MGT
  zfs create -V 1G "$mgt_vol" || error "Failed to create MGT zvol"
  mkdir -p /lustre/mgt/lustre || error "Failed to create MGT backing store"
  info "Formatting MGT..."
  pushd /lustre >/dev/null || error "pushd failed"
    info "Current directory: $(pwd)"
    ls -ld mgt/lustre || info "mgt/lustre directory missing"
    mkfs.lustre --mgs --backfstype=zfs --reformat mgt/lustre /dev/zvol/"$mgt_vol" || error "mkfs.lustre MGT failed"
  popd >/dev/null
  echo "zfs" > /lustre/.osd.mgt
  info "MGT created"
}

remove_mgt() {
  read_pool
  if mount | grep -q "/lustre/mgt"; then
    error "MGS is running. Stop it first."
  fi
  [ -f /lustre/.osd.mgt ] && rm -f /lustre/.osd.mgt
  if zfs list "${POOL}/mgt" >/dev/null 2>&1; then
    zfs destroy "${POOL}/mgt" || error "Failed to destroy MGT zvol"
  fi
  rm -rf /lustre/mgt
  info "MGT removed"
}

# create_mdt_or_ost: Create MDT or OST volumes for a filesystem.
# Parameters: type (mdt or ost), FS, SIZE_IN_GB, NUM
create_mdt_or_ost() {
  local type="$1"
  local fs="$2"
  local size="$3"
  local num="$4"
  local size_kb=$(( size * 1024 * 1024 ))
  local type_upper
  type_upper=$(echo "$type" | tr '[:lower:]' '[:upper:]')

  local i
  for (( i=0; i<num; i++ )); do
    local vol_name="${POOL}/${fs}_${type}${i}"
    if zfs list "$vol_name" >/dev/null 2>&1; then
      error "${type_upper} zvol ${vol_name} already exists"
    fi

    info "Creating ${type_upper} zvol: ${vol_name}"
    # Create zvol with 8K block size for Lustre compatibility.
    zfs create -V "${size}G" -b 8K "$vol_name" || error "Failed to create zvol ${vol_name}"

    # Wait for the device node to appear.
    local dev_path="/dev/zvol/${vol_name}"
    local wait_count=0
    while [ ! -e "$dev_path" ] && [ $wait_count -lt 10 ]; do
      sleep 1
      wait_count=$((wait_count+1))
    done
    if [ ! -e "$dev_path" ]; then
      error "Device node ${dev_path} not found after waiting"
    fi
    debug "Device node exists: $(ls -l ${dev_path})"

    # Create the backing store directory under /lustre.
    local backing_parent="/lustre/${fs}_${type}${i}"
    local backing_dir="${backing_parent}/lustre"
    info "Creating backing store directory: ${backing_dir}"
    mkdir -p "$backing_dir" || error "Failed to create backing store ${backing_dir}"
    debug "Backing store directory info: $(ls -ld "$backing_dir")"

    # Ensure relative path is interpreted correctly: change directory to /lustre.
    pushd /lustre >/dev/null || error "pushd /lustre failed"
      info "Current directory: $(pwd)"
      info "Listing backing store: ls -ld ${fs}_${type}${i}/lustre"
      ls -ld "${fs}_${type}${i}/lustre" || info "Backing store directory not found"
      info "Executing mkfs.lustre for ${fs}_${type}${i} with device ${dev_path}"
      mkfs.lustre --${type} --backfstype=zfs --fsname="${fs}" --index="${i}" \
                   --mgsnode="${MGSNODE}" --device-size="${size_kb}" --reformat \
                   "${fs}_${type}${i}/lustre" ${dev_path} \
                   || error "mkfs.lustre ${type} failed for ${vol_name}"
    popd >/dev/null

    # Record the OSD type (in this case always "zfs").
    mkdir -p /lustre/"${fs}"
    echo "zfs" > /lustre/"${fs}"/.osd."${type}"
    info "${type_upper} ${i} created"
  done
}

create_fs() {
  local fs="$1"
  local mdt_size="$2"
  local mdt_num="$3"
  local ost_size="$4"
  local ost_num="$5"

  read_pool
  mkdir -p "/lustre/${fs}" || error "Failed to create FS directory (/lustre/${fs})"
  info "Creating MDT(s) for ${fs}..."
  create_mdt_or_ost "mdt" "$fs" "$mdt_size" "$mdt_num"
  info "Creating OST(s) for ${fs}..."
  create_mdt_or_ost "ost" "$fs" "$ost_size" "$ost_num"
  info "Filesystem ${fs} created"
}

remove_fs() {
  local fs="$1"
  read_pool
  for vol in $(zfs list -H -o name | grep "${POOL}/${fs}_"); do
    info "Destroying zvol: ${vol}"
    zfs destroy "$vol" || error "Failed to destroy zvol ${vol}"
  done
  rm -rf "/lustre/${fs}"
  info "Filesystem ${fs} removed"
}

start_mgs() {
  read_pool
  local mgt_dev="/dev/zvol/${POOL}/mgt"
  if mount | grep -q "/lustre/mgt"; then
    error "MGS already mounted"
  fi
  if [ ! -e "$mgt_dev" ]; then
    error "MGT device not found: ${mgt_dev}"
  fi
  mkdir -p /lustre/mgt || error "Failed to create /lustre/mgt directory"
  mount -t lustre mgt/lustre /lustre/mgt || error "Failed to mount MGS"
  info "MGS started"
}

stop_mgs() {
  if mount | grep -q "/lustre/mgt"; then
    umount /lustre/mgt || error "Failed to unmount MGS"
  fi
  info "MGS stopped"
}

start_fs() {
  local fs="$1"
  read_pool
  if ! mount | grep -q "/lustre/mgt"; then
    error "MGS not mounted"
  fi
  for dir in /lustre/"${fs}"/mdt*; do
    local base
    base=$(basename "$dir")
    local dev="/dev/zvol/${POOL}/${fs}_${base}"
    if [ ! -e "$dev" ]; then
      error "Device not found: ${dev}"
    fi
    mount -t lustre "${fs}_${base}/lustre" "$dir" || error "Failed to mount MDT ${dir}"
  done
  for dir in /lustre/"${fs}"/ost*; do
    local base
    base=$(basename "$dir")
    local dev="/dev/zvol/${POOL}/${fs}_${base}"
    if [ ! -e "$dev" ]; then
      error "Device not found: ${dev}"
    fi
    mount -t lustre "${fs}_${base}/lustre" "$dir" || error "Failed to mount OST ${dir}"
  done
  info "Filesystem ${fs} mounted"
}

stop_fs() {
  local fs="$1"
  for dir in /lustre/"${fs}"/mdt*; do
    if mount | grep -q "${dir}"; then
      umount "${dir}" || error "Failed to unmount ${dir}"
    fi
  done
  for dir in /lustre/"${fs}"/ost*; do
    if mount | grep -q "${dir}"; then
      umount "${dir}" || error "Failed to unmount ${dir}"
    fi
  done
  info "Filesystem ${fs} unmounted"
}

display_status() {
  read_pool
  echo "Pool: ${POOL}"
  if [ -f /lustre/.osd.mgt ]; then
    echo "MGT: exists"
  else
    echo "MGT: missing"
  fi
  for fs_dir in /lustre/*; do
    [ "$(basename "$fs_dir")" = "mgt" ] && continue
    if [ -d "$fs_dir" ]; then
      echo "FS: $(basename "$fs_dir")"
    fi
  done
}

usage() {
  echo "Usage: $0 COMMAND [OPTIONS]"
  echo ""
  echo "Commands:"
  echo "  create_pool <POOL> <DEVICE>"
  echo "  remove_pool"
  echo "  create_mgt"
  echo "  remove_mgt"
  echo "  create_fs <FS> <MDT_SIZE> <MDT_NUM> <OST_SIZE> <OST_NUM>"
  echo "  remove_fs <FS>"
  echo "  start_mgs"
  echo "  stop_mgs"
  echo "  start_fs <FS>"
  echo "  stop_fs <FS>"
  echo "  status"
  exit 1
}

if [ "$EUID" -ne 0 ]; then
  error "Run as root"
fi

if [ "$#" -lt 1 ]; then
  usage
fi

cmd="$1"
shift

case "$cmd" in
  create_pool)
    [ "$#" -eq 2 ] || usage
    create_pool "$1" "$2"
    ;;
  remove_pool)
    remove_pool
    ;;
  create_mgt)
    create_mgt
    ;;
  remove_mgt)
    remove_mgt
    ;;
  create_fs)
    [ "$#" -eq 5 ] || usage
    create_fs "$1" "$2" "$3" "$4" "$5"
    ;;
  remove_fs)
    [ "$#" -eq 1 ] || usage
    remove_fs "$1"
    ;;
  start_mgs)
    start_mgs
    ;;
  stop_mgs)
    stop_mgs
    ;;
  start_fs)
    [ "$#" -eq 1 ] || usage
    start_fs "$1"
    ;;
  stop_fs)
    [ "$#" -eq 1 ] || usage
    stop_fs "$1"
    ;;
  status)
    display_status
    ;;
  *)
    usage
    ;;
esac

exit 0
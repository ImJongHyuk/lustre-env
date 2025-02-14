#!/bin/bash
# lustre-setup.sh

set -e
set -u

# Logging functions
error() { echo "Err: $1" >&2; exit 1; }
info()  { echo "$1"; }
debug() { [ "${DEBUG:-0}" -ne 0 ] && echo "Dbg: $1"; }

# Load YAML config (requires yq)
load_config() {
  [ -z "${CONFIG_FILE:-}" ] && error "Config file required: -c config.yml"
  command -v yq >/dev/null || error "yq not found (https://github.com/mikefarah/yq)"
  
  # MGS/MDT configuration
  MGS_POOL=$(yq e '.mgt_mdt.pool' "$CONFIG_FILE")
  MGS_DEVICE=$(yq e '.mgt_mdt.device' "$CONFIG_FILE")
  MGS_SERVER_NAME=$(yq e '.mgt_mdt.server.name' "$CONFIG_FILE")
  MGS_ENTRYPOINT=$(yq e '.mgt_mdt.server.entrypoint' "$CONFIG_FILE")
  MGS_PROTOCOL=$(yq e '.mgt_mdt.server.protocol' "$CONFIG_FILE")
  MGS_SERVER="${MGS_ENTRYPOINT}@${MGS_PROTOCOL}"
  MGT_SIZE=$(yq e '.mgt_mdt.mgt_size' "$CONFIG_FILE")
  MDT_SIZE=$(yq e '.mgt_mdt.mdt.size' "$CONFIG_FILE")
  MDT_INDEX=$(yq e '.mgt_mdt.mdt.index' "$CONFIG_FILE")
  
  # OST configuration
  OST_POOL_PREFIX=$(yq e '.ost.pool_prefix' "$CONFIG_FILE")
  OST_SIZE=$(yq e '.ost.size' "$CONFIG_FILE")
  readarray -t OST_HOSTS < <(yq e '.ost.mappings[].host' "$CONFIG_FILE")
  
  # Filesystem and additional settings
  FS=$(yq e '.filesystem' "$CONFIG_FILE")
  LUSTRE_DIR=$(yq e '.lustre_dir' "$CONFIG_FILE")
  BLOCK_SIZE=$(yq e '.block_size' "$CONFIG_FILE")
}

check_all_unmounted() {
  if mount | grep -q "${LUSTRE_DIR}/mgt"; then
    info "MGS is still mounted."
    return 1
  fi
  if mount | grep -q "${LUSTRE_DIR}/${FS}_mdt"; then
    info "One or more MDT mounts are active."
    return 1
  fi
  if mount | grep -q "${LUSTRE_DIR}/${FS}_ost"; then
    info "One or more OSS mounts are active."
    return 1
  fi
  return 0
}

##############################
# Local create/setup functions
##############################

create_local_pool() {
  local pool="$1"
  shift
  local devices=("$@")
  for device in "${devices[@]}"; do
    if [ ! -b "$device" ]; then
      error "Device not found: $device"
    fi
  done
  if zpool list "$pool" >/dev/null 2>&1; then
    error "Pool exists: $pool"
  fi
  zpool create -f -O canmount=off -o multihost=on -o cachefile=none "$pool" "${devices[@]}" \
    || error "Pool create failed: $pool"
  mkdir -p "${LUSTRE_DIR}" || error "Dir create failed: ${LUSTRE_DIR}"
  export POOL="$pool"
  info "Pool created: $POOL"
}

create_local_mdt() {
  if [ -z "${POOL}" ]; then
    error "No pool. Run create_local_pool."
  fi
  local fs="$1"
  local mdt_size="$2"
  local mdt_index="$3"
  local zvol_name="${POOL}/${fs}_mdt${mdt_index}"
  info "Creating MDT: ${zvol_name} (${mdt_size}G)"

  if zfs list "${zvol_name}" >/dev/null 2>&1; then
    info "MDT exists; destroying: ${zvol_name}"
    zfs destroy -r "${zvol_name}" || error "Destroy MDT failed: ${zvol_name}"
  fi

  zfs create -V ${mdt_size}G -b ${BLOCK_SIZE} "${zvol_name}" || error "MDT create failed: ${zvol_name}"
  
  mkdir -p "${LUSTRE_DIR}/${fs}_mdt${mdt_index}/lustre" || error "MDT backing fail"
  local size_kb=$(( mdt_size * 1024 * 1024 ))
  cd "${LUSTRE_DIR}" || error "cd fail: ${LUSTRE_DIR}"
  mkfs.lustre --mdt --backfstype=zfs --fsname="${fs}" --index="${mdt_index}" --mgsnode="${MGS_SERVER}" \
    --device-size="${size_kb}" --reformat "${fs}_mdt${mdt_index}/lustre" /dev/zvol/"${zvol_name}" \
    || error "mkfs MDT fail: ${zvol_name}"
  cd - >/dev/null
  info "MDT created: ${fs}_mdt${mdt_index}"
}

create_local_ost() {
  if [ -z "${POOL}" ]; then
    error "No pool. Run create_local_pool."
  fi
  local fs="$1"
  local ost_size="$2"
  local ost_index="$3"
  local zvol_name="${POOL}/${fs}_ost${ost_index}"
  info "Creating OST: ${zvol_name} (${ost_size}G)"
  zfs create -V ${ost_size}G -b ${BLOCK_SIZE} "${zvol_name}" || error "OST create failed: ${zvol_name}"
  mkdir -p "${LUSTRE_DIR}/${fs}_ost${ost_index}/lustre" || error "OST backing fail"
  local size_kb=$(( ost_size * 1024 * 1024 ))
  
  dev="/dev/zvol/${POOL}/${fs}_ost${ost_index}"
  timeout=0
  while [ ! -e "$dev" ] && [ $timeout -lt 10 ]; do
    sleep 1
    timeout=$((timeout+1))
  done
  if [ ! -e "$dev" ]; then
    error "Device not found: $dev"
  fi
  
  cd "${LUSTRE_DIR}" || error "cd fail: ${LUSTRE_DIR}"
  mkfs.lustre --ost --backfstype=zfs --fsname="${fs}" --index="${ost_index}" --mgsnode="${MGS_SERVER}" \
    --device-size="${size_kb}" --reformat "${fs}_ost${ost_index}/lustre" \
    /dev/zvol/"${zvol_name}" || error "mkfs OST fail: ${zvol_name}"
  cd - >/dev/null
}

setup_mgt_mdt_local() {
  info "Starting MGS/MDT setup on $(hostname)"
  create_local_pool "${MGS_POOL}" "${MGS_DEVICE}"
  zfs create -V ${MGT_SIZE}G -b ${BLOCK_SIZE} "$POOL/mgt" || error "Failed to create MGT zvol"
  sleep 2
  mkdir -p "${LUSTRE_DIR}/mgt/lustre" || error "Failed to create MGT backing store"
  cd "${LUSTRE_DIR}" || error "Failed to cd to ${LUSTRE_DIR}"
  mkfs.lustre --mgs --backfstype=zfs --device-size=$(( MGT_SIZE * 1024 * 1024 )) --reformat mgt/lustre /dev/zvol/"$POOL/mgt" \
    || error "mkfs.lustre MGS failed"
  cd - >/dev/null
  info "MGS created"
  create_local_mdt "${FS}" "${MDT_SIZE}" "${MDT_INDEX}"
}

setup_ost_local() {
  info "Starting OST setup on $(hostname -s)"
  current_host=$(hostname -s)
  if [ -z "${OST_DEVICES:-}" ] || [ -z "${OST_INDEX_OFFSET:-}" ]; then
    error "Environment variables OST_DEVICES and OST_INDEX_OFFSET must be set on remote node"
  fi
  IFS=',' read -r -a devices <<< "$OST_DEVICES"
  global_index="${OST_INDEX_OFFSET}"
  for k in "${!devices[@]}"; do
    device="${devices[$k]}"
    pool_name="${OST_POOL_PREFIX}_${current_host}_${k}"
    info "Creating OST on host ${current_host}: device ${device}, pool ${pool_name}, OST index ${global_index}"
    create_local_pool "$pool_name" "$device"
    create_local_ost "$FS" "$OST_SIZE" "$global_index" --mgsnode="${MGS_SERVER}"
    global_index=$((global_index + 1))
  done
}

status_local() {
  local node
  node=$(hostname -s)
  echo "[$node]"
  mount | grep lustre | sed "s/^/[$node] /" || echo "[$node] None"
}

get_all_nodes() {
  local nodes=()

  local mapping_count
  mapping_count=$(yq e '.ost.mappings | length' "$CONFIG_FILE")
  for (( i=0; i < mapping_count; i++ )); do
    local host
    host=$(yq e ".ost.mappings[$i].host" "$CONFIG_FILE")

    if ! printf "%s\n" "${nodes[@]}" | grep -w -q "$host"; then
      nodes+=("$host")
    fi
  done
  
  if ! printf "%s\n" "${nodes[@]}" | grep -w -q "$MGS_ENTRYPOINT"; then
    nodes+=("$MGS_ENTRYPOINT")
  fi

  local IFS=,
  echo "${nodes[*]}"
}

# pdsh wrapper (remote commands)
pdsh_remote() {
  local targets="$1"
  local cmd="$2"
  pdsh -w "$targets" "set -euo pipefail; \
export DEBUG=1; \
export MGS_POOL='${MGS_POOL}'; \
export MGS_DEVICE='${MGS_DEVICE}'; \
export MGS_SERVER='${MGS_SERVER}'; \
export MGT_SIZE='${MGT_SIZE}'; \
export MDT_SIZE='${MDT_SIZE}'; \
export MDT_INDEX='${MDT_INDEX}'; \
export OST_POOL_PREFIX='${OST_POOL_PREFIX}'; \
export OST_SIZE='${OST_SIZE}'; \
export FS='${FS}'; \
export LUSTRE_DIR='${LUSTRE_DIR}'; \
export BLOCK_SIZE='${BLOCK_SIZE}'; \
source $(realpath "$0"); \
${cmd}"
}

##############################
# Local mount/umount functions
##############################

start_mgs_local() {
  if ! mount | grep -q "${LUSTRE_DIR}/mgt"; then
    mkdir -p "${LUSTRE_DIR}/mgt"
    mount -t lustre mgt/lustre "${LUSTRE_DIR}/mgt" || error "MGS mount fail"
    info "MGS mounted on $(hostname -s)"
  else
    info "MGS already mounted"
  fi
}

start_mds_local() {
  if ! mount | grep -q "${LUSTRE_DIR}/${FS}_mdt${MDT_INDEX}"; then
    mkdir -p "${LUSTRE_DIR}/${FS}_mdt${MDT_INDEX}"
    mount -t lustre "${FS}_mdt${MDT_INDEX}/lustre" "${LUSTRE_DIR}/${FS}_mdt${MDT_INDEX}" || error "MDT mount fail"
    info "MDT mounted on $(hostname -s)"
  else
    info "MDT already mounted"
  fi
}

start_oss_local() {
  if [ -z "${OST_COUNT:-}" ] || [ -z "${OST_INDEX_OFFSET:-}" ]; then
    info "OST mount skipped"
    return 0
  fi

  for local_index in $(seq 0 $((OST_COUNT - 1))); do
    global_index=$(( OST_INDEX_OFFSET + local_index ))
    mount_point="${LUSTRE_DIR}/${FS}_ost${global_index}"
    if ! mount | grep -q "${mount_point}"; then
      mkdir -p "${mount_point}"
      pool_name="${OST_POOL_PREFIX}_$(hostname -s)_${local_index}"
      mount_source="${FS}_ost${global_index}/lustre"
      info "Mounting OSS on $(hostname -s): ${mount_source} -> ${mount_point}"
      mount -t lustre "${mount_source}" "${mount_point}" || error "OSS mount fail: ${global_index}"
    else
      info "OST ${global_index} already mounted"
    fi
  done
}

stop_mgs_local() {
  if mount | grep -q "${LUSTRE_DIR}/mgt"; then
    umount "${LUSTRE_DIR}/mgt" || error "MGS unmount fail"
    info "MGS unmounted on $(hostname -s)"
  else
    info "MGS already unmounted"
  fi
}

stop_mds_local() {
  if mount | grep -q "${LUSTRE_DIR}/${FS}_mdt${MDT_INDEX}"; then
    umount "${LUSTRE_DIR}/${FS}_mdt${MDT_INDEX}" || error "MDT unmount fail"
    info "MDT unmounted on $(hostname -s)"
  else
    info "MDT already unmounted"
  fi
}

stop_oss_local() {
  if [ -z "${OST_COUNT:-}" ] || [ -z "${OST_INDEX_OFFSET:-}" ]; then
    info "OST unmount skipped"
    return 0
  fi

  for local_index in $(seq 0 $(( OST_COUNT - 1 ))); do
    global_index=$(( OST_INDEX_OFFSET + local_index ))
    mount_point="${LUSTRE_DIR}/${FS}_ost${global_index}"
    if mount | grep -q "${mount_point}"; then
      umount "${mount_point}" || error "OSS unmount fail: ${global_index}"
      info "OST ${global_index} unmounted on $(hostname -s)"
    else
      info "OST ${global_index} already unmounted"
    fi
  done
}

##############################
# Main command processing
##############################
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  usage() {
    cat <<EOF
Usage: $0 [-c config.yml] <command>
Commands:
  setup_mgt_mdt  : Create MGS/MDT
  setup_ost      : Create OSTs
  start_mgs      : Mount MGS
  start_mds      : Mount MDT
  start_oss      : Mount OSS
  stop_mgs       : Unmount MGS
  stop_mds       : Unmount MDT
  stop_oss       : Unmount OSS
  status         : Display status
  check          : Check all mounts
  remove_pools   : Remove all pools
EOF
    exit 1
  }

  # Option parsing: [-c config.yml]
  CONFIG_FILE=""
  while getopts "c:" opt; do
    case "$opt" in
      c) CONFIG_FILE="$OPTARG" ;;
      *) usage ;;
    esac
  done
  shift $((OPTIND-1))

  if [ -z "$CONFIG_FILE" ]; then
    if [ -z "${LUSTRE_HOME:-}" ]; then
      error "LUSTRE_HOME environment variable is not set. Please run lustreenv first."
    fi
    CONFIG_FILE="${LUSTRE_HOME}/conf/config.yml"
  fi

  [ "$#" -ge 1 ] || usage

  # Main command
  COMMAND="$1"
  shift

  # Load configuration
  load_config
  SCRIPT_PATH="$(realpath "$0")"
  export PDSH_RCMD_TYPE=ssh
  export PDSH_SSH_ARGS="-oStrictHostKeyChecking=no"

  case "${COMMAND}" in
    setup_mgt_mdt)
      info "Creating MGS/MDT on ${MGS_ENTRYPOINT}"
      pdsh_remote "${MGS_ENTRYPOINT}" "setup_mgt_mdt_local"
      ;;
    setup_ost)
      mapping_count=$(yq e '.ost.mappings | length' "$CONFIG_FILE")
      global_index=0
      for (( i=0; i < mapping_count; i++ )); do
        host=$(yq e ".ost.mappings[$i].host" "$CONFIG_FILE")
        devices=$(yq e '.ost.mappings['"$i"'].devices | join(",")' "$CONFIG_FILE")
        info "OST: ${host} devices: (${devices}) index: ${global_index}"
        pdsh_remote "${host}" "export OST_DEVICES='${devices}'; export OST_INDEX_OFFSET='${global_index}'; setup_ost_local"
        device_count=$(yq e ".ost.mappings[$i].devices | length" "$CONFIG_FILE")
        global_index=$(( global_index + device_count ))
      done
      ;;
    start_mgs)
      info "Mounting MGS on ${MGS_ENTRYPOINT}"
      pdsh_remote "${MGS_ENTRYPOINT}" "start_mgs_local"
      ;;
    start_mds)
      info "Mounting MDT on ${MGS_ENTRYPOINT}"
      pdsh_remote "${MGS_ENTRYPOINT}" "start_mds_local"
      ;;
    start_oss)
      mapping_count=$(yq e '.ost.mappings | length' "$CONFIG_FILE")
      global_index=0
      for (( i=0; i < mapping_count; i++ )); do
        host=$(yq e ".ost.mappings[$i].host" "$CONFIG_FILE")
        ost_count=$(yq e ".ost.mappings[$i].devices | length" "$CONFIG_FILE")
        info "Mount OSS on ${host}: count ${ost_count}, offset ${global_index}"
        pdsh_remote "${host}" "export OST_COUNT='${ost_count}'; export OST_INDEX_OFFSET='${global_index}'; start_oss_local"
        global_index=$(( global_index + ost_count ))
      done
      ;;
    stop_mgs)
      info "Unmounting MGS on ${MGS_ENTRYPOINT}"
      pdsh_remote "${MGS_ENTRYPOINT}" "stop_mgs_local"
      ;;
    stop_mds)
      info "Unmounting MDT on ${MGS_ENTRYPOINT}"
      pdsh_remote "${MGS_ENTRYPOINT}" "stop_mds_local"
      ;;
    stop_oss)
      mapping_count=$(yq e '.ost.mappings | length' "$CONFIG_FILE")
      global_index=0
      for (( i=0; i < mapping_count; i++ )); do
        host=$(yq e ".ost.mappings[$i].host" "$CONFIG_FILE")
        ost_count=$(yq e ".ost.mappings[$i].devices | length" "$CONFIG_FILE")
        info "Unmount OSS on ${host}: count ${ost_count}, offset ${global_index}"
        pdsh_remote "${host}" "export OST_COUNT='${ost_count}'; export OST_INDEX_OFFSET='${global_index}'; stop_oss_local"
        global_index=$(( global_index + ost_count ))
      done
      ;;
    status)
      all_nodes=$(get_all_nodes)
      # info "Status: ${OST_HOSTS[*]}"
      info "Status: ${all_nodes}"
      output=$(pdsh_remote "${all_nodes}" "status_local")
      echo "$output" | sort
      ;;
    check)
      info "Running check_all_unmounted on MGS host: ${MGS_ENTRYPOINT}"
      pdsh_remote "${MGS_ENTRYPOINT}" "check_all_unmounted" || error "Check failed on MGS host: ${MGS_ENTRYPOINT}"
      mapping_count=$(yq e '.ost.mappings | length' "$CONFIG_FILE")
      for (( i=0; i < mapping_count; i++ )); do
        host=$(yq e ".ost.mappings[$i].host" "$CONFIG_FILE")
        info "Checking unmounted status on host: ${host}"
        pdsh_remote "${host}" "check_all_unmounted" || error "Check failed on host: ${host}"
      done
      info "All hosts are unmounted."
      ;;
    remove_pools)
      all_nodes=$(get_all_nodes)
      pdsh_remote "${all_nodes}" "check_all_unmounted" || error "Check failed on one or more nodes: ${all_nodes}"
      for i in {1..3}; do
        pdsh_remote "${all_nodes}" "for pool in \$(zpool list -H -o name); do
          info \"Run ${i}: Destroying pool: \$pool on \$(hostname)\";
          zpool destroy \"\$pool\" || true;
        done"
      done
      
      pdsh_remote "${all_nodes}" "zpool list"
      ;;
    *)
      usage
      ;;
  esac
fi

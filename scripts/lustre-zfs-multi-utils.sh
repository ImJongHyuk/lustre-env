#!/bin/bash
# lustre-zfs-multi-utils.sh
# Multi Node Lustre management utility using ZFS/ZPOOL for distributed environments.
#
# 이 스크립트는 Ansible을 이용하여 멀티 노드 환경에서 로컬 ZFS 풀, MDT, OST zvol 생성 작업을 수행하기 위한
# 기본 함수를 제공합니다.
#
# 사용 예시 (원격 노드에서 Ansible으로 실행):
#   ./lustre-zfs-multi-utils.sh create_local_pool <POOL> <DEVICE>
#   ./lustre-zfs-multi-utils.sh create_local_mdt <FS> <MDT_SIZE_IN_GB> <MDT_INDEX>
#   ./lustre-zfs-multi-utils.sh create_local_ost <FS> <OST_SIZE_IN_GB> <OST_INDEX> [--mgsnode <MGSNODE>]
#
# 각 노드에서는 먼저 로컬 풀을 생성한 후,
# 해당 풀 위에 MDT와 OST zvol을 생성하여 Lustre MGS/MDT/OST 클러스터에 기여하도록 구성합니다.
#
# 참고:
# - 기존의 lustre-zfs-utils.sh는 단일 노드 환경용으로 그대로 재활용할 수 있습니다.
# - 이 스크립트는 각 노드에서 개별적으로 실행되며, 클러스터 전체의 조정 및 배포는 Ansible 등 외부 오케스트레이션 도구를 이용합니다.
#

set -e

DEBUG=1

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

# 글로벌 변수: 로컬 풀 이름 (create_local_pool 실행 시 설정됨)
POOL=""

# create_local_pool: 로컬 ZFS 풀 생성 (단일 노드 내에서 사용)
create_local_pool() {
  local pool="$1"
  shift
  local devices=("$@")
  
  # 전달된 모든 디바이스가 블록 디바이스인지 확인합니다.
  for device in "${devices[@]}"; do
    if [ ! -b "$device" ]; then
      error "Block device $device not found"
    fi
  done
  
  if zpool list "$pool" >/dev/null 2>&1; then
    error "Pool $pool already exists"
  fi
  
  # 여러 디바이스를 사용하여 ZFS 풀 생성
  zpool create -f "$pool" "${devices[@]}" || error "Failed to create pool $pool on devices: ${devices[*]}"
  mkdir -p /lustre || error "Failed to create /lustre directory"
  POOL="$pool"
  info "Local pool ${POOL} created on devices: ${devices[*]}"
}

# create_local_mdt: 로컬 MDT zvol 생성
# 매개변수: <FS> <MDT_SIZE_IN_GB> <MDT_INDEX>
create_local_mdt() {
  if [ -z "${POOL}" ]; then
    error "Local pool not set. Please run create_local_pool first."
  fi
  local fs="$1"
  local mdt_size="$2"
  local mdt_index="$3"
  local zvol_name="${POOL}/${fs}_mdt${mdt_index}"
  info "Creating local MDT zvol: ${zvol_name} with size ${mdt_size}G"
  zfs create -V ${mdt_size}G "${zvol_name}" || error "Failed to create MDT zvol ${zvol_name}"
}

# create_local_ost: 로컬 OST zvol 생성
# 매개변수: <FS> <OST_SIZE_IN_GB> <OST_INDEX> [--mgsnode <MGSNODE>]
create_local_ost() {
  if [ -z "${POOL}" ]; then
    error "Local pool not set. Please run create_local_pool first."
  fi
  local fs="$1"
  local ost_size="$2"
  local ost_index="$3"
  shift 3
  local mgsnode=""
  while [[ "$#" -gt 0 ]]; do
    case $1 in
      --mgsnode)
        mgsnode="$2"
        shift 2
        ;;
      *)
        shift
        ;;
    esac
  done

  local zvol_name="${POOL}/${fs}_ost${ost_index}"
  info "Creating local OST zvol: ${zvol_name} with size ${ost_size}G"
  zfs create -V ${ost_size}G "${zvol_name}" || error "Failed to create OST zvol ${zvol_name}"
  
  if [ -n "$mgsnode" ]; then
    info "Configuring OST ${zvol_name} to connect to MGS node: ${mgsnode}"
    # 추가 구성 작업 (예: Lustre 연결 설정)이 필요한 경우 여기에 추가합니다.
  fi
}

# remove_local_pool: 로컬 ZFS 풀 제거
remove_local_pool() {
  local pool="$1"
  if ! zpool list "$pool" >/dev/null 2>&1; then
    error "Pool $pool does not exist"
  fi
  zpool destroy "$pool" || error "Failed to destroy pool $pool"
  rm -rf /lustre
  info "Local pool ${pool} removed"
}

# 사용법 출력 함수
usage() {
  cat <<EOF
Usage: $0 <command> [parameters]
Commands:
  create_local_pool <POOL> <DEVICE>
      로컬 ZFS 풀을 생성합니다.
  
  create_local_mdt <FS> <MDT_SIZE_IN_GB> <MDT_INDEX>
      로컬 MDT zvol을 생성합니다.
  
  create_local_ost <FS> <OST_SIZE_IN_GB> <OST_INDEX> [--mgsnode <MGSNODE>]
      로컬 OST zvol을 생성합니다. (옵션: MGS 노드 지정)
  
  remove_local_pool <POOL>
      지정한 로컬 ZFS 풀을 제거합니다.
EOF
}

# 메인 스위치: 입력된 명령에 따라 함수 호출
case "$1" in
  create_local_pool)
    [ "$#" -eq 3 ] || { usage; exit 1; }
    create_local_pool "$2" "$3"
    ;;
  create_local_mdt)
    [ "$#" -eq 4 ] || { usage; exit 1; }
    create_local_mdt "$2" "$3" "$4"
    ;;
  create_local_ost)
    if [ "$#" -lt 4 ]; then
      usage
      exit 1
    fi
    create_local_ost "$2" "$3" "$4" "${@:5}"
    ;;
  remove_local_pool)
    [ "$#" -eq 2 ] || { usage; exit 1; }
    remove_local_pool "$2"
    ;;
  *)
    usage
    exit 1
    ;;
esac 
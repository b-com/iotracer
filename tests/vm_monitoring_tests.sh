#!/bin/bash
#/*!**************************************************************
#* \copyright (C) Copyright 2015-2016 b<>com
#* \brief     Integration tests of the iotracer kernel module using libvirt
#* This program is free software; you can redistribute it and/or
#* modify it under the terms of the GNU General Public Licence
#* as published by the Free Software Foundation; either version
#* 2 of the Licence, or (at your option) any later version.
#***************************************************************/

show_usage() {
  echo "Usage: $0 [OPTION]... vm_name vm_directory_path"
  echo "where vm_name is the name of the virtual machine to use"
  echo "and vm_directory path is the path where to install the VM image"
  echo "if the VM does not exist"
  echo
  echo "Options:"
  echo "  -m cache_mode    Specify libvirt-KVM cache mode (default: none)"
  exit 3
}

CACHE_MODE=none

while getopts m: opt
do
    case "$opt" in
      m) CACHE_MODE="$OPTARG";;
      \?) # unknown flag
          echo >&2 \
          show_usage;;
    esac
done
shift $(( OPTIND - 1 ))

if [ $# -lt 1 -o $# -gt 3 ]; then
  show_usage
fi

#== global variables 

script_name=$(basename "$0" .sh)
script_dir=$(dirname "$0")
IOTRACER_PATH=$(readlink -e "${script_dir}/..")
io_profile="${IOTRACER_PATH}"/tests/io_profile.py

GUEST_NAME=$1
VM_DIR=$(readlink -f "$2")

#== functions ==

# function clear_cache
. "${IOTRACER_PATH}"/scripts/cache_func.sh

# iotracer wrapper functions
. "${IOTRACER_PATH}"/scripts/iotracer_func.sh

# functions to manage libvirt domains
. "${IOTRACER_PATH}"/scripts/libvirt_func.sh

# load framework tests
. "${IOTRACER_PATH}"/tests/assert.sh


#== Tests

# Check VM exist and is running
vm_state=$(virsh list --all | awk -v guestname="${GUEST_NAME}" '$2==guestname { print $3 }')
if [ -z "${vm_state}" ]; then
  echo "we need to create the VM"
  if [ $# -lt 2 ]; then
    show_usage
  fi
  # install VM image if needed
  if [ ! -f "${VM_DIR}/${GUEST_NAME}.qcow2" ]; then
    install_debian_image "${VM_DIR}/${GUEST_NAME}.qcow2"
    if [ $? -ne 0 ]; then
      echo "Failed to setup test environment" && exit 1
    fi
  fi
  # Create new guest using VM image
  create_domain "${VM_DIR}/${GUEST_NAME}.qcow2" "${CACHE_MODE}"
elif [ "${vm_state}" != "running" ]; then
  # Start the guest
  virsh start "${GUEST_NAME}"
  wait_domain_ssh_ready "${GUEST_NAME}"
fi

if [ $? -ne 0 ]; then
  echo "Cannot access to VM" && exit 1
fi

# Install fio in guest
fio_status=$(\
  domain_exec_cmd "${GUEST_NAME}" \
    "dpkg-query -l fio | awk '\$2 == \"fio\" { print \$1 }'")
if [ "${fio_status}" != "ii" ]; then
  domain_exec_cmd "${GUEST_NAME}" "sudo apt-get -y install fio"
fi

vm_image=$(readlink -f "$(domain_to_image "${GUEST_NAME}")")
if [ $# -eq 2 ]; then
  if [ "${vm_image}" != "${VM_DIR}/${GUEST_NAME}.qcow2" ]; then
    echo "Using image ${vm_image} (expected ${VM_DIR}/${GUEST_NAME}.qcow2)"
  fi
fi

mkdir -p /tmp/iotracer

# Check if host cache is diabled for this guest
rm -f /tmp/iotracer/"${GUEST_NAME}".xml
virsh dumpxml "${GUEST_NAME}" > /tmp/iotracer/"${GUEST_NAME}".xml
cache_mode=$(xmllint --xpath 'string(/domain/devices/disk/driver/@cache)' /tmp/iotracer/"${GUEST_NAME}".xml)
rm -f /tmp/iotracer/"${GUEST_NAME}".xml

# Load iotracer module
load_iotracer
if [ $? -ne 0 ]; then
  echo "Failed to load kernel module" && exit 1
fi

_assert_reset

for testdesc in "${script_dir}/${script_name}"/* ; do
  testname=$(basename "${testdesc}")
  echo "Executing test ${testname}"

  . "${testdesc}"

  if [ "${rwmixread}" -gt 0 ]; then
    # create test file on guest
    domain_exec_cmd "${GUEST_NAME}" \
      "dd if=/dev/urandom of=${testname}.bin \
          bs=${blocksize} count=$(( size / blocksize ))"
  fi;
  domain_exec_cmd "${GUEST_NAME}" "$(typeset -f clear_cache); clear_cache"

  clear_cache
  monitor_file "${vm_image}" $(( 2 * size / blocksize ))

  cmd_output=$(\
    domain_exec_cmd "${GUEST_NAME}" \
      "fio --minimal --gtod_reduce=1 \
        --name=\"$(basename "${testdesc}")\" --filename=\"${testname}.bin\" \
        --rw=randrw --end_fsync=1 --ioengine=${ioengine} --direct=${direct} \
        --bs=${blocksize} --filesize=${size} --rwmixread=${rwmixread} \
        --percentage_random=${percentage_random_read},${percentage_random_write}")

  # As fio read/write sizes is not conform to what we expect from rwmixread
  # we need to get the real values
  fio_readsize=$(echo "${cmd_output}" | awk -F\; '{ print $6 }')
  fio_writesize=$(echo "${cmd_output}" | awk -F\; '{ print $47 }')
  cp -f "${testdesc}" /tmp/iotracer/"${testname}"
  echo read_bytes=$(( fio_readsize * 1024 )) >> /tmp/iotracer/"${testname}"
  echo write_bytes=$(( fio_writesize * 1024 )) >> /tmp/iotracer/"${testname}"
  sleep $(( $(cat /proc/sys/vm/dirty_expire_centisecs) / 100 ))
  sync
  rm -f /tmp/iotracer/"${testdesc}".iolog
  cat "$(monitored_file_procdir "${vm_image}")"/log > /tmp/iotracer/"${testname}".iolog

  if [ "${cache_mode}" = "none" ]; then
    prof_output=$("${io_profile}" check /tmp/iotracer/"${testname}".iolog /tmp/iotracer/"${testname}" --directio)
  else
    prof_output=$("${io_profile}" check /tmp/iotracer/"${testname}".iolog /tmp/iotracer/"${testname}")
  fi
  assert "echo ${prof_output}" ""

  rm -f /tmp/iotracer/"${testname}"
  unmonitor_file "${vm_image}"
  domain_exec_cmd "${GUEST_NAME}" "rm ${testname}.bin"

  assert_end "${testname}"
done

# Unload iotracer module
unload_iotracer

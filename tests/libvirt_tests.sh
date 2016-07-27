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
  echo "Usage: $0 vm_directory_path"
  echo "where vm_directory path is the path where to install VM images"
  exit 3
}

if [ $# -lt 1 ]; then
  show_usage
fi

#== global variables 

IOTRACER_PATH=$(readlink -e "$(dirname "$0")/..")

VM_DIR=$1

BASE_IMG=iotracer-debian-8.3.0.qcow2
WORKLOAD="dd if=/dev/urandom of=random.bin oflag=dsync bs=8k count=100 status=none"

#== functions ==

# function clear_cache
. "${IOTRACER_PATH}"/scripts/cache_func.sh

# iotracer wrapper functions
. "${IOTRACER_PATH}"/scripts/iotracer_func.sh

# functions to manage libvirt domains
. "${IOTRACER_PATH}"/scripts/libvirt_func.sh

# load framework tests
. "${IOTRACER_PATH}"/tests/assert.sh

assert_file_accessed_only_by_pid() {
  local proc_dir=$(monitored_file_procdir "$1")
  local pid=$2

  nb_events=$(awk '{print $4}' "${proc_dir}"/control)
  assert_raises "test ${nb_events} -gt 0" 0
  assert "awk -F\; -v pid=\"${pid}\" '\$7==pid' \"${proc_dir}\"/log | wc -l" \
         "${nb_events}"
}

#== Tests

# Install base image
[ -f "${VM_DIR}/${BASE_IMG}" ] || install_debian_image "${VM_DIR}/${BASE_IMG}"
if [ $? -ne 0 ]; then
  echo "Failed to setup test environment" && exit 1
fi

# Load iotracer module
load_iotracer
if [ $? -ne 0 ]; then
  echo "Failed to load kernel module" && exit 1
fi

_assert_reset

for domain in iotracer_tests_1 iotracer_tests_2; do
  # Create VM
  create_image_and_domain ${domain} "${VM_DIR}/${BASE_IMG}"
  if [ $? -ne 0 ]; then
    echo "Failed to create domain ${domain}" && exit 1
  fi
  
  # Start monitoring of domain images
  monitor_file "${VM_DIR}/${BASE_IMG}" 1000
  monitor_file "${VM_DIR}/${domain}.qcow2" 1000

  clear_cache
  domain_exec_cmd "${domain}" "${WORKLOAD}"
  clear_cache

  # Check that qemu pid is not the same for all domains
  if [ -n "${domain_pid}" ]; then
    previous_domain_pid=${domain_pid}
  fi
  domain_pid=$(domain_qemu_pid "${domain}")
  if [ -n "${previous_domain_pid}" ]; then
    assert_raises "test ${previous_domain_pid} != ${domain_pid}" 0
  fi

  # Check that all access to base image are read access
  check_file_log_contains_only_read "${VM_DIR}/${BASE_IMG}"
  assert "echo $?" "0"

  # Check that for each event in log correspond to domain pid
  assert_file_accessed_only_by_pid "${VM_DIR}/${BASE_IMG}" "${domain_pid}"
  assert_file_accessed_only_by_pid "${VM_DIR}/${domain}.qcow2" "${domain_pid}"

  unmonitor_file "${VM_DIR}/${BASE_IMG}"
  unmonitor_file "${VM_DIR}/${domain}.qcow2"

  destroy_domain_and_image "${domain}"
  
  assert_end "test_${domain}"
done

# Unload iotracer module
unload_iotracer

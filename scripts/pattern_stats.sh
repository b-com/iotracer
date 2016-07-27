#!/bin/sh
#/*!**************************************************************
#* \copyright (C) Copyright 2015-2016 b<>com
#* This program is free software; you can redistribute it and/or
#* modify it under the terms of the GNU General Public Licence
#* as published by the Free Software Foundation; either version
#* 2 of the Licence, or (at your option) any later version.
#***************************************************************/

show_usage() {
    echo "Usage: $0 [OPTION]... domain"
    echo
    echo "Options:"
    echo "  -c nb_executions    Specify number of execution of each pattern (default: 20)"
    echo "  -s size             Specify workload size (default: 700M)"
    echo "  -u user             Specify guest's user name"
    echo "  -p password         Specify guest's user password"
    echo "  -b                  Save blktrace log"
    exit 3
}

fdate() {
    date +"w%V d%w - %T"
}

IOTRACER_PATH=$(readlink -e "$(dirname "$0")/..")

io_profile="${IOTRACER_PATH}"/tests/io_profile.py

# function clear_cache
. "${IOTRACER_PATH}"/scripts/cache_func.sh
 
# iotracer wrapper functions
. "${IOTRACER_PATH}"/scripts/iotracer_func.sh

# functions to manage libvirt domains
. "${IOTRACER_PATH}"/scripts/libvirt_func.sh

# Parse arguments

nb_exec=20
size="700M"
user=debian
password="IOTracer"
blktrace_log=off

while getopts c:s:u:p:b opt
do
    case "$opt" in
      c)  nb_exec=${OPTARG};;
      s)  size="$OPTARG";;
      u)  user="$OPTARG";;
      p)  password="$OPTARG";;
      b)  blktrace_log=on;;
      \?) # unknown flag
          echo >&2 \
          show_usage;;
    esac
done
shift $(( OPTIND - 1 ))

if [ $# -lt 1 ]; then
    show_usage
fi

# Get path of domain's image

vm_image=$(domain_to_image "$1")
if [ -z "${vm_image}" ]; then
    echo "Failed to get image for domain $1"
    exit 2
fi

# Get domain's IP address

ip_addr=$(domain_ip_address "$1")
if [ -z "${ip_addr}" ]; then
    echo "Failed to get IP address for domain $1"
    exit 2
fi

# exec_on_guest <command>
# execute a command on the guest
exec_on_guest() {
    sshpass -p "${password}" \
      ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no \
        "${user}@${ip_addr}" "$@"
}

# copy_on_guest <host_path> <guest_path>
# copy a file from the host to the guest
copy_on_guest() {
    sshpass -p "${password}" \
      scp -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no \
        "$1" "${user}@${ip_addr}:$2"
}

# copy_from_guest <guest_path> <host_path>
# copy a file from the guest to the host
copy_from_guest() {
    sshpass -p "${password}" \
      scp -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no \
        "${user}@${ip_addr}:$1" "$2"
}

# Load iotracer module
load_iotracer

# Install workload script in guest
copy_on_guest "${IOTRACER_PATH}"/scripts/workload.sh "/home/${user}/"

for pattern in write read rw randwrite randread randrw; do
    mkdir -p ${pattern}/log
    if [ "${blktrace_log}" = "on" ]; then
        mkdir ${pattern}/log/blktrace
    fi
    clear_cache
    exec_on_guest ./workload.sh create ${pattern} "${size}"
    sync
    copy_from_guest "/home/${user}/${pattern}.iolog" "${pattern}/"

    sudo dmesg -c > /dev/null

    # Start monitoring of VM image
    for i in $(seq -w 1 "${nb_exec}"); do
        echo "$(fdate) - execution ${i} of ${pattern}..."
        clear_cache
        monitor_file "${vm_image}" 1000000
        if [ "${blktrace_log}" = "on" ]; then
            bdev=$(file_to_bdev "${vm_image}")
            sudo blktrace -d /dev/"${bdev}" -D "${pattern}/log/blktrace" -o "exec_${pattern}_${i}" &
        fi
        exec_on_guest ./workload.sh exec ${pattern}
        sleep $(( $(cat /proc/sys/vm/dirty_expire_centisecs) / 100 ))
        sync
        cat "$(monitored_file_procdir "${vm_image}")"/control > "${pattern}/log/exec_${i}".control
        cat "$(monitored_file_procdir "${vm_image}")"/log > "${pattern}/log/exec_${i}".log
        unmonitor_file "${vm_image}"
        sudo dmesg -c | grep -v usb > "${pattern}/kernel_${i}".log
        if [ "${blktrace_log}" = "on" ]; then
            sudo killall -s 2 blktrace
        fi
        "${io_profile}" log "${pattern}/log/exec_${i}".log >> "${pattern}/exec_${i}".log
    done;
    exec_on_guest "rm ${pattern}.*"
done

exec_on_guest rm workload.sh

# Unload iotracer module
unload_iotracer

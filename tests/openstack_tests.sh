#!/bin/sh
#/*!**************************************************************
#* \copyright (C) Copyright 2015-2016 b<>com
#* \brief     Integration tests of the iotracer kernel module using libvirt
#* This program is free software; you can redistribute it and/or
#* modify it under the terms of the GNU General Public Licence
#* as published by the Free Software Foundation; either version
#* 2 of the Licence, or (at your option) any later version.
#***************************************************************/

export LANG=C

show_usage() {
    echo "Usage: $0 [OPTION]... controller_ip instance"
    echo
    echo "Options:"
    echo "  -c nb_executions    Specify number of execution of each pattern (default: 20)"
    echo "  -s size             Specify workload size (default: 700M)"
    echo "  -u user             Specify guest's user name"
    echo "  -i identity         Specify file from which the identity (private key)"
    echo "                      for public key authentication to the guest is read"
    echo "  -l login            Specify compute's login name"
    echo "  -p password         Specify compute's password"
    exit 3
}

IOTRACER_PATH=$(readlink -e "$(dirname "$0")/..")

io_profile="${IOTRACER_PATH}"/tests/io_profile.py

# Parse arguments

nb_exec=20
user=debian
size="700M"
user="debian"
identity=""
login="FIX_ME_LOGIN"
password="PASSWORD"

while getopts c:s:u:i:l:p: opt
do
    case "$opt" in
      c) nb_exec=${OPTARG};;
      s) size="$OPTARG";;
      u) user="$OPTARG";;
      i) identity="$OPTARG";;
      l) login="$OPTARG";;
      p) password="$OPTARG";;
      \?) # unknown flag
          echo >&2 \
          show_usage;;
    esac
done
shift $(( OPTIND - 1 ))

if [ -n "${identity}" ]; then
    GUEST_SCP="scp -i ${identity}"
else
    GUEST_SCP="scp"
fi

if [ $# -lt 2 ]; then
    show_usage
fi

controller_ip="$1"
instance_name="$2"

# Define useful functions

. "${IOTRACER_PATH}"/scripts/cache_func.sh

fdate() {
    date +"w%V d%w - %T"
}

# exec_on_host <host ip> <command>
# exec a shell command on host
exec_on_host() {
    local host_ip="$1"
    local cmd="$2"

    sshpass -p "${password}" \
      ssh -o \
        ProxyCommand="sshpass -p \"${password}\" ssh %r@${controller_ip} nc %h %p" \
        "${login}@${host_ip}" "${cmd}"
}

# exec_on_guest <instance id> <command>
# exec a shell command on guest
exec_on_guest() {
    if [ -n "${identity}" ]; then
        nova ssh --login "${user}" --identity "${identity}" --extra-opts \""$2"\" "$1"
    else
        nova ssh --login "${user}" --extra-opts \""$2"\" "$1"
    fi
}

# Check requirements

for pkg in sshpass python3-novaclient python3-openstackclient; do
    if [ "$(dpkg-query -l ${pkg} 2> /dev/null | awk -v pkg="${pkg}" '$2 == pkg { print $1 }')" != "ii" ]; then
        echo "${pkg} must be installed !"
        exit 1
    fi
done

if [ -z "${OS_AUTH_URL}" ]; then
    echo "Openstack authentication URL must be set: Set OS_AUTH_URL"
    exit 1
fi

if [ -z "${OS_USERNAME}" -o -z "${OS_PASSWORD}" ]; then
    echo "Openstack credentials must be set: Set OS_USERNAME and OS_PASSWORD"
    exit 1
fi

if [ -z "${OS_PROJECT_NAME}" ]; then
    echo "Openstack project scope must be set: Set OS_PROJECT_NAME"
    exit 1
fi

# Get Id of instance

instance=$(openstack server list -f=csv --quote=minimal --name="${instance_name}" | awk -F, -v name="${instance_name}" '$2==name {print $1}')
if [ -z "${instance}" ]; then
    echo "no instance named '${instance_name}!"
    exit 1
fi

# Check status of instance

status=$(openstack server show -f=value -c=status "${instance}")
if [ "${status}" != "ACTIVE" ]; then
    echo "instance is not active (status = ${status})"
    exit 1
fi

# Get VM instance name

vm_name=$(openstack server show -f=value -c=OS-EXT-SRV-ATTR:instance_name "${instance}")
if [ -z "${vm_name}" ]; then
    echo "failed to get instance_name attribute"
    exit 1
fi

# Get host IP address

hypervisor=$(openstack server show -f=value -c=OS-EXT-SRV-ATTR:hypervisor_hostname "${instance}")
if [ -z "${hypervisor}" ]; then
    echo "failed to get hypervisor_hostname attribute"
    exit 1
fi

host_ip=$(openstack hypervisor show -f=value -c=host_ip "${hypervisor}")
if [ -z "${host_ip}" ]; then
    echo "failed to get host IP address"
    exit 1
fi

# Get image file path\'
vm_image=$(exec_on_host "${host_ip}" "virsh domblklist ${vm_name}" | awk '$1=="vda" {print $2}')

# Get base image path
base_image=$(exec_on_host "${host_ip}" "qemu-img info ${vm_image}" | awk -F: '$1=="backing file" {print $2}' | xargs)

# Get guest IP address
vm_ip=$(nova floating-ip-list | awk -F\| -vinstance=" ${instance} " '$4==instance {print $3}' | xargs)
if [ -z "${vm_ip}" ]; then
    echo "failed to get VM IP address"
    exit 1
fi

# Install workload script in guest
"${GUEST_SCP}" "${IOTRACER_PATH}"/scripts/workload.sh "${user}@${vm_ip}:/home/${user}"

# Install fio in guest
fio_status=$(exec_on_guest "${instance}" "dpkg-query -l fio" | awk '$2=="fio" { print $1 }')
[ "${fio_status}" = "ii" ] || exec_on_guest "${instance}" "sudo apt-get -y install fio"

# Copy iotracer module source on host
exec_on_host "${host_ip}" "rm -fr iotracer"
# exec_on_host "${host_ip}" "git clone https://github.com/b-com/iotracer"
sshpass -p "${password}" \
  scp -o ProxyCommand="sshpass -p \"${password}\" ssh %r@${controller_ip} nc %h %p" \
      -r \
      "${IOTRACER_PATH}"/../iotracer "${login}@${host_ip}:/home/\"${login}\""/

# Build module
exec_on_host "${host_ip}" "make -C iotracer"

# Load iotracer module
exec_on_host "${host_ip}" "sh iotracer/scripts/iotracer_func.sh load_iotracer"

for pattern in write read rw randwrite randread randrw; do
    mkdir -p ${pattern}/log

    exec_on_guest "${instance}" "./workload.sh create \"${pattern}\" \"${size}\" && sync"
    "${GUEST_SCP}" "${user}@${vm_ip}:/home/${user}/${pattern}.iolog" "${pattern}/"

    # Start monitoring of VM image
    for i in $(seq -w 1 "${nb_exec}"); do
        echo "$(fdate) - execution ${i} of ${pattern}..."
        exec_on_host "${host_ip}" "source iotracer/scripts/cache_func.sh && clear_cache"
        exec_on_host "${host_ip}" \
          "sh iotracer/scripts/iotracer_func.sh monitor_file \"${vm_image}\" 1000000"
        exec_on_host "${host_ip}" \
          "sh iotracer/scripts/iotracer_func.sh monitor_file \"${base_image}\" 1000000"
        exec_on_guest "${instance}" "./workload.sh exec ${pattern}"
        delay=$(exec_on_host "${host_ip}" "cat /proc/sys/vm/dirty_expire_centisecs")
        sleep $(( delay / 100 ))
        exec_on_host "${host_ip}" "sync"
        exec_on_host "${host_ip}" \
          "cat \"\$(sh iotracer/scripts/iotracer_func.sh monitored_file_procdir \"${vm_image}\")\"/control" > "${pattern}/log/exec_${i}_vm_image.control"
        exec_on_host "${host_ip}" \
          "cat \"\$(sh iotracer/scripts/iotracer_func.sh monitored_file_procdir \"${vm_image}\")\"/log" > "${pattern}/log/exec_${i}_vm_image.log"
        exec_on_host "${host_ip}" \
          "cat \"\$(sh iotracer/scripts/iotracer_func.sh monitored_file_procdir \"${base_image}\")\"/control" > "${pattern}/log/exec_${i}_base_image.control"
        exec_on_host "${host_ip}" \
          "cat \"\$(sh iotracer/scripts/iotracer_func.sh monitored_file_procdir \"${base_image}\")\"/log" > "${pattern}/log/exec_${i}_base_image.log"
        exec_on_host "${host_ip}" \
          "sh iotracer/scripts/iotracer_func.sh unmonitor_file \"${vm_image}\""
        exec_on_host "${host_ip}" \
          "sh iotracer/scripts/iotracer_func.sh unmonitor_file \"${base_image}\""
        "${io_profile}" log "${pattern}/log/exec_${i}_vm_image.log" >> "${pattern}/exec_${i}_vm_image.log"
        "${io_profile}" log "${pattern}/log/exec_${i}_base_image.log" >> "${pattern}/exec_${i}_base_image.log"
    done;
    exec_on_guest "${instance}" "rm ${pattern}.*"
done

exec_on_guest "${instance}" " rm workload.sh"

# Unload iotracer module
exec_on_host "${host_ip}" "sh iotracer/scripts/iotracer_func.sh unload_iotracer"

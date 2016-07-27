#/*!**************************************************************
#* \copyright (C) Copyright 2015-2016 b<>com
#* This program is free software; you can redistribute it and/or
#* modify it under the terms of the GNU General Public Licence
#* as published by the Free Software Foundation; either version
#* 2 of the Licence, or (at your option) any later version.
#***************************************************************/

BASE_IMG_SRC=http://cdimage.debian.org/cdimage/openstack/archive/8.3.0/debian-8.3.0-openstack-amd64.qcow2
OS_VARIANT=debianwheezy

GUEST_USER=debian
GUEST_PASSWORD="IOTracer"

export LANG=C 

# domain_to_image <domain>
# return path to image used by a domain
domain_to_image() {
    virsh domblklist "$1" | awk '$1=="vda" {print $2}'
}

# domain_ip_address <domain>
# return IP address of a domain
domain_ip_address() {
  local domain="$1"
    
  network=$(virsh net-list | awk '$2=="active" { print $1 }')
  bridge=$(virsh net-info "${network}" | awk '$1=="Bridge:" { print $2 }')
  mac_addr=$(virsh domiflist "${domain}"  | awk '$2=="network" { print $5 }')
  arp -ani "${bridge}" | awk -v mac="${mac_addr}" '$4==mac { print substr($2,2,length($2)-2) }'
}

# domain_qemu_pid <domain>
# return pid of qemu process corresponding to a domain
domain_qemu_pid() {
  sudo cat /var/run/libvirt/qemu/"$1".pid
}

# domain_exec_cmd <domain> <command>
# execute a command on a domain
domain_exec_cmd() {
  local domain="$1"
  local command="$2"
  local ip_addr=$(domain_ip_address "${domain}")

  sshpass -p "${GUEST_PASSWORD}" \
    ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no \
      "${GUEST_USER}@${ip_addr}" "${command}"
}

# wait_domain_ssh_ready <domain>
wait_domain_ssh_ready() {
  local domain="$1"

  local nb_retry=0

  local domain_ip_addr=$(domain_ip_address "${domain}")
  while [ -z "${domain_ip_addr}" -a ${nb_retry} -lt 60 ]; do
    sleep 1
    domain_ip_addr=$(domain_ip_address "${domain}")
    nb_retry=$(( nb_retry + 1 ))
  done
  if [ -z "${domain_ip_addr}" ]; then
    echo "Failed to get IP address for domain ${domain}" && return 1
  fi

  nb_retry=0
  local ssh_status=$(nmap -PN -p ssh "${domain_ip_addr}" | awk '$3=="ssh" {print $2}')
  while [ "${ssh_status}" != "open" -a ${nb_retry} -lt 60 ]; do
    sleep 1
    ssh_status=$(nmap -PN -p ssh "${domain_ip_addr}" | awk '$3=="ssh" {print $2}')
    nb_retry=$(( nb_retry + 1 ))
  done
  if [ "${ssh_status}" != "open" ]; then
    echo "SSH server not available on domain ${domain}" && return 1
  fi
  
  nb_retry=0
  domain_exec_cmd "${domain}" /bin/true
  while [ $? -ne 0 -a ${nb_retry} -lt 30 ]; do
    sleep 1
    nb_retry=$(( nb_retry + 1 ))
    domain_exec_cmd "${domain}" /bin/true
  done
  if [ $? -ne 0  ]; then
    echo "SSH server not ready on domain ${domain}" && return 1
  fi
}

# install_debian_image <image>
# Create and prepare a new Dabian qcow2 disk image that can be used by Libvirt-KVM
install_debian_image() {
  local image="$1"

  local installation_ok=0

  wget -O "${image}" "${BASE_IMG_SRC}"
  if [ $? -ne 0 ]; then
    echo "Failed to download image" && return 1
  fi

  [ -r "/boot/vmlinuz-$(uname -r)" ] || sudo chmod +r "/boot/vmlinuz-$(uname -r)"
  virt-sysprep -a "${image}" --format qcow2 --enable customize \
    --hostname "$(basename -s .qcow2 "${image}")" \
    --password "${GUEST_USER}:password:${GUEST_PASSWORD}" \
    --run-command "apt-get -y remove cloud-init" \
    --firstboot-command "dpkg-reconfigure openssh-server"
  installation_ok=$?
  if [ "${installation_ok}" -ne 0 ]; then
    echo "Failed to customise image"    
  fi
 
  if [ "${installation_ok}" -ne 0 ]; then
    rm -f "${image}"
  fi
  return "${installation_ok}"
}


# create_domain <image> [cache_mode]
# Create a new domain using an existing qcow2 image
create_domain() {
  local image="$1"
  if [ $# -lt 2 ]; then
    local cache_mode=none
  else
    local cache_mode="$2"
  fi

  local domain="$(basename -s .qcow2 "${image}")"

  virt-install --quiet --connect qemu:///system \
    --os-type=linux --os-variant="${OS_VARIANT}"\
    --disk path="${image},device=disk,format=qcow2,cache=${cache_mode}" \
    --name "${domain}" \
    --vcpus=2 --ram 1024 --graphics none --noautoconsole --import
  if [ $? -ne 0 ]; then
    echo "Failed to install domain ${domain}" && return 1
  fi

  # Wait VM is ready to accept ssh connection
  wait_domain_ssh_ready "${domain}"
}

# create_image_and_domain <domain> <base_image> [cache_mode]
# Create a new image using an existing qcow2 base image
# and create a domain using this image
create_image_and_domain() {
  local domain="$1"
  local base_image="$2"

  local domain_image="$(dirname "${base_image}")/${domain}.qcow2"

  qemu-img create -q -f qcow2 -o backing_file="${base_image}" "${domain_image}"
  if [ $? -eq 0 ]; then
    if [ $# -lt 3 ]; then
      create_domain "${domain_image}"
    else
      create_domain "${domain_image}" "$3"
    fi
    if [ $? -ne 0 ]; then
      sudo rm -f "${domain_image}"
      return 1
    fi
  fi
}

# destroy_domain <domain>
destroy_domain() {
  local domain=$1

  virsh --quiet shutdown "${domain}"
  local nb_retry=0
  local state=$(virsh domstate "${domain}")
  while [ "${state}" != "shut off" -a ${nb_retry} -lt 30 ]; do
    sleep 1
    nb_retry=$(( nb_retry + 1 ))
    state=$(virsh domstate "${domain}")
  done
  if [ "${state}" != "shut off" ]; then
    echo "Failed to shutdown ${domain}. Killing it..."
    sudo kill "$(domain_qemu_pid "${domain}")"
  fi
  virsh --quiet undefine "${domain}"
}

# destroy_domain_and_image <domain>
destroy_domain_and_image() {
  local domain=$1
  local image=$(domain_to_image "${domain}")

  destroy_domain "${domain}"
  sudo rm -f "${image}"
}

# Install packages required to use functions defined in this script
install_libvirt_kvm() {
  local packages_to_install=""
  for pkg in qemu-kvm libvirt-bin virtinst nmap sshpass; do
    pkg_status=$(dpkg-query -l "${pkg}" | awk -v pkg="${pkg}" '$2 == pkg { print $1 }')
    if [ "${pkg_status}" != "ii" ]; then
      packages_to_install="${packages_to_install} ${pkg}"
    fi
  done
  # we need virt-sysprep 1.26 or greater
  pkg_status=$(dpkg-query -l libguestfs-tools | awk '$2 == "libguestfs-tools" { print $1 }')
  if [ "${pkg_status}" != "ii" ]; then
    packages_to_install="${packages_to_install} libguestfs-tools"
  else
    pkg_version=$(virt-sysprep --version | awk '{ print $2 }')
    pkg__major=$(echo "${pkg_version}" | cut -d. -f1)
    pkg__minor=$(echo "${pkg_version}" | cut -d. -f2)
    if [ "${pkg__major}" -lt 1 -o \
         \( "${pkg__major}" -eq 1 -a "${pkg__minor}" -lt 26 \) ]; then
      sudo add-apt-repository -y ppa:yantarou/libguestfs
      packages_to_install="${packages_to_install} libguestfs-tools"
    fi
  fi
  if [ -n "${packages_to_install}" ]; then
    sudo apt-get -q update
    echo "${packages_to_install}" | xargs sudo apt-get -q -y install
  fi
}


install_libvirt_kvm || exit 1

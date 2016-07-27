#!/bin/sh
#/*!**************************************************************
#* \copyright (C) Copyright 2015-2016 b<>com
#* This program is free software; you can redistribute it and/or
#* modify it under the terms of the GNU General Public Licence
#* as published by the Free Software Foundation; either version
#* 2 of the Licence, or (at your option) any later version.
#***************************************************************/

if [ $# -lt 1 ]; then
  echo Usage: "$(basename "$0")" vm_name
  exit 1
fi

VM_NAME="$1"

qemu-img create "${VM_NAME}.img" 2G
mkfs.ext4 -F "${VM_NAME}.img"
sudo mkdir -p "/mnt/${VM_NAME}"
sudo mount -o loop "${VM_NAME}.img" "/mnt/${VM_NAME}"
sudo debootstrap trusty "/mnt/${VM_NAME}" http://fr.archive.ubuntu.com/ubuntu
sudo cp "$(dirname "$0")/install-vm.sh" "/mnt/${VM_NAME}/install-vm.sh"
sudo LANG=C.UTF-8 chroot "/mnt/${VM_NAME}" /bin/bash /install-vm.sh
sudo umount "/mnt/${VM_NAME}"
sudo rmdir "/mnt/${VM_NAME}"

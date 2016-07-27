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
TEST_IMG="$1.img"

if [ $# -gt 1 ]; then
  KERNEL_VERSION="$2"
else
  KERNEL_VERSION="$(uname -r)"
fi

IOTRACER_MODULE_DIR="$(readlink -f "$(dirname "$(readlink -f "$0")")/..")"

sudo apt-get -y install "linux-image-${KERNEL_VERSION}"
sudo chmod +r "/boot/vmlinuz-${KERNEL_VERSION}" "/boot/initrd.img-${KERNEL_VERSION}"

kvm -m 1G -hda "${TEST_IMG}" -name "iotracer_test_linux-${KERNEL_VERSION}" -smp 2 -fsdev local,id=iotracer_src_dev,path="${IOTRACER_MODULE_DIR}",security_model=none -device virtio-9p-pci,fsdev=iotracer_src_dev,mount_tag=iotracer_src -kernel "/boot/vmlinuz-${KERNEL_VERSION}" -initrd "/boot/initrd.img-${KERNEL_VERSION}" -append "root=/dev/sda" -curses -redir tcp:2222::22

#!/bin/sh
#/*!**************************************************************
#* \copyright (C) Copyright 2015-2016 b<>com
#* This program is free software; you can redistribute it and/or
#* modify it under the terms of the GNU General Public Licence
#* as published by the Free Software Foundation; either version
#* 2 of the Licence, or (at your option) any later version.
#***************************************************************/

echo "installing VM"
echo "- Add useful aptitude repositories"
cat << EOT >> /etc/apt/sources.list
deb http://fr.archive.ubuntu.com/ubuntu trusty-updates main
deb http://security.ubuntu.com/ubuntu trusty-security main
deb http://fr.archive.ubuntu.com/ubuntu trusty universe
deb http://fr.archive.ubuntu.com/ubuntu trusty-updates universe
deb http://security.ubuntu.com/ubuntu trusty-security universe
EOT
echo "- Populate /dev"
mount none /proc -t proc
apt-get update
apt-get -y install makedev
if [ $? -eq 0 ]; then
    cd /dev
    MAKEDEV generic
    echo "- Configure /etc/fstab"
    cat << EOT > /etc/fstab
# /etc/fstab: static file system information.
#
# file system    mount point   type    options                  dump pass
/dev/sda         /             ext4    defaults                 0    1

proc             /proc         proc    defaults                 0    0
sysfs            /sys          sysfs   defaults                 0    0

EOT
    echo "- Initialise root password"
    sed -i 's/root:!:/root::/g' /etc/shadow*
    echo "root:iotracer" | chpasswd
    echo "- Enable text-only mode"
    echo blacklist vga16fb >> /etc/modprobe.d/blacklist-framebuffer.conf
    echo "- Configure network"
    cat << EOT >> /etc/network/interfaces
auto eth0
iface eth0 inet dhcp

EOT
    echo "# Workaround for sudo" >> /etc/hosts
    echo "127.0.1.1    $(/bin/hostname)" >> /etc/hosts
    echo "- Configure ssh"
    apt-get -y install ssh
    if [ $? -eq 0 ]; then
        sed -i 's/PermitRootLogin without-password/PermitRootLogin yes/g' /etc/ssh/sshd_config
        echo "- Install development tools"
        apt-get -y install build-essential git bc fio
    fi
fi
umount /proc
exit

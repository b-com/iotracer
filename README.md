# I/O Tracer kernel module

## Introduction

The I/O tracer kernel module is based on Jprobes. It probes kernel functions that generate disk I/O to log I/O access at various levels
(block, VFS) of [the Linux storage stack](https://upload.wikimedia.org/wikipedia/commons/3/30/IO_stack_of_the_Linux_kernel.svg).

I/O Tracer Module is an open source software (GNU Public License v2)

This module requires that kernel is compiled with `CONFIG_KPROBES` and `CONFIG_KALLSYMS` options set in kernel configuration. Even if this is the case in many Linux distributions, a cloud provider may disable these options (for security reasons for example).

If they are not set, you need to build your own kernel (see [KernelBuild](http://kernelnewbies.org/KernelBuild) on kernelnewbies.org).

The following Linux operating systems (and kernel versions) have been
tested:
-   Ubuntu 14.04 kernel 3.16
-   Ubuntu 14.04 kernel 3.19
-   Ubuntu 14.04 kernel 4.2

Note: This list should not be considered complete and exclusive. The module may work on Linux operating systems and kernels that do not appear on this list. But it will not work on system using kernel version prior to version 3.16 (as the module probes generic_file_read_iter and __generic_file_write_iter functions that were introduced in this version). 

The following filesystems have been tested:
-   EXT4/EXT2 (with and without LVM)

The following format of the images have been tested:
-   QCOW2
-   RAW

## Development environment on Ubuntu 14.04

Development environment use Git and Ubuntu 14.04 KVM/QEMU virtual machines.

User must have root access to the development machine. 

### Install Requirements for Ubuntu Linux  

Linux Debian Procedure should work on Ubuntu and similar distributions.

Install appropriate packages:
```
sudo apt-get install build-essential git qemu qemu-kvm libvirt-bin debootstrap linux-image-3.16.0-53-generic
```


#### Get the source code

To clone source code from gerrit use the following command: 
```
git clone https://github.com/b-com/iotracer.git
```

####  Create the Development Virtual Machine

To create the VM that will be used to do unitary tests of the module use the script create-vm.sh : 
````
ubuntu@bebop:/mnt/dev/iotracer$ scripts/create-vm.sh my-vm
````

#### Start the Virtual Machine

The current version of the module is known to work with kernel versions 3.16.X, 3.19.X and 4.2.X but it does not build with version 3.13.X.

The kernel must be configured with procfs,Kallsysm and kprobes support. In most Linux distributions the kernel is configured with these options activated.

To use the following command you need to have read access to kernel image and initrd files in /boot.

To start the VM use the script start-vm.sh: 
````
ubuntu@bebop:/mnt/dev/iotracer$ scripts/start-vm.sh testu-vm 3.16.0-53-generic
````

#### Build the module

##### Log to the VM as root (password: iotracer) 
````
ssh -p 2222 root@localhost
````

##### Mount iotracer_kernel_module directory in VM: 
```
root@bebop:~# [ ! -d /lib/modules/$(uname -r) ] && apt-get -y install linux-image-$(uname -r) && udevadm trigger
root@bebop:~# mkdir -p /mnt/iotracer_src
root@bebop:~# mount -t 9p -o trans=virtio,version=9p2000.L,posixacl,cache=loose iotracer_src /mnt/iotrace
```

##### Install required kernel headers: 
```
ubuntu@bebop:~# sudo apt-get -y install linux-headers-$(uname -r)
```

##### Build the module: 
```
ubuntu@bebop:~# cd /mnt/iotracer_src/src
ubuntu@bebop:/mnt/iotracer_src/src# make clean ; make
```

#### Test the module

##### Basic tests 

```
ubuntu@bebop:~# sudo insmod /mnt/iotracer_src/iotracer.ko MAX_EVENTS=100
ubuntu@bebop:~# lsmod | grep iotracer
iotracer            20480  0 
ubuntu@bebop:~# rm -f /tmp/iotracer_test_file && touch /tmp/iotracer_test_file
ubuntu@bebop:~# echo add /tmp/iotracer_test_file > /proc/iotracer/control
ubuntu@bebop:~# cat /proc/iotracer/control
sda_83420 /tmp/iotracer_test_file
ubuntu@bebop:~# cat /proc/iotracer/sda_83420/control 
1 364.358689497 100 0
ubuntu@bebop:~# dd if=/dev/urandom of=/tmp/iotracer_test_file bs=8k count=10000
10000+0 records in
10000+0 records out
81920000 bytes (82 MB) copied, 3.36968 s, 24.3 MB/s
ubuntu@bebop:~# cat /proc/iotracer/sda_83420/control 
1 364.358689497 100 100
ubuntu@bebop:~# cat /proc/iotracer/sda_83420/log
86.525308709;W;3547136;524288;BLK;dd;1847
86.525355240;W;3548160;524288;BLK;dd;1847
86.525383215;W;3549184;524288;BLK;dd;1847
...
ubuntu@bebop:~# echo remove /tmp/iotracer_test_file > /proc/iotracer/control
ubuntu@bebop:~# cat /proc/iotracer/control
ubuntu@bebop:~# sudo rmmod iotracer
```

##### Unitary tests

Unitary tests can be done using script module_interface_tests.sh: 
```
ubuntu@bebop:~# cd /mnt/iotracer_src/tests
ubuntu@bebop:/mnt/iotracer_src/tests# ./module_interface_tests.sh
```

##### Basic profile recognition test

Script profile_ident_tests.py check that the module correctly identifies sequential/random reads/writes profiles

```
ubuntu@bebop:~# sudo insmod /mnt/iotracer_src/src/iotracer.ko
ubuntu@bebop:~# /mnt/iotracer_src/tests/profile_ident_tests.py
execute sequential write test for libaio...
execute random write test for libaio...
execute sequential read test for libaio...
execute random read test for libaio...
execute sequential write test for posixaio...
execute random write test for posixaio...
execute sequential read test for posixaio...
execute random read test for posixaio...
execute sequential write test for sync...
execute random write test for sync...
execute sequential read test for sync...
execute random read test for sync...
execute sequential write test for psync...
execute random write test for psync...
execute sequential read test for psync...
execute random read test for psync...
execute sequential write test for vsync...
execute random write test for vsync...
execute sequential read test for vsync...
execute random read test for vsync...
execute sequential write test for pvsync...
execute random write test for pvsync...
execute sequential read test for pvsync...
execute random read test for pvsync...
.
----------------------------------------------------------------------
Ran 1 test in 188.633s

OK
ubuntu@bebop:~# sudo rmmod iotracer
```


This test create two files in /tmp directory, each one taking 40% of available space in the corresponding partition. One file is used to perform sequential access and the other to perform random access.

fio is used to write and read this file using various IO engine (libaio, posixaio, sync, psync, vsync and pvsync). 

#### Interface of the module 

##### Module parameters

 MAX_EVENTS : default value for maximal number of IO events to log (default = 10) 

###### Interface in procfs

To monitor a new file use: 
```
echo add <filename> [max_events] > /proc/iotracer/control
```

This will create a subdirectory in /proc/iotracer to handle I/O traces regarding this file. The following command returns the name of this directory: 
```
awk -vf="<filename>" '$0~f {print $1}' /proc/iotracer/control
```

To remove a file from the list use: 
```
echo remove <filename> > /proc/iotracer/control
```

List files that are monitored :
```
/proc/iotracer/control 
```

List the IO events corresponding to inode <inode> from block device <bdev>.
```
/proc/iotracer/<bdev>_<inode>/log 
```

Each line is in the form: 
```
<timestamp>;<access type>;<address>;<accessed data size>;<access level>;<name of the process making the access>;<PID of the process making the access>
```
Where :

    timestamp : is the elapsed time (in seconds) since the tracing was enabled
    access type : indicates whether it is Read or Write access event
    address : block address for a block, address in the file for VFS
    access level : block or VFS 
    
Here is a real sample of traced events:
```
61633.318652058;R;1879048192;16384;VFS;ATA-0;14272
61633.318663395;R;21282816;16384;BLK;ATA-0;14272
61633.320542604;R;1880104960;65536;VFS;ATA-0;14272
```

/proc/iotracer/<bdev>_<inode>/control 

Give status of the log corresponding to inode <inode> from block device <bdev>:
```
<status> <T0> <max_events> <nb_events>
```

This file can be used to control log behavior by writing a command to it.

The allowed commands are:

    stop : stop log of events
    start : restart log of events
    reset : remove all events from log
    timereset : remove all events from log and reinitialize T0 

#### Functional Tests


##### Monitoring of Virtual Machines

Script pattern_stats.sh has been used to test monitoring of Virtual Machines by the IO-Tracer kernel module while basic predefined I/O workload is executed in the VM.

The configuration of the host used is:

    Ubuntu Server 14.04.4 LTS,
    kernel 3.19,
    system on HDD,
    VM images stored on an isolated ext4 partition on SDD (the disk is used by anything else). 

The configuration of the VM used are:

    Libvirt KVM hypervisor (default configuration for NOVA Compute node),
    QCOW2 image (default configuration for NOVA Compute),
    Debian 8.3 (Jessie) from http://cdimage.debian.org/cdimage/openstack/8.3.0/debian-8.3.0-openstack-amd64.qcow2,
    KVM configured to used virtio disk,
    KVM configured to use cache mode none, writeback or writethrough depending on the VM. 

Cache mode directsync and unsafe was not used because version of virt-install available in Ubuntu 14.04 does not manage them and these modes might not be used in production (see http://rwmj.wordpress.com/2013/09/02/new-in-libguestfs-allow-cache-mode-to-be-selected/)).

Before executing a test, the image file of the VM used by the test is defragmented. This is done to avoid change of sequential/random aspect of the pattern at each level (VFS, BLK) due to fragmentation of the file.

During execution of the test, there is only one active VM: the one used by the test.

That is, to perform a test using libvirt domain iotracer-debian-cache_none, the following commands are executed: 
```
ubuntu@bebop:~/iotracer$ mkdir pattern_stats_none
ubuntu@bebop:~/iotracer$ cd pattern_stats_none
ubuntu@bebop:~/iotracer/pattern_stats_none$ source /home/indeed/iotracer/iotracer_kernel_module/scripts/libvirt_func.sh 
ubuntu@bebop:~/iotracer/pattern_stats_none$ e4defrag $(domain_to_image iotracer-debian-cache_none)
ubuntu@bebop:~/iotracer/pattern_stats_none$ virsh start iotracer-debian-cache_none
ubuntu@bebop:~/iotracer/pattern_stats_none$ /home/indeed/iotracer/iotracer_kernel_module/scripts/pattern_stats.sh -t vm_ext4_sdd_writethrough
ubuntu@bebop:~/iotracer/pattern_stats_none$ virsh shutdown iotracer-debian-cache_none
```


##  Publications

* Ouarnoughi, Hamza and Boukhobza, Jalil and Singhoff, Frank and Rubini, Stéphane, A Multilevel I/O Tracer for Timing and Performance Analysis of Storage Systems in IaaS Cloud, 3rd IEEE Real-Time and Distributed Computing in Emerging Applications (REACTION), 2014,Rome, Italy, Dec
 
obj-m += iotracer.o

iotracer-src  := $(wildcard *.c probes/*.c)
iotracer-objs := iotracer_module.o kprobes.o iotracer_log.o
iotracer-objs += probes/filemap_probes.o
iotracer-objs += probes/block_probes.o


KERN_VERSION ?= $(shell uname -r)

KERN_DIR=/lib/modules/$(KERN_VERSION)/build

build:
	$(MAKE) -C $(KERN_DIR) M=$(CURDIR) modules

clean:
	$(MAKE) -C $(KERN_DIR) M=$(CURDIR) clean

install:
	$(MAKE) -C $(KERN_DIR) M=$(CURDIR) modules_install
	/sbin/depmod $(KERN_VERSION)

codecheck:
	$(KERN_DIR)/scripts/checkpatch.pl --no-tree --no-summary -f Makefile *.[ch] probes/*.[ch]

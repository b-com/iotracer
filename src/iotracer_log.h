/*!**************************************************************
* \authors   Hamza Ouarnoughi, Jean-Emile DARTOIS, Nicolas Guyomard
* \copyright (C) Copyright 2015-2016 b<>com
*
* This program is free software; you can redistribute it and/or
* modify it under the terms of the GNU General Public Licence
* as published by the Free Software Foundation; either version
* 2 of the Licence, or (at your option) any later version.
***************************************************************/
/* The for logging the events in block device */

#ifndef IOTRACER_LOG_H
#define IOTRACER_LOG_H

#include <linux/types.h>
#include <linux/atomic.h>
#include <linux/sched.h>

/* Log events types */
#define IO_READ_EVENT  ('R')
#define IO_WRITE_EVENT ('W')
#define IO_EVENT_NONE  ('?')

extern unsigned int MAX_EVENTS;

/* Log events types */
enum access_level {
	VFS,
	FS,
	BLK
};

int iotracer_bdev_monitored(struct block_device *bdev);

int iotracer_inode_monitored(struct inode *inode);

/**
 * iotracer_insert_event - insert an I/O event in a log
 *
 * @event:   type of the I/O (read/write)
 * @level:   access level of the event (block/VFS)
 * @inode:   inode related to the i/O
 * @address: address of the I/O
 * @size:    size of the I/O
 *
 * This function must be called by the thread performing the I/O event
 */
void iotracer_insert_event(char event, enum access_level level,
		       struct inode *inode,
		       loff_t address, size_t size);

void iotracer_log_exit(void);

struct proc_dir_entry *iotracer_proc_create(struct proc_dir_entry *proc_dir);

#endif /* IOTRACER_LOG_H */

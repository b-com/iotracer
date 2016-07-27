/***************************************************************
* \authors   Jean-Emile DARTOIS, Hamza Ouarnoughi, Nicolas Guyomard
* \copyright (C) Copyright 2015-2016 b<>com
*
* This program is free software; you can redistribute it and/or
* modify it under the terms of the GNU General Public Licence
* as published by the Free Software Foundation; either version
* 2 of the Licence, or (at your option) any later version.
 ***************************************************************/

#include "../iotracer_util.h"

#include <linux/kprobes.h>  /* For jprobes and kprobes */

#include <linux/fs.h>
#include <linux/aio.h>
#include <linux/uio.h>

#include "../iotracer_log.h"

#include "filemap_probes.h"

/**
 * generic_file_read_iter_handler - handler for generic_file_read_iter() probe
 */
ssize_t generic_file_read_iter_handler(struct kiocb *iocb,
				       struct iov_iter *iter)
{
	if (iotracer_inode_monitored(iocb->ki_filp->f_mapping->host)) {
		/* Insert the event */
		iotracer_insert_event(IO_READ_EVENT, VFS,
				      iocb->ki_filp->f_mapping->host,
				      iocb->ki_pos, iov_iter_count(iter));
	}

	jprobe_return();
	return 0;
}

/**
 * __generic_file_write_iter_handler - handler for __generic_file_write_iter()
 *                                     probe
 */
ssize_t __generic_file_write_iter_handler(struct kiocb *iocb,
					  struct iov_iter *from)
{
	if (iotracer_inode_monitored(iocb->ki_filp->f_mapping->host)) {
		/* Insert the event */
		iotracer_insert_event(IO_WRITE_EVENT, VFS,
				      iocb->ki_filp->f_mapping->host,
				      iocb->ki_pos, iov_iter_count(from));
	}

	jprobe_return();
	return 0;
}

static struct jprobe generic_file_read_iter_j = {
	.entry	= generic_file_read_iter_handler,
	.kp	= {
			.symbol_name = "generic_file_read_iter",
		  },
};

static struct jprobe generic_file_write_iter_j = {
	.entry	= __generic_file_write_iter_handler,
	.kp	= {
			.symbol_name = "__generic_file_write_iter",
		  },
};

/**
 * register_filemap_probes - probes registration
 */
int register_filemap_probes(void)
{
	int ret = 0;

	ret = register_jprobe(&generic_file_write_iter_j);
	if (ret) {
		IOTRACER_ERROR(
			"register generic_file_write_iter probe failed\n");
		return ret;

	}

	ret = register_jprobe(&generic_file_read_iter_j);
	if (ret) {
		IOTRACER_ERROR(
			"register generic_file_read_iter probe failed\n");
		return ret;
	}

	return ret;
}

/**
 * unregister_filemap_probes - probes unregistration
 */
void unregister_filemap_probes(void)
{
	unregister_jprobe(&generic_file_write_iter_j);
	unregister_jprobe(&generic_file_read_iter_j);
}

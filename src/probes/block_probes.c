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

#include <linux/bio.h>    /* bio structuree */

#include <linux/kallsyms.h>
#include <linux/kprobes.h> /* For jprobes and kprobes */

/*
 * struct dio is redefined here because it is not defined in a header file
 * (it is defined in fs/direct-io.c)
 */
#define DIO_PAGES	64
struct dio {
	int flags;			/* doesn't change */
	int rw;
	struct inode *inode;
	loff_t i_size;			/* i_size when submitted */
	dio_iodone_t *end_io;		/* IO completion function */

	void *private;			/* copy from map_bh.b_private */

	/* BIO completion state */
	spinlock_t bio_lock;		/* protects BIO fields below */
	int page_errors;		/* errno from get_user_pages() */
	int is_async;			/* is IO async ? */
	bool defer_completion;		/* defer AIO completion to workqueue? */
	int io_error;			/* IO error in completion path */
	unsigned long refcount;		/* direct_io_worker() and bios */
	struct bio *bio_list;		/* singly linked via bi_private */
	struct task_struct *waiter;	/* waiting task (NULL if none) */

	/* AIO related stuff */
	struct kiocb *iocb;		/* kiocb */
	ssize_t result;                 /* IO result */

	/*
	 * pages[] (and any fields placed after it) are not zeroed out at
	 * allocation time.  Don't add new fields after pages[] unless you
	 * wish that they not be zeroed.
	 */
	union {
		struct page *pages[DIO_PAGES];	/* page buffer */
		struct work_struct complete_work;/* deferred AIO completion */
	};
} ____cacheline_aligned_in_smp;

#include "../iotracer_log.h"

#include "block_probes.h"

static void *dio_bio_end_aio_addr;
static void *dio_bio_end_io_addr;

/**
 * bio_page_inode - return the inode corresponding to a block I/O
 *
 * @bio: description of the block I/O
 * @page: page used to store data of the block I/O
 */
static inline struct inode *bio_page_inode(struct bio *bio, struct page *page)
{
	struct inode *inode = NULL;
	struct address_space *mapping = NULL;

	/*
	 * On an anonymous page mapped into a user virtual memory area,
	 * page->mapping points to the list of these private vmas
	 * (its anon_vma), not to the inode address_space which
	 * maps the page from disk.
	 *
	 * If bio has been created for direct-io,
	 * bi_private points to struct dio which field inode
	 * points to the corresponding inode
	 *
	 * To check if this is tha case we use the fact that direct-io
	 * set bi_end_io to function dio_bio_end_aio or dio_bio_end_io
	 *
	 * The anon_vma heads a list of private "related" vmas, to scan if
	 */
	if (!PageAnon(page))
		mapping = page_file_mapping(page);

	if (mapping != NULL) {
		inode = mapping->host;
		if (inode == NULL)
			IOTRACER_DEBUG("null host\n");
	} else if ((bio->bi_private != NULL) &&
		   ((bio->bi_end_io == dio_bio_end_aio_addr) ||
		     (bio->bi_end_io == dio_bio_end_io_addr))) {
			struct dio *dio = (struct dio *) bio->bi_private;

			inode = dio->inode;
			if (inode == NULL) {
				IOTRACER_DEBUG("null inode\n");
			} else {
				IOTRACER_DEBUG("dio (anon page = %d)\n",
					       PageAnon(page));
			}
	} else {
		IOTRACER_WARNING("cannot handle page\n");
	}

	return inode;
}

/**
 * insert_bio_event - insert a block I/O event in the I/O tracer log
 *
 * @bio: description of the block I/O
 */
static inline void insert_bio_event(struct bio *bio)
{
	struct inode *inode = NULL;

	if (bio->bi_iter.bi_idx > 0)
		IOTRACER_DEBUG("iter index = %u\n", bio->bi_iter.bi_idx);

	inode = bio_page_inode(bio, bio_page(bio));
	if (inode == NULL) {
		struct bio_vec *bvl;
		unsigned bvl_idx;

		bio_for_each_segment_all(bvl, bio, bvl_idx) {
			IOTRACER_DEBUG("bio_vec %u\n", bvl_idx);
			inode = bio_page_inode(bio, bvl->bv_page);
			if (inode != NULL) {
				IOTRACER_DEBUG("inode %ld -> %u @ %u\n",
					       inode->i_ino,
					       bvl->bv_len,
					       bvl->bv_offset);
				break;
			}
		}
	}

	if (inode != NULL) {
		if (iotracer_inode_monitored(inode)) {
			/* Write log */
			iotracer_insert_event((bio->bi_rw & WRITE)
						? IO_WRITE_EVENT
						: IO_READ_EVENT,
					      BLK,
					      inode,
					      (loff_t) bio->bi_iter.bi_sector,
					      bio_sectors(bio));
		} else {
			IOTRACER_DEBUG("blk %c ino %ld - %lld %u - %u %u\n",
				       (bio->bi_rw & WRITE) ? 'W' : 'R',
				       inode->i_ino,
				       (loff_t) bio->bi_iter.bi_sector,
				       bio_sectors(bio),
				       task_tgid_nr(current),
				       task_pid_nr(current));
		}
	} else {
		IOTRACER_WARNING("bio not logged\n");
	}
}

/**
 * generic_make_request_handler - handler for generic_make_request() probe
 */
void generic_make_request_handler(struct bio *bio)
{
	if ((bio != NULL) && iotracer_bdev_monitored(bio->bi_bdev)) {
		if (bio_is_rw(bio)) {
			if (bio_page(bio) != NULL)
				insert_bio_event(bio);
			else
				IOTRACER_DEBUG("null page\n");
		} else {
			IOTRACER_DEBUG("not rw\n");
		}
	}

	jprobe_return();
}

static struct jprobe generic_make_request_j = {
	.entry	= generic_make_request_handler,
	.kp	= {
			.symbol_name = "generic_make_request",
		  },
};

/**
 * register_block_probes - block probes registration
 */
int register_block_probes(void)
{
	int ret = 0;

	dio_bio_end_aio_addr = (void *) kallsyms_lookup_name("dio_bio_end_aio");
	if (dio_bio_end_aio_addr == NULL)
		IOTRACER_WARNING(
			"symbol dio_bio_end_aio not found, block direct-io will be lost\n");

	dio_bio_end_io_addr = (void *) kallsyms_lookup_name("dio_bio_end_io");
	if (dio_bio_end_io_addr == NULL)
		IOTRACER_WARNING(
			"symbol dio_bio_end_io not found, block direct-io will be lost\n");

	/* Register probes */
	ret = register_jprobe(&generic_make_request_j);
	if (ret) {
		IOTRACER_ERROR("register generic_make_request probe failed\n");
		return ret;
	}

	return ret;
}

/**
 * unregister_block_probes - block probes unregistration
 */
void unregister_block_probes(void)
{
	unregister_jprobe(&generic_make_request_j);
}

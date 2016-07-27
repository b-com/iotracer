/*!**************************************************************
* \authors   Hamza Ouarnoughi, Jean-Emile DARTOIS, Nicolas Guyomard
* \copyright (C) Copyright 2015-2016 b<>com
*
* This program is free software; you can redistribute it and/or
* modify it under the terms of the GNU General Public Licence
* as published by the Free Software Foundation; either version
* 2 of the Licence, or (at your option) any later version.
*
* This file implements user's interface of iotracer in procfs and
* provide facility to log IO events related to an inode
***************************************************************/

/* The for logging the events in block device */

#include "iotracer_util.h"

#include <linux/vmalloc.h>
#include <linux/proc_fs.h>
#include <linux/sched.h>
#include <linux/slab.h>
#include <linux/uaccess.h>
#include <linux/seq_file.h>
#include <linux/namei.h>
#include <linux/ctype.h>

#include "iotracer_log.h"

#define PROCFS_LOG_NAME "log"
#define PROCFS_CTL_NAME "control"

#define PROC_DIRNAME_LEN_MAX (BDEVNAME_SIZE+12)

#define SECTOR_SIZE 512 /* TODO: get it from bio struct */

#define MAX_RECEIVED_SIZE (32)

/* A log entry */
struct s_iolog_entry {
	loff_t address;
	size_t bsize;
	ktime_t ktimestamp;
	enum access_level level;
	char task_name[TASK_COMM_LEN];
	pid_t task_tgid;
	char type;
};

struct filepath {
	char *pathname;
	struct hlist_node f_iolog;
};

/* Log data for an inode */
struct s_iotracer_log {
	/* unique ids of the inode associated to this log */
	char bdevname[BDEVNAME_SIZE];
	unsigned long inode_num;
	/* list of iotracer logs */
	struct list_head list;
	/* lock for this log */
	spinlock_t lock;
	/* list of path corresponding to this log */
	struct hlist_head pathname;
	/* lock status */
	int enabled;
	/* log circular buffer data */
	unsigned int next_entry;
	unsigned int nbelems;
	unsigned int size;
	struct s_iolog_entry *elems;
	/* time zero for this log */
	ktime_t kTimeZero;
	/* /proc entries */
	struct proc_dir_entry *proc_dir;
	struct proc_dir_entry *log_proc_file;
	struct proc_dir_entry *ctl_proc_file;
	/* last_shown is used to check that all log entries are shown
	 * when reading log file
	 */
	unsigned int last_shown;
};

/* list of iotracer logs */
static LIST_HEAD(iotracer_log_list);
DEFINE_SPINLOCK(iotracer_log_lock);

/**
 * io_access_level - return access level as a string
 */
static inline char *io_access_level(enum access_level level)
{
	switch (level) {
	case VFS:
		return "VFS";
	case FS:
		return "FS";
	case BLK:
		return "BLK";
	default:
		return "";
	}
}

/**
 * iolog_get_state - return state of a log
 */
static inline int iolog_get_state(struct s_iotracer_log *iolog)
{
	return iolog->enabled;
}

/**
 * iolog_enable - enable a log
 */
static inline void iolog_enable(struct s_iotracer_log *iolog)
{
	iolog->enabled = 1;
}

/**
 * iolog_disable - disable a log
 */
static inline void iolog_disable(struct s_iotracer_log *iolog)
{
	iolog->enabled = 0;
}

/**
 * get_absolute_path - return string containing absolute path of a path
 */
static inline char *get_absolute_path(struct path *path)
{
	char *absolute_path = NULL;
	char *pathbuf = __getname();
	char *fullpath = NULL;

	if (!pathbuf) {
		IOTRACER_ERROR("Unable to allocate pathbuf\n");
		return ERR_PTR(-ENOMEM);
	}

	fullpath = d_path(path, pathbuf, PATH_MAX);
	if (!IS_ERR(fullpath)) {
		absolute_path = kstrdup(fullpath, GFP_KERNEL);
		if (IS_ERR(absolute_path))
			IOTRACER_ERROR("Unable to allocate pathname\n");
	}
	__putname(pathbuf);

	return absolute_path;
}

/**
 * inode_lookup - get block device name and inode number corresponding to a path
 *
 * @pathname:  name of the file
 * @bdev_name: name of block device containing the inode
 * @inode_num: inode number
 * @fullpath:  absolute path of pathname
 */
static int inode_lookup(const char *pathname,
			char *bdev_name, unsigned long *inode_num,
			char **fullpath)
{
	int ret = 0;
	struct path path;

	if (kern_path(pathname, LOOKUP_RCU, &path)) {
		IOTRACER_ERROR("file not found: %s\n", pathname);
		ret = -ENOENT;
	} else {
		*fullpath = get_absolute_path(&path);
		if (IS_ERR_OR_NULL(fullpath))
			ret = -EPERM;
	}

	if (!ret && d_is_symlink(path.dentry)) {
		IOTRACER_INFO("%s is a symlink\n", *fullpath);

		/* we must use target inode, not inode of the symlink */
		path_put(&path);
		if (kern_path(pathname, LOOKUP_FOLLOW, &path)) {
			IOTRACER_ERROR("target of symlink %s not found\n",
				       pathname);
			ret = -ENOENT;
		}
	}

	if (!ret) {
		struct inode *inode = path.dentry->d_inode;

		if (inode) {
			if (inode->i_sb && inode->i_sb->s_bdev) {
				/* Get the device name */
				bdevname(inode->i_sb->s_bdev, bdev_name);
				*inode_num = inode->i_ino;
			} else if (inode->i_sb) {
				IOTRACER_ERROR("no bdev for %s\n", pathname);
				ret = -EPERM;
			} else {
				IOTRACER_ERROR("no superblock for %s\n",
					       pathname);
				ret = -EPERM;
			}
		} else {
			IOTRACER_ERROR("no inode for %s\n", pathname);
			ret = -EPERM;
		}

		path_put(&path);
	}

	return ret;
}

/**
 * get_iolog - return struct s_iotracer_log associated to the given inode
 *
 * @bdevname:  name of block device containing the inode
 * @inode_num: inode number
 */
static struct s_iotracer_log *get_iolog(char *bdevname, unsigned long inode_num)
{
	int found = 0;
	struct s_iotracer_log *cur;

	spin_lock(&iotracer_log_lock);
	list_for_each_entry(cur, &iotracer_log_list, list)
		if (!strncmp(cur->bdevname, bdevname, BDEVNAME_SIZE) &&
				(cur->inode_num == inode_num)) {
			found = 1;
			break;
		}
	spin_unlock(&iotracer_log_lock);

	if (found)
		return cur;
	else
		return NULL;
}

/**
 * iotracer_bdev_monitored - check if a block device is monitored
 */
int iotracer_bdev_monitored(struct block_device *bdev)
{
	int found = 0;
	struct s_iotracer_log *cur;
	char bdev_name[BDEVNAME_SIZE];

	/* Get the device name */
	bdevname(bdev, bdev_name);

	spin_lock(&iotracer_log_lock);
	list_for_each_entry(cur, &iotracer_log_list, list)
		if (!strncmp(cur->bdevname, bdev_name, BDEVNAME_SIZE)) {
			found = 1;
			break;
		}
	spin_unlock(&iotracer_log_lock);

	return found;
}

/**
 * iotracer_inode_monitored - check if an inode is monitored
 */
int iotracer_inode_monitored(struct inode *inode)
{
	int ret = 0;

	if (!inode->i_sb)
		IOTRACER_WARNING("inode without superblock\n");
	else if (inode->i_sb->s_bdev) {
		char bdev_name[BDEVNAME_SIZE];

		/* Get the device name */
		bdevname(inode->i_sb->s_bdev, bdev_name);

		if (get_iolog(bdev_name, inode->i_ino))
			ret = 1;
		else if (iotracer_bdev_monitored(inode->i_sb->s_bdev))
			IOTRACER_DEBUG("inode %ld of %s not monitored\n",
				       inode->i_ino, bdev_name);
	}

	return ret;
}

/**
 * iolog_reset - reset a log
 */
static inline void iolog_reset(struct s_iotracer_log *iolog)
{
	unsigned int i;

	/* Take the lock to avoid concurrent access */
	spin_lock(&(iolog->lock));

	iolog->nbelems = 0;
	iolog->next_entry = 0; /* This can be ommitted */

	for (i = 0; i < iolog->size; i++)
		iolog->elems[i].type = IO_EVENT_NONE;

	/* Release the lock */
	spin_unlock(&iolog->lock);
}

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
			   loff_t address, size_t size)
{
	struct s_iotracer_log *iolog;
	char bdev_name[BDEVNAME_SIZE];

	/* Get the device name */
	bdevname(inode->i_sb->s_bdev, bdev_name);

	iolog = get_iolog(bdev_name, inode->i_ino);

	if (unlikely(!iolog)) {
		IOTRACER_ERROR("no log for inode %ld of %s\n",
			       inode->i_ino, bdev_name);
	} else if (iolog_get_state(iolog)) {
		struct s_iolog_entry *log_entry;

		/* Take the lock to avoid concurrent access */
		spin_lock(&(iolog->lock));

		log_entry = &(iolog->elems[iolog->next_entry]);

		/* Save the end of the circular log */
		iolog->next_entry = (iolog->next_entry+1)%iolog->size;

		/* If log is full then log return to the first slot */
		if (iolog->nbelems < iolog->size)
			iolog->nbelems++;

		/* Release the lock */
		spin_unlock(&iolog->lock);

		/* Use k_time to replace getnstime*/
		log_entry->ktimestamp = ktime_get();

		/* Log the event (access type)*/
		log_entry->type = event;

		/* Log the accessed adress */
		log_entry->address = address;

		/* Log the data size accessed */
		/* TODO: use log_entry->bsize = size in all cases */
		if (level == BLK)
			log_entry->bsize = (size*SECTOR_SIZE);
		else
			log_entry->bsize = size;

		/* IO Level */
		log_entry->level = level;

		/* Log the task making this IO */
		get_task_comm(log_entry->task_name, current);
		/* Use identifier of the user process making the access(tgid)
		 * not identifier of the kernel thread(pid) */
		log_entry->task_tgid = task_tgid_nr(current);
	} else {
		pr_devel("%s(%c, %s, %s %ld, %lld, %zu) - log inactive\n",
			 __func__,
			 event, io_access_level(level),
			 bdev_name, inode->i_ino,
			 address, size);
	}
}

/* The /proc entries stuff */

/**
 * proc_file_get_iolog - return struct s_iotracer_log corresponding to
 *                       the given file in /proc (log or control entry)
 */
static struct s_iotracer_log *proc_file_get_iolog(struct file *filp)
{
	char proc_dirname[PROC_DIRNAME_LEN_MAX];
	unsigned long inodenum;
	char *p;
	struct s_iotracer_log *iolog = NULL;

	strncpy(proc_dirname, filp->f_path.dentry->d_parent->d_name.name,
		PROC_DIRNAME_LEN_MAX);
	p = strnchr(proc_dirname, PROC_DIRNAME_LEN_MAX, '_');
	if (p) {
		*p = '\0';
		if (!kstrtoul(p+1, 0, &inodenum))
			iolog = get_iolog(proc_dirname, inodenum);
	}

	return iolog;
}

/*
 * seq_file operations for log_proc_file
 */

static void *iolog_seq_start(struct seq_file *s, loff_t *pos)
{
	struct s_iotracer_log *iolog = s->private;
	unsigned int *spos = NULL;
	/* pos contain the index from which to start the sequence */
	unsigned int idx = (unsigned int) *pos;

	IOTRACER_DEBUG("%s: entries %d/%d , next = %d , pos = %lld\n",
		       __func__,
		       iolog->nbelems, iolog->size, iolog->next_entry,
		       *pos);

	/* It is assumed that user has disabled log before read */
	if (idx >= iolog->nbelems) {
		*pos = 0;
		return NULL;
	}

	spos = kmalloc(sizeof(unsigned int), GFP_KERNEL);
	if (spos) {
#ifdef DEBUG
		if (iolog_get_state(iolog))
			IOTRACER_WARNING("WARNING: reading while log active\n");
#endif

		/* Index of the current log to read */
		/* first entry index is (next_entry + size - nbelems) % size */
		*spos = ((iolog->next_entry
			  + iolog->size - iolog->nbelems)
			 + (unsigned int)(*pos)) % iolog->size;

		IOTRACER_DEBUG("index = %d\n", *spos);

		iolog->last_shown = iolog->size;
	}

	return spos;
}

static void iolog_seq_stop(struct seq_file *s, void *v)
{
	kfree(v);
}

static void *iolog_seq_next(struct seq_file *s, void *v, loff_t *pos)
{
	struct s_iotracer_log *iolog = s->private;
	unsigned int *spos = (unsigned int *) v;

	*spos = (*spos + 1) % iolog->size;
	++*pos;
	if (*spos == (iolog->next_entry % iolog->size))
		return NULL; /* end the sequence */

	return spos;
}

static int iolog_seq_show(struct seq_file *s, void *v)
{
	int ret;
	struct s_iotracer_log *iolog = s->private;
	unsigned int idx = *((unsigned int *) v);
	struct s_iolog_entry *cur = &iolog->elems[idx];

	ktime_t kts_tmp = ktime_sub(cur->ktimestamp, iolog->kTimeZero);
	struct timespec ts_tmp = ktime_to_timespec(kts_tmp);

	if ((iolog->last_shown < iolog->size)
	    && (iolog->last_shown != idx)
	    && (idx != ((1 + iolog->last_shown) % iolog->size)))
		IOTRACER_WARNING("%s: jump from %d to %d\n",
		       __func__, iolog->last_shown, idx);

	iolog->last_shown = idx;

	/* Print:
	 * - the time stamp first
	 * - the access type
	 * - the accessed block address
	 * - the accessed data size
	 * - the access level
	 * - the name and tgid of the task making the IO
	 * - the inode number (TODO file path)
	 */
	ret = seq_printf(s, "%lld.%.9ld;%c;%lld;%zu;%s;%s;%u\n",
			 (long long)ts_tmp.tv_sec, ts_tmp.tv_nsec,
			 cur->type,
			 cur->address,
			 cur->bsize,
			 io_access_level(cur->level),
			 cur->task_name,
			 cur->task_tgid);

	if (ret)
		IOTRACER_DEBUG("%s: no place in buffer for index %d\n",
			       __func__, idx);

	return ret;
}

static const struct seq_operations iolog_seq_ops = {
	.start	= iolog_seq_start,
	.next	= iolog_seq_next,
	.stop	= iolog_seq_stop,
	.show	= iolog_seq_show
};

/* File operations for the /proc log entry */

static int procfile_iolog_open(struct inode *inode, struct file *filp)
{
	int err = seq_open(filp, &iolog_seq_ops);

	if (!err) {
		struct seq_file *s = (struct seq_file *) filp->private_data;
		struct s_iotracer_log *iolog = proc_file_get_iolog(filp);

		if (!iolog) {
			IOTRACER_ERROR("no log corresponding to this file\n");
			return -EFAULT;
		}

		s->private = iolog;
	}

	return err;
}

static const struct file_operations fops_iolog = {
	.owner	 = THIS_MODULE,
	.open	 = procfile_iolog_open,
	.read	 = seq_read,
	.llseek	 = seq_lseek,
	.release = seq_release
};

/* File operations for the /proc log control entry */

static ssize_t procfile_iolog_ctl_read(struct file *filp,
				       char __user *buffer, size_t size,
				       loff_t *offset)
{
#define LINE_MAX_LEN 64

	ssize_t bytes_read = 0;
	struct s_iotracer_log *iolog = filp->private_data;
	struct timespec ts_tmp;
	char line[LINE_MAX_LEN];

	buffer[0] = '\0';

	if (!iolog)
		return -EINVAL;

	/* Get data to output */
	spin_lock(&iolog->lock);
	ts_tmp = ktime_to_timespec(iolog->kTimeZero);
	snprintf(line, LINE_MAX_LEN, "%d %lld.%.9ld %d %d\n",
		 iolog->enabled, (long long) ts_tmp.tv_sec, ts_tmp.tv_nsec,
		 iolog->size, iolog->nbelems);
	spin_unlock(&iolog->lock);

	/* Copy output to user buffer */
	if (*offset < strlen(line)) {
		strncpy(buffer, line + *offset, size);
		bytes_read = strlen(buffer);
		*offset += bytes_read;
	}

	return bytes_read;
}

static ssize_t procfile_iolog_ctl_write(struct file *filp,
					const char __user *buffer, size_t size,
					loff_t *offset)
{
	char received[MAX_RECEIVED_SIZE];
	int ret;
	struct s_iotracer_log *iolog = filp->private_data;

	if (!iolog) {
		IOTRACER_ERROR("%s: no log corresponding to this file\n",
			       __func__);
		return -EINVAL;
	}

	if (size > MAX_RECEIVED_SIZE)
		return size;

	ret = copy_from_user(received, buffer, size);

	if (!strncmp(received, "reset", strlen("reset"))) {
		iolog_reset(iolog);
	} else if (!strncmp(received, "timereset", strlen("timereset"))) {
		iolog_reset(iolog);
		/* getnstimeofday(&log.zeroTime); */
		iolog->kTimeZero = ktime_get();
	} else if (!strncmp(received, "start", strlen("start"))) {
		iolog_enable(iolog);
	} else if (!strncmp(received, "stop", strlen("stop"))) {
		iolog_disable(iolog);
	} else {
		IOTRACER_ERROR("Unrecognized command : %s\n", received);
	}

	return size;
}

static int procfile_iolog_ctl_open(struct inode *inode, struct file *filp)
{
	struct s_iotracer_log *iolog = proc_file_get_iolog(filp);

	if (!iolog) {
		IOTRACER_ERROR("no log corresponding to this file\n");
		return -EFAULT;
	}

	filp->private_data = iolog;

	return 0;
}

static int procfile_iolog_ctl_close(struct inode *inode, struct file *filp)
{
	return 0;
}

static const struct file_operations fops_iolog_ctl = {
	.owner	 = THIS_MODULE,
	.read	 = procfile_iolog_ctl_read,
	.write	 = procfile_iolog_ctl_write,
	.open	 = procfile_iolog_ctl_open,
	.release = procfile_iolog_ctl_close
};

/**
 * iolog_add - add a new file to monitor
 *
 * #pathname: name of the file
 * @size_max: number of events to keep in the log corresponding to the file
 */
static int iolog_add(char *pathname, unsigned int size_max)
{
	int ret;
	char bdevname[BDEVNAME_SIZE];
	unsigned long inodenum;
	struct s_iotracer_log *iolog = NULL;
	struct filepath *fp;
	struct hlist_node *tmp;
	unsigned int i;
	char proc_dirname[PROC_DIRNAME_LEN_MAX];
	char *fullpath = NULL;

	ret = inode_lookup(pathname, bdevname, &inodenum, &fullpath);
	if (ret) {
		IOTRACER_ERROR("inode_lookup failed for %s\n", pathname);
		return ret;
	}
	if (strcmp(pathname, fullpath))
		IOTRACER_DEBUG("%s absolute path = %s", pathname, fullpath);

	/* Nothing to do if we already monitor this inode */
	iolog = get_iolog(bdevname, inodenum);
	if (iolog) {
		int found = 0;

		hlist_for_each_entry(fp, &iolog->pathname, f_iolog)
			if (!strcmp(fp->pathname, fullpath)) {
				found = 1;
				break;
			}
		if (!found) {
			fp = kmalloc(sizeof(struct filepath), GFP_KERNEL);
			if (IS_ERR(fp)) {
				IOTRACER_ERROR("Unable to allocate filepath\n");
				kfree(fullpath);
				return -ENOMEM;
			}
			fp->pathname = fullpath;
			/* TODO: update size and elems if needed */
			hlist_add_head(&fp->f_iolog, &iolog->pathname);
			IOTRACER_INFO("%s is monitored (inode %ld of %s)\n",
				      fullpath,
				      iolog->inode_num, iolog->bdevname);
		} else {
			IOTRACER_INFO("%s is already monitored\n", pathname);
			kfree(fullpath);
		}
		return 0;
	}

	/* Allocate the iolog */
	iolog = kmalloc(sizeof(struct s_iotracer_log), GFP_KERNEL);
	if (IS_ERR(iolog)) {
		kfree(fullpath);
		return -ENOMEM;
	}

	/* initialize struct s_iotracer_log */
	iolog->inode_num = inodenum;
	strncpy(iolog->bdevname, bdevname, BDEVNAME_SIZE);
	INIT_LIST_HEAD(&(iolog->list));
	INIT_HLIST_HEAD(&iolog->pathname);
	fp = kmalloc(sizeof(struct filepath), GFP_KERNEL);
	if (IS_ERR(fp)) {
		IOTRACER_ERROR("Unable to allocate filepath\n");
		kfree(iolog);
		kfree(fullpath);
		return -ENOMEM;
	}
	fp->pathname = fullpath;
	INIT_HLIST_NODE(&fp->f_iolog);
	hlist_add_head(&fp->f_iolog, &iolog->pathname);

	iolog->enabled = 0;
	spin_lock_init(&iolog->lock);
	iolog->size = size_max;
	iolog->nbelems = 0;
	iolog->next_entry = 0;

	iolog->elems =
	  vmalloc(iolog->size*sizeof(struct s_iolog_entry));
	if (IS_ERR(iolog->elems)) {
		IOTRACER_ERROR("Unable to allocate log array\n");
		goto free_iolog;
	}

	for (i = 0; i < iolog->size; i++)
		iolog->elems[i].type = IO_EVENT_NONE;

	/* /proc entry */
	snprintf(proc_dirname, PROC_DIRNAME_LEN_MAX,
		 "%s_%ld", bdevname, inodenum);
	iolog->proc_dir = proc_mkdir(proc_dirname, iotracer_proc_dir);
	if (!iolog->proc_dir) {
		IOTRACER_ERROR("Unable to create /proc/%s/%s\n",
			       PROCFS_DIR, proc_dirname);
		goto free_mem;
	}

	iolog->log_proc_file =
		proc_create(PROCFS_LOG_NAME, S_IRUGO,
			    iolog->proc_dir, &fops_iolog);
	if (!iolog->log_proc_file) {
		IOTRACER_ERROR("Unable to create /proc/%s/%s/%s\n",
			       PROCFS_DIR, proc_dirname, PROCFS_LOG_NAME);
		goto del_proc_dir;
	}

	iolog->ctl_proc_file =
		proc_create(PROCFS_CTL_NAME, S_IWUGO | S_IRUGO,
			    iolog->proc_dir, &fops_iolog_ctl);
	if (!iolog->ctl_proc_file) {
		IOTRACER_ERROR("Unable to create /proc/%s/%s/%s\n",
			       PROCFS_DIR, proc_dirname, PROCFS_CTL_NAME);
		proc_remove(iolog->log_proc_file);
		goto del_proc_dir;
	}

	/* set time zero */
	iolog->kTimeZero = ktime_get();

	spin_lock(&iotracer_log_lock);
	list_add_tail(&iolog->list, &iotracer_log_list);
	spin_unlock(&iotracer_log_lock);
	IOTRACER_INFO("ready to log %d events for %s (inode %ld of %s)\n",
		      iolog->size, pathname,
		      iolog->inode_num, iolog->bdevname);

	iolog_enable(iolog);

	return 0;

del_proc_dir:
	proc_remove(iolog->proc_dir);

free_mem:
	vfree(iolog->elems);

free_iolog:
	hlist_for_each_entry_safe(fp, tmp, &iolog->pathname, f_iolog) {
		hlist_del_init(&fp->f_iolog);
		kfree(fp->pathname);
	}
	kfree(iolog);

	return -ENOMEM;
}

/**
 * iolog_del - stop to monitor an inode
 *
 * @bdevname:  name of block device containing the inode
 * @inode_num: inode number
 */
static int iolog_del(char *bdevname, unsigned long inodenum)
{
	int ret = 0;
	struct s_iotracer_log *iolog = get_iolog(bdevname, inodenum);
	struct filepath *fp;
	struct hlist_node *tmp;

	if (iolog) {
		char proc_dirname[PROC_DIRNAME_LEN_MAX];

		IOTRACER_INFO("stop monitoring inode %ld of %s\n",
			      inodenum, bdevname);
		list_del_init(&(iolog->list));

		spin_lock(&iotracer_log_lock);
		list_del(&iolog->list);
		spin_unlock(&iotracer_log_lock);

		snprintf(proc_dirname, PROC_DIRNAME_LEN_MAX, "%s_%ld",
			 iolog->bdevname, iolog->inode_num);

		proc_remove(iolog->log_proc_file);
		proc_remove(iolog->ctl_proc_file);
		proc_remove(iolog->proc_dir);
		vfree(iolog->elems);
		hlist_for_each_entry_safe(fp, tmp, &iolog->pathname,
					  f_iolog) {
			hlist_del_init(&fp->f_iolog);
			kfree(fp->pathname);
		}
		kfree(iolog);
	} else {
		IOTRACER_INFO("inode %ld of %s not monitored\n",
			      inodenum, bdevname);
		ret = -ENOENT;
	}

	return ret;
}

/**
 * iolog_remove - remove a file from monitoring
 *
 * #pathname: name of the file
 */
static int iolog_remove(char *pathname)
{
	int ret = -ENOENT;
	struct s_iotracer_log *iolog = NULL;
	struct s_iotracer_log *cur;
	struct filepath *fp;
	struct hlist_node *tmp;

	spin_lock(&iotracer_log_lock);
	list_for_each_entry(cur, &iotracer_log_list, list) {
		hlist_for_each_entry_safe(fp, tmp, &cur->pathname, f_iolog)
			if (!strcmp(fp->pathname, pathname)) {
				iolog = cur;
				hlist_del_init(&fp->f_iolog);
				break;
			}
		if (iolog)
			break;
	}
	spin_unlock(&iotracer_log_lock);

	if (iolog) {
		IOTRACER_INFO("stop monitoring %s\n", pathname);
		ret = 0;
		if (hlist_empty(&iolog->pathname))
			ret = iolog_del(iolog->bdevname,
					   iolog->inode_num);
	} else
		IOTRACER_ERROR("'%s' not monitored\n", pathname);

	return ret;
}

/**
 * iotracer_log_exit - clean all: stop to monitor any file
 */
void iotracer_log_exit(void)
{
	struct s_iotracer_log *cur, *next;

	list_for_each_entry_safe(cur, next, &iotracer_log_list, list)
		iolog_del(cur->bdevname, cur->inode_num);
}

/* seq_file operations for /proc control file */

static void *iotracer_seq_start(struct seq_file *s, loff_t *pos)
{
	spin_lock(&iotracer_log_lock);
	return seq_list_start(&iotracer_log_list, *pos);
}

static void iotracer_seq_stop(struct seq_file *s, void *v)
{
	spin_unlock(&iotracer_log_lock);
}

static void *iotracer_seq_next(struct seq_file *s, void *v, loff_t *pos)
{
	return seq_list_next(v, &iotracer_log_list, pos);
}

static int iotracer_seq_show(struct seq_file *s, void *v)
{
	int ret;
	struct s_iotracer_log *iolog = container_of(v, struct s_iotracer_log,
						    list);
	struct filepath *fp;
	struct hlist_node *tmp;

	ret = seq_printf(s, "%s_%ld", iolog->bdevname, iolog->inode_num);
	if (!ret) {
		hlist_for_each_entry_safe(fp, tmp, &iolog->pathname,
					  f_iolog) {
			ret = seq_printf(s, " %s", fp->pathname);
			if (ret)
				break;
		}
	}
	if (!ret)
		ret = seq_putc(s, '\n');

	return ret;
}

static const struct seq_operations iotracer_seq_ops = {
	.start	= iotracer_seq_start,
	.next	= iotracer_seq_next,
	.stop	= iotracer_seq_stop,
	.show	= iotracer_seq_show
};

/* file operations for /proc control file */

static int procfile_iotracer_open(struct inode *inode, struct file *filp)
{
	int err = seq_open(filp, &iotracer_seq_ops);

	if (!err) {
		/*
		 * seq_files do not implement write() and clear FMODE_PWRITE
		 * As we want to implement it we need to set FMODE_PWRITE.
		 */
		filp->f_mode |= FMODE_PWRITE;
	}

	return err;
}

/**
 * procfile_iotracer_write - Write to the /proc entry
 *
 * This file is used to give new inodes to trace
 */
static ssize_t procfile_iotracer_write(struct file *file,
				       const char __user *buffer, size_t size,
				       loff_t *offset)
{
	char *received = NULL;
	int ret = -EIO;

	char *cmd_str;
	char *path_str = NULL;
	unsigned int max_events;
	int len;

	if (size > (PATH_MAX + 19))
		return -EIO;

	received = kmalloc(size+1, GFP_KERNEL);
	if (IS_ERR(received))
		return -ENOMEM;

	if (copy_from_user(received, buffer, size)) {
		kfree(received);
		return -EFAULT;
	}
	received[size] = '\0';

	cmd_str = skip_spaces(received);
	if (!*cmd_str)
		IOTRACER_ERROR("command required\n");
	else {
		/* parse command string */
		/*
		 * argv_split() cannot be used here as this function strictly
		 * split on white-space not performing quote processing
		 * whereas file path may contain space
		 */
		len = 0;
		for (path_str = cmd_str;
		     *path_str && !isspace(*path_str);
		     path_str++)
			len++;

		path_str = strim(path_str);
		if (!*path_str)
			IOTRACER_ERROR("file path required\n");
		else {
			cmd_str[len] = '\0';

			if (!strncmp(cmd_str, "add", strlen("add"))) {
				/*
				 * This command has an optional parameter,
				 * the number of events to log.
				 * If path_str ends with a space followed by
				 * digits, we assume that those digits form
				 * this optional parameter.
				 * This implies that if a file name ends with
				 * a space followed by digits, this parameter
				 * must be provided.
				 */
				for (len = strlen(path_str);
				     (len > 0) && isdigit(path_str[len-1]);
				     len--)
					;

				if ((len > 0) && isspace(path_str[len-1])) {
					path_str[len-1] = '\0';
					ret = kstrtouint(&path_str[len], 0,
							 &max_events);
					if (ret) {
						IOTRACER_ERROR("kstrtouint!\n");
						max_events = 0;
					}
				} else {
					max_events = MAX_EVENTS;
				}

				if (max_events > 0)
					ret = iolog_add(path_str,
							   max_events);
			} else if (!strncmp(cmd_str,
					    "remove", strlen("remove"))) {
				ret = iolog_remove(path_str);
			} else {
				IOTRACER_ERROR("Unrecognized command : %s\n",
					       received);
			}
		}
	}

	if (!ret)
		ret = size;

	kfree(received);

	return ret;
}

static const struct file_operations fops_iotracer = {
	.owner	 = THIS_MODULE,
	.open	 = procfile_iotracer_open,
	.release = seq_release,
	.read	 = seq_read,
	.write	 = procfile_iotracer_write,
};

/**
 * iotracer_proc_create - create /proc control file
 */
struct proc_dir_entry *iotracer_proc_create(struct proc_dir_entry *proc_dir)
{
	return proc_create(PROCFS_CTL_NAME, S_IWUGO | S_IRUGO,
			   proc_dir, &fops_iotracer);
}

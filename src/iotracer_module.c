/*!**************************************************************
* \authors   Hamza Ouarnoughi, Jean-Emile DARTOIS, Nicolas Guyomard
* \copyright (C) Copyright 2015-2016 b<>com
*
* This program is free software; you can redistribute it and/or
* modify it under the terms of the GNU General Public Licence
* as published by the Free Software Foundation; either version
* 2 of the Licence, or (at your option) any later version.
***************************************************************/

#include "iotracer_util.h"

#include <linux/module.h>  /* Needed by all modules */
#include <linux/proc_fs.h>  /* Necessary because we use the proc fs */

#include "iotracer_log.h"
#include "kprobes.h"

#define IOTRACER_VERSION "1.2.0"

#define PROCFS_CTL_NAME  "control"  /* /proc entry name */

/* Module input parameters */

/* The max events to hold in the log */
unsigned int MAX_EVENTS = 10;
module_param(MAX_EVENTS, uint, 0444);
MODULE_PARM_DESC(MAX_EVENTS, "Max events to hold in the events log file");

/* /proc entries pointers */
struct proc_dir_entry *iotracer_proc_dir;
static struct proc_dir_entry *iotracer_ctl_proc_file;

/**
 * iotracer_init - module initialisation
 */
int __init iotracer_init(void)
{
	int err = 0;

	/* Create directory in /proc for module interface */
	iotracer_proc_dir = proc_mkdir(PROCFS_DIR, NULL);
	if (iotracer_proc_dir == NULL) {
		IOTRACER_ERROR("Unable to create /proc/%s\n", PROCFS_DIR);
		return -ENOMEM;
	}

	/* Create module control file in /proc */
	iotracer_ctl_proc_file = iotracer_proc_create(iotracer_proc_dir);
	if (iotracer_ctl_proc_file == NULL) {
		IOTRACER_ERROR("Unable to create /proc/%s/%s\n",
				PROCFS_DIR, PROCFS_CTL_NAME);
		err = -ENOMEM;
		goto del_proc_dir;
	}

	/* Register probes */
	err = register_iotracer_probes();
	if (err) {
		unregister_iotracer_probes();
		goto del_proc_ctl;
	}

	return 0;

del_proc_ctl:
	proc_remove(iotracer_ctl_proc_file);

del_proc_dir:
	proc_remove(iotracer_proc_dir);

	return err;
}

/**
 * iotracer_exit - module cleanup
 */
void __exit iotracer_exit(void)
{
	IOTRACER_INFO("Cleanup I/O Tracer module...\n");

	/* Release probes */
	unregister_iotracer_probes();

	/* Stop logging */
	iotracer_log_exit();

	/* Remove /proc entry */
	proc_remove(iotracer_ctl_proc_file);
	proc_remove(iotracer_proc_dir);
}

module_init(iotracer_init);
module_exit(iotracer_exit);

MODULE_AUTHOR("Jean-Emile DARTOIS, Hamza Ouarnoughi and Nicolas Guyomard");
MODULE_DESCRIPTION("The I/O tracer kernel module aims to monitor I/O requests that generates physical disk activity.");
MODULE_VERSION(IOTRACER_VERSION);
MODULE_LICENSE("GPL");

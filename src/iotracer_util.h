/*!**************************************************************
* \authors   Hamza Ouarnoughi, Jean-Emile DARTOIS, Nicolas Guyomard
* \copyright (C) Copyright 2015-2016 b<>com

* This program is free software; you can redistribute it and/or
* modify it under the terms of the GNU General Public Licence
* as published by the Free Software Foundation; either version
* 2 of the Licence, or (at your option) any later version.
***************************************************************/

#ifndef IOTRACER_UTIL_H
#define IOTRACER_UTIL_H

#define pr_fmt(fmt) KBUILD_MODNAME ": " fmt

#include <linux/printk.h>
#include <linux/proc_fs.h>

#define PROCFS_DIR KBUILD_MODNAME /* /proc directory */

#define IOTRACER_INFO(fmt, ...) pr_info(fmt, ##__VA_ARGS__)

#define IOTRACER_ERROR(fmt, ...) \
	pr_err(" ERROR - " fmt, ##__VA_ARGS__)

#define IOTRACER_WARNING(fmt, ...) \
	pr_warn(" WARNING - " fmt, ##__VA_ARGS__)

#define IOTRACER_DEBUG(fmt, ...) \
	pr_devel(" %s - " fmt, __func__, ##__VA_ARGS__)

/* pointer to directory in /proc for module interface */
extern struct proc_dir_entry *iotracer_proc_dir;

#endif /* IOTRACER_UTIL_H */

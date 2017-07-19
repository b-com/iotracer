/*!**************************************************************
* \file
* \brief     VFS dentry parser
*
* \author    Jean-Emile DARTOIS
* \date      Created on : 24/11/2014
* \copyright (C) Copyright b<>com\n
*            This software is the confidential and proprietary
*            information of b<>com. You shall not disclose such
*            confidential information and shall use it only in
*            accordance with the terms of the license agreement you
*            entered into with b<>com.
***************************************************************/
#ifndef _DENTRY_H
#define _DENTRY_H

#include <linux/version.h>
#include <linux/module.h>
#include <linux/types.h>
#include <linux/list.h>
#include <linux/hash.h>
#include <linux/workqueue.h>
#include <linux/dcache.h>
#include <linux/debugfs.h>
#include <linux/slab.h>
#include <asm/uaccess.h>
#include <linux/exportfs.h>

#define WORK_BUFF_SIZE	PAGE_SIZE
struct dentry * get_inode_dentry(struct inode * inode);
int dentry_full_file_name(struct dentry * dentry, char * buf, int buf_len);
#endif
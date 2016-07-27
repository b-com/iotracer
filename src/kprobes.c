/***************************************************************
* \authors   Hamza Ouarnoughi, Jean-Emile DARTOIS, Nicolas Guyomard
* \copyright (C) Copyright 2015-2016 b<>com
*
* This program is free software; you can redistribute it and/or
* modify it under the terms of the GNU General Public Licence
* as published by the Free Software Foundation; either version
* 2 of the Licence, or (at your option) any later version.
***************************************************************/

#include "iotracer_util.h"

/* VFS level probes handlers */
#include "probes/filemap_probes.h"

/* block I/O layer probes handlers */
#include "probes/block_probes.h"

#include "kprobes.h"

/**
 * register_iotracer_probes - probes registration
 *
 * TODO: give the traced level as parameter
 */
int register_iotracer_probes(void)
{
	int ret = 0;

	/* Register block probes */
	ret = register_block_probes();
	if (!ret) {
		/* Register filemap probes */
		ret = register_filemap_probes();
		if (ret) {
			IOTRACER_ERROR("fail to register filemap probes\n");
			unregister_block_probes();
		}
	} else
		IOTRACER_ERROR("fail to register block probes\n");

	return ret;
}

/**
 * unregister_iotracer_probes - probes unregistration
 */
void unregister_iotracer_probes(void)
{
	unregister_block_probes();
	unregister_filemap_probes();
}

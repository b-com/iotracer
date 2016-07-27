# !/usr/bin/python3
# -*- encoding: utf-8 -*-
#
# Copyright 2015-2016 b<>com
#
# This program is free software; you can redistribute it and/or modify it
# under the terms and conditions of the GNU General Public License,
# version 2, as published by the Free Software Foundation.
#
# This program is distributed in the hope it will be useful, but WITHOUT
# ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
# FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for
# more details.

import os
import subprocess


def clear_cache():
    # flush file system buffers
    os.sync()
    # force kernel to drop clean caches
    try:
        subprocess.check_call("sudo sh -c 'echo 3 > /proc/sys/vm/drop_caches'",
                              stderr=subprocess.STDOUT,
                              universal_newlines=True,
                              shell=True)
    except Exception as err:
        print('Fail to drop clean caches: %s' % (err))

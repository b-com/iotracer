#!/bin/sh
#/*!**************************************************************
#* \copyright (C) Copyright 2015-2016 b<>com
#* This program is free software; you can redistribute it and/or
#* modify it under the terms of the GNU General Public Licence
#* as published by the Free Software Foundation; either version
#* 2 of the Licence, or (at your option) any later version.
#***************************************************************/

# clear_cache
# clean FS cache
clear_cache() {
    sync
    sudo sysctl vm.drop_caches=3 > /dev/null
}

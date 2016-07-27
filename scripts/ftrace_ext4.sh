#!/bin/sh
#/*!**************************************************************
#* \copyright (C) Copyright 2015-2016 b<>com
#* This program is free software; you can redistribute it and/or
#* modify it under the terms of the GNU General Public Licence
#* as published by the Free Software Foundation; either version
#* 2 of the Licence, or (at your option) any later version.
#***************************************************************/

mkdir /debug
mount -t debugfs nodev /debug
echo 0 >/debug/tracing/tracing_on
echo 'ext4_*' 'journal_*' > /debug/tracing/set_ftrace_filter
echo function >/debug/tracing/current_tracer
echo 1 >/debug/tracing/tracing_on
gedit /var/log/messages &
sleep 3
echo 0 >/debug/tracing/tracing_enabled
cat /debug/tracing/trace

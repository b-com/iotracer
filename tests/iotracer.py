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

from enum import Enum, unique


@unique
class IoLevel(Enum):
    BLK = 1
    FS = 2
    VFS = 3


# IO event
class IoEvent:
    def __init__(self, event_str):
        [time, io_type, address, size,
         level, task_name, task_pid] = event_str.split(';')
        
        self.time = time
        self.type = io_type
        self.address = int(address)
        self.size = int(size)
        self.level = getattr(IoLevel, level)
        self.task_name = task_name
        self.task_pid = int(task_pid)
    
    def __str__(self):
        return ('%s - %s access by %s(%s) at %s level : addr = %s , size = %s'
                % (self.time,
                   self.type, self.task_name, self.task_pid, self.level.name,
                   self.address, self.size))


# Iterator on IoTracer events
# If level is specified only events at this level will be returned
class _IoTracerIterator:
    def __init__(self, logfile_name, level=None):
        self._logfile = open(logfile_name, 'r')
        self._level = level
        if level and not isinstance(level, IoLevel):
            raise TypeError
    
    def __iter__(self):
        return self
    
    def __next__(self):
        line = self._logfile.readline()
        while line:
            event = IoEvent(line.rstrip('\n'))
            if not self._level:
                return event
            elif event.level == self._level:
                return event
            else:
                # current event is not at filtered level, get next
                line = self._logfile.readline()
        else:
            raise StopIteration
    
    def __del__(self):
        self._logfile.close()


# Log of iotracer kernel module
class IoTracerLog:
    def __init__(self, log):
        self._log = log
    
    def __iter__(self):
        return _IoTracerIterator(self._log)
    
    def events(self, level=None):
        return _IoTracerIterator(self._log, level=level)


# Interface to iotracer kernel module
class IoTracer(IoTracerLog):
    def __init__(self, filename, max_events=0):
        if not os.path.exists("/proc/iotracer"):
            raise AssertionError('iotracer kernel module is not loaded')
        
        self._filename = filename
        cmd = 'readlink -e $(df --output=source ' + filename + ' | tail -1)'
        cmd += ' | cut -d/ -f3'
        try:
            out = subprocess.check_output(cmd, stderr=subprocess.DEVNULL,
                                          universal_newlines=True,
                                          shell=True)
        except subprocess.SubprocessError:
            print('fail to get block device for %s' % filename)
            raise
        else:
            bdev = out.rstrip(b'\n')
            try:
                ino = os.stat(filename).st_ino
                with open('/proc/iotracer/control', 'w') as fctl:
                    cmd = 'add %s' % self._filename
                    if max_events:
                        cmd += ' %s' % max_events
                    print(cmd, file=fctl)
            except OSError:
                print('fail to add %s to iotracer monitoring' % filename)
                raise
            else:
                self._procdir = '/proc/iotracer/%s_%s' % (bdev, ino)
                IoTracerLog.__init__(self, self._procdir + '/log')
    
    def __del__(self):
        if os.path.exists("/proc/iotracer"):
            with open('/proc/iotracer/control', 'w') as fctl:
                print('remove %s' % self._filename, file=fctl)
    
    def filename(self):
        return self._filename
    
    def stop(self):
        with open(self._procdir + '/control', 'w') as fctl:
            print('stop', file=fctl)
    
    def start(self):
        with open(self._procdir + '/control', 'w') as fctl:
            print('start', file=fctl)
    
    def reset(self, timereset=False):
        with open(self._procdir + '/control', 'w') as fctl:
            if timereset:
                print('timereset', file=fctl)
            else:
                print('reset', file=fctl)
    
    def _control_file_data(self):
        with open(self._procdir + '/control', 'r') as fctl:
            return fctl.readline().split()
    
    def is_active(self):
        return bool(self._control_file_data()[0])
    
    def time_zero(self):
        return self._control_file_data()[1]
    
    def max_events(self):
        return int(self._control_file_data()[2])
    
    def num_events(self):
        return int(self._control_file_data()[3])

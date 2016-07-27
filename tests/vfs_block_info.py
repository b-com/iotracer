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

import argparse
import re
import math

from collections import namedtuple
from abc import ABCMeta

import iotracer

file_extent = namedtuple('file_extent',
                         'logical_offset physical_offset length')


class FileExtentsListPrototype(metaclass=ABCMeta):
    def __init__(self):
        self._extent_tab = None
        self._block_size = None
        self._nb_blocks = None
        self._filesize = None
        self._filepath = None

    def get_filepath(self):
        return self._filepath
    
    def get_filesize(self):
        return self._filesize
    
    def get_nb_blocks(self):
        return self._nb_blocks
    
    def get_block_size(self):
        return self._block_size
    
    def get_extent_tab(self):
        return self._extent_tab


""" 
    List of extents of a file
    That is list of contiguous blocks allocated in the file system
    to store data of the file
"""


class FileExtentsList:
    def __init__(self, prototype):
        self.filepath = prototype.get_filepath()
        self.filesize = prototype.get_filesize()
        self.nb_blocks = prototype.get_nb_blocks()
        self.block_size = prototype.get_block_size()
        self._extent_tab = prototype.get_extent_tab()
    
    def extent_from_logical_offset(self, offset):
        extent = None
        for e in self._extent_tab:
            if ((e.logical_offset <= offset) and
                    (offset < e.logical_offset + e.length)):
                extent = e
                break
        return extent
    
    def extent_from_physical_offset(self, offset):
        extent = None
        for e in self._extent_tab:
            if ((e.physical_offset <= offset) and
                    (offset < e.physical_offset + e.length)):
                extent = e
                break
        return extent


""" 
    Class allowing to create FileExtentsList corresponding to a specific file
    from output of command "filefrag -v" on this file
"""


class FilefragOutputParser(FileExtentsListPrototype):
    def __init__(self, filename):
        super(FilefragOutputParser).__init__()
        self._filepath = filename
        self._extent_tab = []
        self._parse_filefrag_output(filename)
    
    def _parse_fs_type(self, file):
        self._fs_type = None
        line = file.readline()
        while line and self._fs_type is None:
            m = re.match(r"^Filesystem type is: (?P<fs_type>\w+)$", line)
            if m:
                self._fs_type = m.group("fs_type")
            else:
                line = file.readline()
        return self._fs_type is not None
    
    def _parse_sizes(self, file):
        self._filesize = None
        self._nb_blocks = None
        self._block_size = None
        line = file.readline()
        while line and self._block_size is None:
            m = re.match(
r"^File size of (?P<filepath>.+?) is (?P<file_size>\d+) \((?P<nb_blocks>\d+) blocks of (?P<block_size>\d+) bytes\)$",
                line)
            if m:
                self._filepath = m.group("filepath")
                self._filesize = int(m.group("file_size"))
                self._nb_blocks = int(m.group("nb_blocks"))
                self._block_size = int(m.group("block_size"))
            else:
                line = file.readline()
        return self._block_size is not None
    
    def _parse_extents(self, file):
        line = file.readline()
        if line:
            if re.match(
                    r"^ ext: +logical_offset: +physical_offset: +length: +expected: +flags:$",
                    line):
                line = file.readline()
                while (line):
                    m = re.match(
                        r"^ +\d+: +(?P<logical_start>\d+).. +(?P<logical_end>\d+): +(?P<physical_start>\d+).. +(?P<physical_end>\d+): +(?P<length>\d+):",
                        line)
                    if m:
                        self._extent_tab.append(
                            file_extent(int(m.group("logical_start")),
                                        int(m.group("physical_start")),
                                        int(m.group("length"))))
                        line = file.readline()
                    else:
                        break
    
    def _parse_filefrag_output(self, filename):
        with open(filename, 'r') as filefrag_output:
            if self._parse_fs_type(filefrag_output):
                if self._parse_sizes(filefrag_output):
                    self._parse_extents(filefrag_output)


""" 
    Giving FileExtentsList corresponding to a file and I/O Tracer log
    of access to this file, display for each VFS access the corresponding
    block access it should produce
"""


def vfs_to_block(iotracer_log, file_extents, directio):
    for event in iotrace.events():
        print("%s:%s:%s:%s:%s:%s:%s" % (event.time,
                                        event.type,
                                        event.address,
                                        event.size,
                                        event.level.name,
                                        event.task_name,
                                        event.task_pid))
        if event.level is iotracer.IoLevel.VFS:
            address = event.address
            size = event.size
            while size > 0:
                block_index = int(address / filemap.block_size)
                offset_in_block = address - (block_index * filemap.block_size)
                extent = filemap.extent_from_logical_offset(block_index)
                if extent:
                    offset_in_extent = block_index - extent.logical_offset
                    if directio:
                        physical_address = (int(offset_in_block / 512) +
                                            (int(filemap.block_size / 512) *
                                             (offset_in_extent +
                                              extent.physical_offset)))
                        block_access_size = event.size
                    else:
                        physical_address = (int(filemap.block_size / 512) *
                                            (offset_in_extent +
                                             extent.physical_offset))
                        nb_blocks = math.ceil((size + offset_in_block)
                                              / filemap.block_size)
                        if nb_blocks > (extent.length - offset_in_extent):
                            nb_blocks = extent.length
                        block_access_size = nb_blocks * filemap.block_size
                    print("->\t%s:%s:BLK" % (
                        physical_address, block_access_size))
                    size -= block_access_size
                    address += block_access_size
                else:
                    raise Exception("Warning: no extent for block_index %s" % (
                        block_index))


if __name__ == "__main__":
    # create the argument's parser
    parser = argparse.ArgumentParser()
    parser.add_argument('iotracerlog', help='file containing iotracer log')
    parser.add_argument('filefrag',
                        help='file containing output of command filefrag -v')
    parser.add_argument('--directio', action='store_true',
                        help='log corresponds to direct I/O access')
    
    # parse argument lists
    args = parser.parse_args()
    
    try:
        iotrace = iotracer.IoTracerLog(args.iotracerlog)
    except Exception as e:
        print('Failed to parse iotracer log', e)
    else:
        try:
            filemap = FileExtentsList(FilefragOutputParser(args.filefrag))
        except Exception as e:
            print('Failed to parse filefrag output', e)
        else:
            try:
                vfs_to_block(iotrace, filemap, args.directio)
            except Exception as e:
                print(e)

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

import sys
import os
import subprocess
import argparse

from collections import Counter
from collections import defaultdict
from collections import OrderedDict

import iotracer


# IO statistics
class IoStats:
    _ordered_keys = ["events",
                     "time", "dtr", "iops",
                     "read_bytes", "r_seq_rate", "r_rand_rate",
                     "write_bytes", "w_seq_rate", "w_rand_rate"]
    
    """
        nb_ios          -- number of IOs
        exe_t           -- time between first and last IO
        dtr             -- Data Transfer Rate
        iops            -- I/O Operations Per Second
        read_bytes      -- size read in bytes
        seq_read_rate   -- percentage of sequential reads
        rand_read_rate  -- percentage of random reads
        write_bytes     -- size written in bytes
        seq_write_rate  -- percentage of sequential writes
        rand_write_rate -- percentage of random writes
    """
    
    def __init__(self, nb_ios, exe_t, dtr, iops,
                 read_bytes, seq_read_rate, rand_read_rate,
                 write_bytes, seq_write_rate, rand_write_rate):
        self.events = nb_ios
        self.time = exe_t
        self.read_bytes = read_bytes
        self.write_bytes = write_bytes
        self.w_seq_rate = seq_write_rate
        self.w_rand_rate = rand_write_rate
        self.r_seq_rate = seq_read_rate
        self.r_rand_rate = rand_read_rate
        self.dtr = dtr
        self.iops = iops
    
    def to_dict(self):
        return OrderedDict([(k, getattr(self, k)) for k in self._ordered_keys])
    
    def __str__(self):
        statstr = "\n".join(["events=%s" % self.events,
                             "time=%s dtr=%s iops=%s" % (self.time,
                                                         self.dtr,
                                                         self.iops),
                             "read: io=%s seq=%s rand=%s" % (self.read_bytes,
                                                             self.r_seq_rate,
                                                             self.r_rand_rate),
                             "write: io=%s seq=%s rand=%s" % (self.write_bytes,
                                                              self.w_seq_rate,
                                                              self.w_rand_rate)])
        return statstr


class IoTracerStats(IoStats):
    """
        nb_ios       -- number of IOs
        exe_t        -- time between first and last IO
        read_bytes   -- size read in bytes
        r_seq        -- number of sequential reads
        r_rnd        -- number of random reads
        write_bytes  -- size written in bytes
        w_seq        -- number of sequential writes
        w_rnd        -- number of random writes
        map_dict     -- dict of memory areas accessed by IOs
                        key is the start adress of the area
                        value is the size of the area
        io_size_list -- ist of IO sizes
    """
    
    def __init__(self, nb_ios, exe_t,
                 read_bytes, r_seq, r_rnd,
                 write_bytes, w_seq, w_rnd,
                 map_dict, io_size_list):
        
        (w_seq_rate, w_rand_rate,
         r_seq_rate, r_rand_rate) = self._calc_type_rates(nb_ios,
                                                          w_seq, w_rnd,
                                                          r_seq, r_rnd)
        (dtr, iops) = self._calc_transfer_rates(exe_t,
                                                read_bytes + write_bytes)
        
        IoStats.__init__(self, nb_ios, exe_t, dtr, iops,
                         read_bytes, r_seq_rate, r_rand_rate,
                         write_bytes, w_seq_rate, w_rand_rate)
        
        self._calc_io_dist(io_size_list)
    
    def _calc_type_rates(self, nb_ios, w_seq, w_rnd, r_seq, r_rnd):
        w_seq_rate = 0.0
        w_rand_rate = 0.0
        r_seq_rate = 0.0
        r_rand_rate = 0.0
        
        if nb_ios > 0:
            w_seq_rate = round(float(w_seq) / nb_ios, 4)
            w_rand_rate = round(float(w_rnd) / nb_ios, 4)
            r_seq_rate = round(float(r_seq) / nb_ios, 4)
            r_rand_rate = round(float(r_rnd) / nb_ios, 4)
        
        return w_seq_rate, w_rand_rate, r_seq_rate, r_rand_rate
    
    def _calc_transfer_rates(self, exe_t, io_size_in_bytes):
        dtr = 0
        iops = 0
        
        if exe_t > 0:
            dtr = round((float(io_size_in_bytes) / 1024.0) / exe_t)
            iops = round(10 ** 9 * (io_size_in_bytes / 4096) /
                         int(10 ** 9 * exe_t))
        
        return dtr, iops
    
    def _calc_io_dist(self, io_size_list):
        self.io_dist = defaultdict(float)
        
        io_dist = Counter(io_size_list)
        total_counts = sum(io_dist.values())
        for size in io_dist.keys():
            self.io_dist[size] = io_dist[size] / total_counts
    
    def __str__(self):
        statstr = "\n".join(["%s" % (super().__str__()), "size distribution:"])
        for io_size in sorted(self.io_dist.keys()):
            io_size_val = self.io_dist.get(io_size)
            if io_size_val >= 0.01:
                statstr = "\n".join([statstr,
                                     "%s\t%.4f" % (io_size, io_size_val)])
        
        return statstr


class IoProfiler:
    def __init__(self, iotracer_log):
        if not isinstance(iotracer_log, iotracer.IoTracerLog):
            raise TypeError
        else:
            self._iotrace = iotracer_log
    
    # Calculate IO statistics for an iotracer log level
    def stats(self, level=iotracer.IoLevel.BLK):
        if not isinstance(level, iotracer.IoLevel):
            raise TypeError
        else:
            stats = None
            
            if level is iotracer.IoLevel.BLK:
                io_size = 512
            elif level is iotracer.IoLevel.FS:
                io_size = 4096
            elif level is iotracer.IoLevel.VFS:
                io_size = 1
            
            nb_ios = 0
            time_tab = []
            size_tab = []
            prev_addr = None
            
            map_dict = defaultdict(int)
            
            w_seq = 0
            w_rnd = 0
            r_seq = 0
            r_rnd = 0
            read_bytes = 0
            write_bytes = 0
            prev_map_addr = None
            for event in self._iotrace.events(level):
                # Is it sequential?
                random_access = False
                if nb_ios > 0:
                    if event.address != (prev_addr + (size_tab[-1] / io_size)):
                        random_access = True
                        map_dict[event.address] = max(
                            int(event.size / io_size),
                            map_dict[event.address])
                        prev_map_addr = event.address
                    else:
                        map_dict[prev_map_addr] += int(event.size / io_size)
                else:
                    map_dict.update({event.address: int(event.size / io_size)})
                    prev_map_addr = event.address
                
                nb_ios += 1
                time_tab.append(float(event.time))
                prev_addr = event.address
                size_tab.append(event.size)
                
                # Calculate the <read/write>_<rand/seq> rates
                # Is it a write IO?
                if event.type == 'W':
                    write_bytes += event.size
                    if random_access:
                        w_rnd += 1
                    else:
                        w_seq += 1
                else:
                    read_bytes += event.size
                    if random_access:
                        r_rnd += 1
                    else:
                        r_seq += 1
            
            if nb_ios > 0:
                stats = IoTracerStats(nb_ios, time_tab[-1] - time_tab[0],
                                      read_bytes, r_seq, r_rnd,
                                      write_bytes, w_seq, w_rnd,
                                      map_dict, size_tab)
            
            return stats
    
    def __str__(self):
        retstr = ""
        for level in iotracer.IoLevel:
            stats = self.stats(level)
            if stats:
                retstr = "\n".join([retstr,
                                    "---- %s ----" % level.name,
                                    "%s" % stats])
        return retstr


"""
    Class allowing to execute a command and get IO statistics corresponding to
    execution of this command.
    If multiple executions of the command is done (multiple calls to exec()),
    only I/O statistics reagrding last execution will be returned by stats()
"""


class CommandIoProfiler(IoProfiler):
    def __init__(self, command, file):
        self._cmd = command
        try:
            io_tracer = iotracer.IoTracer(file, os.stat(file).st_blocks * 2)
        except Exception:
            raise
        else:
            self._io_tracer = io_tracer
            super().__init__(io_tracer)
    
    def __del__(self):
        if self._io_tracer:
            del self._io_tracer
    
    def exec(self):
        self._iotrace.reset()
        try:
            subprocess.check_call(self._cmd, stderr=subprocess.STDOUT,
                                  universal_newlines=True,
                                  shell=True)
        except subprocess.CalledProcessError as err:
            print('%s failed:\n%s' % (args.cmd, err.output))
            raise
        except:
            print('Failed to execute command "%s"' % args.cmd)
            raise


def get_log_profile(args):
    print(IoProfiler(iotracer.IoTracerLog(args.logfile)))


def get_command_profile(args):
    try:
        profiler = CommandIoProfiler(args.cmd, args.file)
    except Exception:
        raise
    else:
        try:
            profiler.exec()
        except:
            sys.exit(1)
        else:
            print(profiler)


"""
    Check that, for each key in allowed_diff dict, the relative differecnce
    between the values of the attribute of stats and expected_stats whose name
    is this key, is coherent with the corresponding value of the dict.
    This value (allowed_diff|key]) must be a tuple whose first element is
    the minimum allowed difference (in percentage) and the second element is
    the maximum allowed difference (also in percentage)
"""


def check_stats(stats, expected_stats, allowed_diff):
    for name in allowed_diff:
        value = getattr(stats, name)
        expected_value = getattr(expected_stats, name)
        if expected_value > 0:
            min_value = expected_value * (100 - allowed_diff[name][0]) / 100
            max_value = expected_value * (100 + allowed_diff[name][1]) / 100
            if value < min_value or value > max_value:
                print('Bad value for %s: %s not in [ %s , %s ]' % (name,
                                                                   value,
                                                                   min_value,
                                                                   max_value))


"""
      Check that statistics corresponding to an iotracer log are coherent
      with expected data.

      args.logfile must be the name of the file containing iotracer
      args.descfilemust be the name of the file describing expected statistics,
      that is defining the following constants:

      size:                    total size for I/O in bytes
      blocksize:               block size for I/O in bytes
      read_bytes:              total size for read I/O in bytes
      write_bytes:             total size for write I/O in bytes
      percentage_random_read:  percentage of reads using random access [0-100]
      percentage_random_write: percentage of writes using random access [0-100]
      percentage_ios_diff:     percentage of allowed overhead in number of
                               events
                               logged compared to expected value [0-100]
      percentage_read_diff:    percentage of allowed overhead in size of
                               reads logged compared to expected value [0-100]
      percentage_write_diff:   percentage of allowed overhead in size of
                               writes logged compared to expected value [0-100]
      percentage_rate_diff:    percentage of allowed difference between
                               observed and expected value for rates
                               ([sequential|random] [read|write] rates) [0-100]
"""


def check_log_profile(args):
    profiler = IoProfiler(iotracer.IoTracerLog(args.logfile))
    vfs_stats = profiler.stats(iotracer.IoLevel.VFS)
    if not vfs_stats:
        print('no VFS data !')
        return
    
    # put constants defined in descfile in a new directory (desc)
    desc = {}
    with open(args.descfile) as descfile:
        exec(descfile.read(), desc)
        
        read_bytes = desc['read_bytes']
        write_bytes = desc['write_bytes']
        expected_stats = IoStats(
            desc['size'] / desc['blocksize'],
            0,
            0,
            0,
            read_bytes,
            ((100 - desc['percentage_random_read']) * read_bytes
             / (desc['size'] * 100)),
            desc['percentage_random_read'] * read_bytes / (desc['size'] * 100),
            write_bytes,
            ((100 - desc['percentage_random_write']) * write_bytes
             / (desc['size'] * 100)),
            (desc['percentage_random_write'] * write_bytes
             / (desc['size'] * 100)))
        
        allowed_diff = {
            'events': (0, desc['percentage_ios_diff']),
            'read_bytes': (0, desc['percentage_read_diff']),
            'write_bytes': (0, desc['percentage_write_diff']),
            'r_rand_rate': (desc['percentage_rate_diff'],
                            desc['percentage_rate_diff']),
            'r_seq_rate': (desc['percentage_rate_diff'],
                           desc['percentage_rate_diff']),
            'w_rand_rate': (desc['percentage_rate_diff'],
                            desc['percentage_rate_diff']),
            'w_seq_rate': (desc['percentage_rate_diff'],
                           desc['percentage_rate_diff']),
        }
        
        check_stats(vfs_stats, expected_stats, allowed_diff)
        
        if args.directio:
            block_stats = profiler.stats(iotracer.IoLevel.BLK)
            
            if not block_stats:
                print('no BLOCK data !')
                return
            
            if not vfs_stats.read_bytes == block_stats.read_bytes:
                print('Inconsistent read size: VFS = %s BLK = %s' %
                      (vfs_stats.read_bytes, block_stats.read_bytes))
            
            if not vfs_stats.write_bytes == block_stats.write_bytes:
                print('Inconsistent write size: VFS = %s BLK = %s' %
                      (vfs_stats.write_bytes, block_stats.write_bytes))
            
            for name in ['events', 'read_bytes', 'write_bytes']:
                del allowed_diff[name]
            check_stats(block_stats, expected_stats, allowed_diff)


if __name__ == "__main__":
    # create the top-level parser
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers()
    
    # create the parser for the "log" command
    parser_log = subparsers.add_parser('log', help='create from iotracer log')
    parser_log.add_argument('logfile', help='file containing iotracer log')
    parser_log.set_defaults(func=get_log_profile)
    
    # create the parser for the "exec" command
    parser_cmd = subparsers.add_parser(
        'exec',
        help='create from execution of a command')
    parser_cmd.add_argument('cmd', help='command to execute')
    parser_cmd.add_argument('file', help='file to monitor')
    parser_cmd.set_defaults(func=get_command_profile)
    
    # create the parser for the "check" command
    parser_check = subparsers.add_parser(
        'check',
        help='check iotracer log with expected data')
    parser_check.add_argument('logfile', help='file containing iotracer log')
    parser_check.add_argument('descfile', help='file describing expected data')
    parser_check.add_argument('--directio', action='store_true',
                              help='log correspond to direct I/O access')
    parser_check.set_defaults(func=check_log_profile)
    
    # parse argument lists
    args = parser.parse_args()
    
    if len(vars(args)) > 0:
        # do the work
        args.func(args)
    else:
        parser.print_usage()

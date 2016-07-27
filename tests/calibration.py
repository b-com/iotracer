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
import sys
import re

from pathlib import Path
from collections import defaultdict
from collections import OrderedDict

import numpy
import iotracer
import io_profile
import linux_utils


class CalibrationData:
    _npstats = ["amin", "amax", "mean", "std", "median"]
    
    def __init__(self):
        self._stats = {}
    
    def update_from_dict(self, level, data_d):
        if len(data_d) > 0:
            dtype = numpy.dtype(
                {'names': list(data_d.keys()),
                 'formats': list(numpy.obj2sctype(v)
                                 for v in list(data_d.values()))
                 })
            self.update_from_array(level,
                                   numpy.array([tuple(list(data_d.values()))],
                                               dtype=dtype))
    
    def update_from_array(self, level, array):
        if level in self._stats.keys():
            self._stats[level] = numpy.concatenate((self._stats[level],
                                                    array))
        else:
            self._stats.update({level: array})
    
    def _stats_to_str(self, array):
        outstr = "data\t%s" % ("\t".join(self._npstats))
        for data in array.dtype.names:
            datastr = "%s" % data
            for stat in self._npstats:
                func = getattr(numpy, stat)
                datastr = "\t".join([datastr, "%s" % (func(array[data]))])
            outstr = "\n".join([outstr, datastr])
        return outstr
    
    def __str__(self):
        outstr = ""
        for level in iotracer.IoLevel:
            if level in self._stats.keys():
                outstr = "\n".join([outstr,
                                    "--- %s ---" % level.name,
                                    self._stats_to_str(self._stats[level])])
        return outstr


class BaseCalibration(CalibrationData):
    def execute(self):
        self._do_calibration()
    
    def _do_calibration(self):
        raise NotImplementedError()


class IoProfileLogCalibration(BaseCalibration):
    def __init__(self, logdirpath):
        super().__init__()
        self._logdirpath = logdirpath
        self._level_parser = LevelParser()
    
    def _parse_logfile(self, logfile_path):
        try:
            logfile = logfile_path.open("r")
        except Exception as e:
            print('fail to read %s: %s' % (logfile_path, e))
        else:
            stats = {}
            io_dist = {}
            line = logfile.readline()
            while line:
                m = re.match(r"^---- (?P<level>\w+) ----$", line)
                if m:
                    (level_stats, level_io_dist) = self._level_parser.parse(
                        logfile)
                    stats.update({m.group('level'): level_stats})
                    io_dist.update({m.group('level'): level_io_dist})
                line = logfile.readline()
            
            for level in iotracer.IoLevel:
                if level.name in stats:
                    self.update_from_dict(level, stats[level.name])
            
            logfile.close()
    
    def _do_calibration(self):
        for logpath in sorted(self._logdirpath.glob('*.log')):
            self._parse_logfile(logpath)


class CommandCalibration(BaseCalibration):
    def __init__(self, file, command, time):
        super().__init__()
        self._file = file
        self._command = command
        self._time = time
    
    def _do_calibration(self):
        try:
            profiler = io_profile.CommandIoProfiler(self._command, self._file)
        except Exception:
            raise
        else:
            for i in range(self._time - 1):
                self._do_command_profiling(profiler)
    
    def _do_command_profiling(self, profiler):
        linux_utils.clear_cache()
        try:
            profiler.exec()
        except:
            raise
        else:
            linux_utils.clear_cache()
            for level in iotracer.IoLevel:
                stats = profiler.stats(level)
                if stats:
                    self.update_from_dict(level, stats.to_dict())


class LevelParser:
    _stats_patterns = [r"^events=(?P<events>\d+)$",
                       " ".join([r"^time=(?P<time>\d+\.\d+)",
                                 r"dtr=(?P<dtr>\d+)",
                                 r"iops=(?P<iops>\d+)$"]),
                       " ".join([r"^read:",
                                 r"io=(?P<read_bytes>\d+)",
                                 r"seq=(?P<r_seq_rate>[01]\.\d+)",
                                 r"rand=(?P<r_rand_rate>[01]\.\d+)$"]),
                       " ".join([r"^write:",
                                 r"io=(?P<write_bytes>\d+)",
                                 r"seq=(?P<w_seq_rate>[01]\.\d+)",
                                 r"rand=(?P<w_rand_rate>[01]\.\d+)$"])]
    
    _int_stats = ["events", "dtr", "iops", "read_bytes", "write_bytes"]
    _float_stats = ["time",
                    "r_seq_rate", "r_rand_rate",
                    "w_seq_rate", "w_rand_rate"]
    
    def __init__(self):
        self._parsing_files = []
        self._pos_before_read = defaultdict(int)
    
    def _readline(self, logfile):
        self._pos_before_read[logfile] = logfile.tell()
        return logfile.readline()
    
    def _unreadline(self, logfile):
        logfile.seek(self._pos_before_read[logfile])
    
    def _parse_stats(self, logfile):
        stat_dict = OrderedDict()
        for pattern in self._stats_patterns:
            line = self._readline(logfile)
            if not line:
                break
            else:
                p = re.compile(pattern)
                m = p.match(line)
                if not m:
                    self._unreadline(logfile)
                    break
                else:
                    # sort in regular expression positional order
                    for k, v in sorted(p.groupindex.items(),
                                       key=lambda t: t[1]):
                        stat_dict.update({k: m.groupdict()[k]})
        if len(stat_dict) < 10:
            stat_dict.clear()
        else:
            self._fix_stat_type(stat_dict)
        return stat_dict
    
    def _fix_stat_type(self, stat_dict):
        for stat in self._int_stats:
            stat_dict[stat] = int(stat_dict[stat])
        for stat in self._float_stats:
            stat_dict[stat] = float(stat_dict[stat])
    
    def _parse_io_distribution(self, logfile):
        io_dist = defaultdict(float)
        line = self._readline(logfile)
        while line:
            m = re.match(r"^(?P<io_size>\d+)\s(?P<frequency>[01]\.\d+)$", line)
            if not m:
                self._unreadline(logfile)
                break
            else:
                io_dist[m.group("io_size")] = m.group("frequency")
                line = self._readline(logfile)
        return io_dist
    
    def parse(self, logfile):
        io_dist = None
        if logfile in self._parsing_files:
            raise Exception("already parsing file %s" % logfile.name)
        else:
            self._parsing_files.append(logfile)
            stat_dict = self._parse_stats(logfile)
            line = self._readline(logfile)
            if line:
                m = re.match(r"^size distribution:$", line)
                if m:
                    io_dist = self._parse_io_distribution(logfile)
                else:
                    self._unreadline(logfile)
            del self._pos_before_read[logfile]
            self._parsing_files.remove(logfile)
            return stat_dict, io_dist


def get_log_calibration(args):
    dirpath = Path(args.directory)
    if not dirpath.is_dir():
        parser.print_usage()
        sys.exit(2)
    
    calibration = IoProfileLogCalibration(dirpath)
    calibration.execute()
    print(calibration)


def get_command_calibration(args):
    calibration = CommandCalibration(args.file, args.cmd, int(args.time))
    calibration.execute()
    print(calibration)


if __name__ == "__main__":
    # create the top-level parser
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers()
    
    # create the parser for the "log" command
    parser_log = subparsers.add_parser(
        'log',
        help='create from io_profile log directory')
    parser_log.add_argument('directory',
                            help='directory containing ioprofile log files')
    parser_log.set_defaults(func=get_log_calibration)
    
    # create the parser for the "cmd" command
    parser_cmd = subparsers.add_parser(
        'exec',
        help='create from execution of a command')
    parser_cmd.add_argument('cmd', help='command to execute')
    parser_cmd.add_argument('time', help='number of executions')
    parser_cmd.add_argument('file', help='file to monitor')
    parser_cmd.set_defaults(func=get_command_calibration)
    
    # parse argument lists
    args = parser.parse_args()
    
    if len(vars(args)) > 0:
        # do the work
        args.func(args)
    else:
        parser.print_usage()

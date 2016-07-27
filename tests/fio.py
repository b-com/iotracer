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

import subprocess


# fio job statistics
class JobStat:
    # Position of fields in the fio terse output
    _job_name_pos = 2
    _read_status_pos = 5
    _io_status_size = 4 + 2 * 4 + 20 + 4 + 5
    _write_status_pos = _read_status_pos + _io_status_size
    _cpu_usage_pos = _write_status_pos + _io_status_size
    _cpu_usage_size = 5
    _io_depth_distrib_pos = _cpu_usage_pos + _cpu_usage_size
    _io_lat_distrib_pos = _io_depth_distrib_pos + 7
    _disk_use_pos = _io_lat_distrib_pos + 10 + 12
    _disk_use_size = 9
    
    # fio read/write statistics
    class IoStat:
        def __init__(self, io, bw, iops, runt):
            self.iosize = io
            self.bw = bw
            self.iops = iops
            self.time = runt
        
        def __str__(self):
            return 'io=%s bw=%s iops=%s time=%s' % (self.iosize,
                                                    self.bw,
                                                    self.iops,
                                                    self.time)
    
    # fio cpu usage statistics
    class CpuStat:
        def __init__(self, usr, sys, ctx):
            self.user = usr
            self.system = sys
            self.context_switch = ctx
        
        def __str__(self):
            return 'u=%s s=%s cs=%s' % (self.user,
                                        self.system,
                                        self.context_switch)
    
    # fio disk statistics
    class DiskStat:
        def __init__(self, disk, ios, merge, ticks, in_queue, util):
            self.name = disk
            self.read_ios = ios["read"]
            self.write_ios = ios["write"]
            self.read_merges = merge["read"]
            self.write_merges = merge["write"]
            self.read_ticks = ticks["read"]
            self.write_ticks = ticks["write"]
            self.inqueue = in_queue
            self.util = util
        
        def __str__(self):
            return '\n\t'.join(['%s u=%s inq=%s' % (self.name,
                                                    self.util,
                                                    self.inqueue),
                                'read=%s merges=%s t=%s' % (self.read_ios,
                                                            self.read_merges,
                                                            self.read_ticks),
                                'write=%s merges=%s t=%s' % (self.write_ios,
                                                             self.write_merges,
                                                             self.write_ticks)]
                               )
    
    def _parse_io_stats(self, fio_stats):
        return JobStat.IoStat(int(fio_stats[0]),
                              int(fio_stats[1]),
                              int(fio_stats[2]),
                              int(fio_stats[3]))
    
    def _parse_cpu_stats(self, fio_stats):
        return JobStat.CpuStat(fio_stats[0],
                               fio_stats[1],
                               int(fio_stats[2]))
    
    def _parse_disk_stats(self, fio_stats):
        return JobStat.DiskStat(fio_stats[0],
                                {'read': int(fio_stats[1]),
                                 'write': int(fio_stats[2])},
                                {'read': int(fio_stats[3]),
                                 'write': int(fio_stats[4])},
                                {'read': int(fio_stats[5]),
                                 'write': int(fio_stats[6])},
                                int(fio_stats[7]),
                                fio_stats[8])
    
    def __init__(self, fio_terse_output):
        fio_stats = fio_terse_output.split(';')
        self.read = self._parse_io_stats(fio_stats[
                                         self._read_status_pos:
                                         self._read_status_pos +
                                         self._io_status_size])
        
        self.write = self._parse_io_stats(fio_stats[
                                          self._write_status_pos:
                                          self._write_status_pos +
                                          self._io_status_size])
        self.cpu = self._parse_cpu_stats(fio_stats[
                                         self._cpu_usage_pos:
                                         self._cpu_usage_pos +
                                         self._cpu_usage_size])
        
        self.disk = self._parse_disk_stats(fio_stats[
                                           self._disk_use_pos:
                                           self._disk_use_pos +
                                           self._disk_use_size])
    
    def __str__(self):
        return 'read: %s\nwrite: %s\ncpu: %sdisk: %s\n' % (self.read,
                                                           self.write,
                                                           self.cpu,
                                                           self.disk)


# fio job
class Job:
    def __init__(self, jobname, filename, filesize, blocksize=4096,
                 write=True, read=True, random=False, numloops=1):
        self._jobname = jobname
        if write:
            if read:
                iotype = 'rw'
            else:
                iotype = 'write'
        else:
            if read:
                iotype = 'read'
            else:
                print('Error: write or false must be True')
                raise ValueError
        if random:
            pattern_type = 'rand' + iotype
        else:
            pattern_type = iotype
        self._args = {
            'rw': pattern_type,
            'bs': blocksize,
            'loops': numloops,
            'filename': filename,
            'filesize': '%sk' % filesize
        }
    
    def name(self):
        return self._jobname
    
    def args(self):
        argstr = ''
        for k, v in self._args.items():
            argstr += '--{0}={1} '.format(k, v)
        return argstr


# Interface to fio process for execution of jobs
class Executor:
    class FioTerseOutput:
        
        def __init__(self, fio_output):
            self._stats = {}
            lines = fio_output.splitlines()
            for line in lines:
                fio_stats = fio_output.split(';')
                jobname = fio_stats[2]
                jobstat = JobStat(line)
                self._stats.update({jobname: jobstat})
        
        def get_job_stats(self, jobname):
            job_stat = None
            if jobname in self._stats:
                job_stat = self._stats[jobname]
            return job_stat
    
    def __init__(self, joblist, ioengine="libaio"):
        self._joblist = joblist
        self._ioengine = ioengine
        self._fio_output = None
    
    def execute(self):
        #        cmd = 'fio --minimal --debug=process --gtod_reduce=1'
        cmd = 'fio --minimal --gtod_reduce=1'
        cmd = " ".join([cmd,
                        '--name=global --ioengine=%s --end_fsync=1'
                        % self._ioengine])
        for job in self._joblist:
            cmd = " ".join([cmd,
                            '--name="%s" %s' % (job.name(), job.args())])
        try:
            out = subprocess.check_output(cmd, stderr=subprocess.STDOUT,
                                          universal_newlines=True,
                                          shell=True)
        except subprocess.CalledProcessError as err:
            print('fio failed:\n\t' + err.output)
            raise
        except:
            print('Failed to execute command "%s"' % cmd)
            raise
        else:
            self._fio_output = Executor.FioTerseOutput(out)
    
    def jobstat(self, job):
        job_stat = None
        if (job in self._joblist) and self._fio_output:
            job_stat = self._fio_output.get_job_stats(job.name())
        return job_stat

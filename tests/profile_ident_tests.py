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

import unittest

import os

import fio
import iotracer
import io_profile


# Class to test ability of iotracer to identify profiles
class TestIoTracerProfileIdent(unittest.TestCase):
    _test_steps = ['_seq_write_test', '_rand_write_test',
                   '_seq_read_test', '_rand_read_test']
    _ioengine = ['libaio', 'posixaio', 'sync', 'psync', 'vsync', 'pvsync']
    
    def setUp(self):
        testdir_path = '/tmp/iotracer_tests'
        seqfile_name = 'sequential-tests.bin'
        randfile_name = 'random-tests.bin'
        self.seqfile_path = testdir_path + '/' + seqfile_name
        self.randfile_path = testdir_path + '/' + randfile_name
        
        os.makedirs(testdir_path, exist_ok=True)
        testdir_statvfs = os.statvfs(testdir_path)
        
        free_blocks = testdir_statvfs.f_bavail
        self.block_size = testdir_statvfs.f_bsize
        
        # Use 40% of available blocks for each test file
        # but do not use file length greater than 1GB
        testfile_blocks = min(int(2 * free_blocks / 5),
                              int(1024 * 1024 * 1024 / self.block_size))
        self.testfile_size = int(testfile_blocks * self.block_size / 1024)
        
        # Create file to test sequential access
        open(self.seqfile_path, 'wb').close()
        
        # Start monitoring seqfile
        self.seqfile_iotracer = iotracer.IoTracer(self.seqfile_path,
                                                  testfile_blocks * 3)
        self.seqfile_profiler = io_profile.IoProfiler(self.seqfile_iotracer)
        
        # Create file to test random access
        open(self.randfile_path, 'wb').close()
        
        self.randfile_iotracer = iotracer.IoTracer(self.randfile_path,
                                                   testfile_blocks * 3)
        self.randfile_profiler = io_profile.IoProfiler(self.randfile_iotracer)
    
    def tearDown(self):
        if self.seqfile_iotracer:
            self.seqfile_profiler = None
            self.seqfile_iotracer.__del__()
            self.seqfile_iotracer = None
        if self.randfile_iotracer:
            self.randfile_profiler = None
            self.randfile_iotracer.__del__()
            self.randfile_iotracer = None
        if os.path.exists(self.seqfile_path):
            os.remove(self.seqfile_path)
        if os.path.exists(self.randfile_path):
            os.remove(self.randfile_path)
    
    # Test that sequential writes profile is correctly recognised
    def _seq_write_test(self, ioengine):
        print('execute sequential write test for %s...' % ioengine)
        seq_write_job = fio.Job('seq write',
                                self.seqfile_iotracer.filename(),
                                self.testfile_size,
                                self.block_size,
                                write=True, read=False)
        
        self.seqfile_iotracer.start()
        self.seqfile_iotracer.reset()
        
        fio_exe = fio.Executor([seq_write_job], ioengine)
        fio_exe.execute()
        
        jobstats = fio_exe.jobstat(seq_write_job)
        
        # Check that there is only write ios
        self.assertEqual(0, jobstats.read.iosize, msg='unexpected read size')
        # Check that write size is correct
        self.assertEqual(self.testfile_size, jobstats.write.iosize,
                         msg='unexpected write size')
        
        self.seqfile_iotracer.stop()
        block_stats = self.seqfile_profiler.stats(iotracer.IoLevel.BLK)
        
        vfs_stats = self.seqfile_profiler.stats(iotracer.IoLevel.VFS)
        
        # Check that there is only write ios
        for io_stats in [vfs_stats, block_stats]:
            self.assertEqual(1,
                             io_stats.w_seq_rate + io_stats.w_rand_rate,
                             msg='unexpected write rate')
            self.assertEqual(0,
                             io_stats.r_seq_rate + io_stats.r_rand_rate,
                             msg='unexpected read rate')
        # Check that write size is correct
        for io_stats in [vfs_stats, block_stats]:
            self.assertEqual(self.testfile_size * 1024, io_stats.write_bytes,
                             msg='unexpected write size')
        
        # Check that ios are sequentially writes
        self.assertEqual(1, vfs_stats.w_seq_rate,
                         msg='unexpected write rates : seq=%s rand=%s' %
                             (vfs_stats.w_seq_rate, vfs_stats.w_rand_rate))
    
    # Test that random writes profile is correctly recognised
    def _rand_write_test(self, ioengine):
        print('execute random write test for %s...' % ioengine)
        rand_write_job = fio.Job('random write',
                                 self.randfile_iotracer.filename(),
                                 self.testfile_size,
                                 self.block_size,
                                 write=True, read=False, random=True)
        
        self.randfile_iotracer.start()
        self.randfile_iotracer.reset()
        
        fio_exe = fio.Executor([rand_write_job], ioengine)
        fio_exe.execute()
        
        jobstats = fio_exe.jobstat(rand_write_job)
        
        vfs_stats = self.randfile_profiler.stats(iotracer.IoLevel.VFS)
        
        # Check that there is only write ios
        self.assertEqual(0, jobstats.read.iosize,
                         msg='unexpected read size')
        # Check that write size is correct
        self.assertEqual(self.testfile_size, jobstats.write.iosize,
                         msg='unexpected write size')
        
        self.randfile_iotracer.stop()
        block_stats = self.randfile_profiler.stats(iotracer.IoLevel.BLK)
        
        # Check that there is only write ios
        for io_stats in [vfs_stats, block_stats]:
            self.assertEqual(1,
                             io_stats.w_seq_rate + io_stats.w_rand_rate,
                             msg='unexpected write rate')
            self.assertEqual(0,
                             io_stats.r_seq_rate + io_stats.r_rand_rate,
                             msg='unexpected read rate')
        
        # Check that write size is correct
        for io_stats in [vfs_stats, block_stats]:
            self.assertEqual(self.testfile_size * 1024, io_stats.write_bytes)
        
        # Check that ios are randomly writes
        self.assertTrue(vfs_stats.w_seq_rate < vfs_stats.w_rand_rate,
                        msg='unexpected write rates : seq=%s rand=%s' %
                            (vfs_stats.w_seq_rate, vfs_stats.w_rand_rate))
    
    # Test that sequential reads profile is correctly recognised
    def _seq_read_test(self, ioengine):
        print('execute sequential read test for %s...' % ioengine)
        seq_read_job = fio.Job('sequential read',
                               self.seqfile_iotracer.filename(),
                               self.testfile_size,
                               self.block_size,
                               read=True, write=False)
        
        self.seqfile_iotracer.start()
        self.seqfile_iotracer.reset()
        
        fio_exe = fio.Executor([seq_read_job], ioengine)
        fio_exe.execute()
        
        jobstats = fio_exe.jobstat(seq_read_job)
        
        # Check that there is only read ios
        self.assertEqual(0, jobstats.write.iosize,
                         msg='unexpected write size')
        # Check that read size is correct
        self.assertEqual(self.testfile_size, jobstats.read.iosize,
                         msg='unexpected read size')
        
        self.seqfile_iotracer.stop()
        block_stats = self.seqfile_profiler.stats(iotracer.IoLevel.BLK)
        vfs_stats = self.seqfile_profiler.stats(iotracer.IoLevel.VFS)
        
        # Check that there is only read ios
        for io_stats in [vfs_stats, block_stats]:
            self.assertEqual(0,
                             io_stats.w_seq_rate + io_stats.w_rand_rate,
                             msg='unexpected write rate')
            self.assertEqual(1,
                             io_stats.r_seq_rate + io_stats.r_rand_rate,
                             msg='unexpected read rate')
        
        # Check that read size is correct
        for io_stats in [vfs_stats, block_stats]:
            self.assertEqual(self.testfile_size * 1024, io_stats.read_bytes,
                             msg='unexpected read size')
        
        # Check that ios are sequentially reads
        self.assertEqual(1, vfs_stats.r_seq_rate,
                         msg='unexpected read rates : seq=%s rand=%s' %
                             (vfs_stats.r_seq_rate, vfs_stats.r_rand_rate))
    
    # Test that random reads profile is correctly recognised
    def _rand_read_test(self, ioengine):
        print('execute random read test for %s...' % ioengine)
        rand_read_job = fio.Job('random read',
                                self.randfile_iotracer.filename(),
                                self.testfile_size,
                                self.block_size,
                                read=True, write=False, random=True)
        
        self.randfile_iotracer.start()
        self.randfile_iotracer.reset()
        
        fio_exe = fio.Executor([rand_read_job], ioengine)
        fio_exe.execute()
        
        jobstats = fio_exe.jobstat(rand_read_job)
        
        # Check that there is only read ios
        self.assertEqual(0, jobstats.write.iosize,
                         msg='unexpected write size')
        # Check that read size is correct
        self.assertEqual(self.testfile_size, jobstats.read.iosize,
                         msg='unexpected read size')
        
        self.randfile_iotracer.stop()
        block_stats = self.randfile_profiler.stats(iotracer.IoLevel.BLK)
        vfs_stats = self.randfile_profiler.stats(iotracer.IoLevel.VFS)
        
        # Check that there is only read ios
        for io_stats in [vfs_stats, block_stats]:
            self.assertEqual(0,
                             io_stats.w_seq_rate + io_stats.w_rand_rate,
                             msg='unexpected write rate')
            self.assertEqual(1,
                             io_stats.r_seq_rate + io_stats.r_rand_rate,
                             msg='unexpected read rate')
        
        # Check that read size is correct
        for io_stats in [vfs_stats, block_stats]:
            self.assertEqual(self.testfile_size * 1024, io_stats.read_bytes,
                             msg='unexpected read size')
        
        # Check that ios are randomly reads
        self.assertTrue(vfs_stats.r_seq_rate < vfs_stats.r_rand_rate,
                        msg='unexpected read rates : seq=%s rand=%s' %
                            (vfs_stats.r_seq_rate, vfs_stats.r_rand_rate))
    
    def test_steps(self):
        for ioengine in self._ioengine:
            with self.subTest(ioengine=ioengine):
                for name in self._test_steps:
                    try:
                        getattr(self, name)(ioengine)
                    except Exception as e:
                        self.fail("{} failed ({}: {})".format(name,
                                                              str(type(e)), e))


if __name__ == "__main__":
    unittest.main()

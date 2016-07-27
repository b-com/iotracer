#!/bin/bash
#/*!**************************************************************
#* \copyright (C) Copyright 2015-2016 b<>com
#* This program is free software; you can redistribute it and/or
#* modify it under the terms of the GNU General Public Licence
#* as published by the Free Software Foundation; either version
#* 2 of the Licence, or (at your option) any later version.
#***************************************************************/


#== global variables 

IOTRACER_PATH=$(readlink -e "$(dirname "$0")/..")

TEST_DIR=/tmp/iotracer_test

DEFAULT_MAX_EVENTS=20

#== functions

# function clear_cache
. "${IOTRACER_PATH}"/scripts/cache_func.sh

# iotracer wrapper functions
. "${IOTRACER_PATH}"/scripts/iotracer_func.sh

# load framework tests
. "${IOTRACER_PATH}"/tests/assert.sh

assert_module_load() {
  load_iotracer MAX_EVENTS=${DEFAULT_MAX_EVENTS}
  assert "echo $?" "0"
  
  assert_raises "lsmod | grep \"${IOTRACER_MODULE_NAME}\"" 0
  assert_raises "test -d /sys/module/\"${IOTRACER_MODULE_NAME}\"/parameters" 0
  assert "cat /sys/module/\"${IOTRACER_MODULE_NAME}\"/parameters/MAX_EVENTS" ${DEFAULT_MAX_EVENTS}
  assert_raises "test -d \"${IOTRACER_PROC_DIR}\"" 0
  assert_raises "test -f \"${IOTRACER_CONTROL}\"" 0
  assert_raises "test -z \"$(cat "${IOTRACER_CONTROL}")\"" 0
}

assert_module_unload() {
  unload_iotracer
  assert "echo $?" "0"
  
  assert_raises "test -f \"${IOTRACER_CONTROL}\"" 1
  assert_raises "test -d \"${IOTRACER_PROC_DIR}\"" 1
  assert_raises "lsmod | grep \"${IOTRACER_MODULE_NAME}\"" 1
}

# assert_monitor_file <filename> [num_events]
assert_monitor_file() {
  monitor_file "$1" "$2"

  local proc_dir=$(monitored_file_procdir "$1")
  
  assert "awk -v filename=\"$1\" '\$0 ~ filename { print \$1 }' \"${IOTRACER_CONTROL}\"" "$(basename "${proc_dir}")"

  assert_raises "test -d \"${proc_dir}\"" 0
  assert_raises "test -f \"${proc_dir}/control\"" 0
  assert_raises "test -f \"${proc_dir}/log\"" 0
  assert "awk '{ print \$1 \" \" \$3 \" \" \$4 }' \"${proc_dir}/control\"" "1 ${2:-${DEFAULT_MAX_EVENTS}} 0"
  assert "cat \"${proc_dir}/log\"" ""
}

# unmonitor_file <filename>
assert_unmonitor_file() {
  unmonitor_file "$1"

  local proc_dir=$(monitored_file_procdir "$1")

  assert_raises "test -f \"${proc_dir}/control\"" 1
  assert_raises "test -f \"${proc_dir}/log\"" 1
  assert_raises "test -d \"${proc_dir}\"" 1

  assert "awk -v filename=\"$1\" '\$0 ~ filename' \"${IOTRACER_CONTROL}\"" ""
}

assert_stop_monitoring_file() {
  # assert_stop_monitoring_file <filename>
  
  local proc_dir=$(monitored_file_procdir "$1")
  mkdir -p "${TEST_DIR}/${proc_dir}"

  stop_monitoring_file "$1"

  cat "${proc_dir}/control" > "${TEST_DIR}/${proc_dir}/control.old"
  cat "${proc_dir}/log" > "${TEST_DIR}/${proc_dir}/log.old"

  assert "awk '{print \$1}' \"${TEST_DIR}/${proc_dir}/control.old\"" "0"

  dd if=/dev/urandom of="$1" bs=8k count=100 status=none
  cat "${proc_dir}/control" > "${TEST_DIR}/${proc_dir}/control.new"
  cat "${proc_dir}/log" > "${TEST_DIR}/${proc_dir}/log.new"

  assert_raises "cmp \"${TEST_DIR}/${proc_dir}/control.old\" \"${TEST_DIR}/${proc_dir}/control.new\"" 0
  assert_raises "cmp \"${TEST_DIR}/${proc_dir}/log.old\" \"${TEST_DIR}/${proc_dir}/log.new\"" 0

  rm -fr "${TEST_DIR}/${proc_dir}"
}

assert_start_monitoring_file() {
  # assert_stop_monitoring_file <filename>
  
  local proc_dir=$(monitored_file_procdir "$1")
  mkdir -p "${TEST_DIR}/${proc_dir}"

  start_monitoring_file "$1"

  cat "${proc_dir}/control" > "${TEST_DIR}/${proc_dir}/control.old"
  cat "${proc_dir}/log" > "${TEST_DIR}/${proc_dir}/log.old"

  assert "awk '{print \$1}' \"${TEST_DIR}/${proc_dir}/control.old\"" "1"

  dd if=/dev/urandom of="$1" bs=8k count=100 status=none
  cat "${proc_dir}/control" > "${TEST_DIR}/${proc_dir}/control.new"
  cat "${proc_dir}/log" > "${TEST_DIR}/${proc_dir}/log.new"

  assert_raises "cmp \"${TEST_DIR}/${proc_dir}/control.old\" \"${TEST_DIR}/${proc_dir}/control.new\"" 1
  assert_raises "cmp \"${TEST_DIR}/${proc_dir}/log.old\" \"${TEST_DIR}/${proc_dir}/log.new\"" 1

  rm -fr "${TEST_DIR}/${proc_dir}"
}

assert_reset_file_log() {
  # assert_reset_file_log <filename>
  
  local proc_dir=$(monitored_file_procdir "$1")
  mkdir -p "${TEST_DIR}/${proc_dir}"

  cat "${proc_dir}/control" > "${TEST_DIR}/${proc_dir}/control.old"

  reset_file_log "$1"

  cat "${proc_dir}/control" > "${TEST_DIR}/${proc_dir}/control.new"

  assert "cat \"${proc_dir}/log\"" ""
  assert "awk '{print \$4}' \"${TEST_DIR}/${proc_dir}/control.new\"" "0"
  assert "awk '{print \$1 \" \" \$2 \" \" \$3}' ${TEST_DIR}/${proc_dir}/control.new" \
         "$(awk '{print $1 " " $2 " " $3}' "${TEST_DIR}/${proc_dir}/control.old")"

  rm -fr "${TEST_DIR}/${proc_dir}"
}

assert_timereset_file_log() {
  # assert_timereset_file_log <filename>
  
  local proc_dir=$(monitored_file_procdir "$1")
  mkdir -p "${TEST_DIR}/${proc_dir}"

  cat "${proc_dir}/control" > "${TEST_DIR}/${proc_dir}/control.old"
  
  timereset_file_log "$1"

  cat "${proc_dir}/control" > "${TEST_DIR}/${proc_dir}/control.new"
  
  assert "cat \"${proc_dir}/log\"" ""
  assert "awk '{print \$4}' \"${TEST_DIR}/${proc_dir}/control.new\"" "0"
  assert "awk '{print \$1 \" \" \$3}' ${TEST_DIR}/${proc_dir}/control.new" \
         "$(awk '{print $1 " " $3}' "${TEST_DIR}/${proc_dir}/control.old")"
  assert_raises "test $(awk '{print $2}' "${TEST_DIR}/${proc_dir}/control.old") != \
                      $(awk '{print $2}' "${TEST_DIR}/${proc_dir}/control.new")" \
                0

  rm -fr "${TEST_DIR}/${proc_dir}"
}

#== unitary tests

# check that module can be loaded

assert_module_load

assert_end module_load

mkdir -p ${TEST_DIR}
touch ${TEST_DIR}/testfile_1
touch ${TEST_DIR}/testfile_2

# check add of a new file to monitor

assert_monitor_file ${TEST_DIR}/testfile_1 

assert_end monitor_file

# check that write events are saved

dd if=/dev/urandom of=${TEST_DIR}/testfile_1 bs=8k count=100  status=none
check_file_log_contains_only_write "${TEST_DIR}/testfile_1"
assert "echo $?" "0"

assert_end log_write

# check control of the log

assert_stop_monitoring_file ${TEST_DIR}/testfile_1

assert_reset_file_log ${TEST_DIR}/testfile_1

assert_start_monitoring_file ${TEST_DIR}/testfile_1

assert_timereset_file_log ${TEST_DIR}/testfile_1

assert_end log_control

# check remove of a file from sensor

assert_unmonitor_file ${TEST_DIR}/testfile_1

assert_end unmonitor_file

# check that read events are saved

clear_cache

assert_monitor_file ${TEST_DIR}/testfile_1
assert_monitor_file ${TEST_DIR}/testfile_2 $(( DEFAULT_MAX_EVENTS * 2 ))

cat ${TEST_DIR}/testfile_1 ${TEST_DIR}/testfile_1 > ${TEST_DIR}/testfile_2
sync

check_file_log_contains_only_read "${TEST_DIR}/testfile_1"
assert "echo $?" "0"

check_file_log_contains_only_write "${TEST_DIR}/testfile_2"
assert "echo $?" "0"

assert_unmonitor_file ${TEST_DIR}/testfile_1
assert_unmonitor_file ${TEST_DIR}/testfile_2

assert_end log_read

# check links are correctly managed

ln ${TEST_DIR}/testfile_1 ${TEST_DIR}/testfile_1.link
assert_monitor_file ${TEST_DIR}/testfile_1 
assert_monitor_file ${TEST_DIR}/testfile_1.link
unmonitor_file ${TEST_DIR}/testfile_1
assert "awk -v filename=\"^${TEST_DIR}/testfile_1\$\" '\$0 ~ filename' \"${IOTRACER_CONTROL}\"" ""
cat ${TEST_DIR}/testfile_1 > /dev/null
sync

check_file_log_contains_only_read "${TEST_DIR}/testfile_1.link"
assert "echo $?" "0"
assert_unmonitor_file ${TEST_DIR}/testfile_1.link

assert_end links

# test unload of the module

assert_module_unload

assert_end module_unload

rm -fr ${TEST_DIR}

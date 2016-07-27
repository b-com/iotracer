#/*!**************************************************************
#* \copyright (C) Copyright 2015-2016 b<>com
#* This program is free software; you can redistribute it and/or
#* modify it under the terms of the GNU General Public Licence
#* as published by the Free Software Foundation; either version
#* 2 of the Licence, or (at your option) any later version.
#***************************************************************/

cmd_path=$_
script=$0

if [ -n "${BASH_SOURCE}" ]; then
  # shell is bash
  if [ "${script}" != "${BASH_SOURCE[0]}" ]; then
    script_sourced=true
    script=${BASH_SOURCE[0]}
  else
    script_sourced=false
  fi
else
  # shell is not bash
  if [ "${cmd_path}" = "${script}" ]; then
    script_sourced=true
    # As there is no way to get path of this file, caller must set IOTRACER_PATH
    if [ -z "${IOTRACER_PATH}" ]; then
      echo IOTRACER_PATH must be set
      exit 1
    fi
  else
    script_sourced=false
  fi
fi

if [ -z "${IOTRACER_PATH}" ]; then
  IOTRACER_PATH=$(readlink -e "$(dirname "${script}")/..")
fi

if [ -z "${IOTRACER_PATH}" ]; then
  echo IOTRACER_PATH not set
  exit 1
fi

#== global variables

export IOTRACER_MODULE_NAME
IOTRACER_MODULE_NAME=iotracer
export IO_TRACER_PROC_DIR
IOTRACER_PROC_DIR=/proc/${IOTRACER_MODULE_NAME}
export IOTRACER_CONTROL
IOTRACER_CONTROL=${IOTRACER_PROC_DIR}/control

#== functions

# load_iotracer [max_events]
# load iotracer kernel module
load_iotracer() {
  sudo insmod "${IOTRACER_PATH}/src/${IOTRACER_MODULE_NAME}.ko" "$@"
}

# unload_iotracer
# unload iotracer kernel module
unload_iotracer() {
  sudo rmmod "${IOTRACER_MODULE_NAME}"
}

# file_to_bdev <filename>
# return name of block device containing a file
file_to_bdev() {
  local bdev_path=$(df --output=source "$1" | tail -1)
  readlink -e "${bdev_path}" | cut -d/ -f3
}

# file_to_inode <filename>
# return inode number a file
file_to_inode() {
  stat --format="%i" "$1"
}

# monitor_file <filename> [num_events]
# add a file to iotracer monitoring
monitor_file() {
  echo "add $1 $2" > "${IOTRACER_CONTROL}"
}

# unmonitor_file <filename>
# remove a file to iotracer monitoring
unmonitor_file() {
  echo "remove $1" > "${IOTRACER_CONTROL}"
}

# monitored_file_procdir <filename>
# return directory in procfs corresponding to iotracer monitoring of a file
monitored_file_procdir() {
  echo "${IOTRACER_PROC_DIR}/$(file_to_bdev "$1")_$(file_to_inode "$1")"
}

# stop_monitoring_file <filename>
# pause monitoring of a file
stop_monitoring_file() {
  echo stop > "$(monitored_file_procdir "$1")/control"
}

# start_monitoring_file <filename>
# restart monitoring of a file
start_monitoring_file() {
  echo start > "$(monitored_file_procdir "$1")/control"
}

# reset_file_log <filename>
# empty iotracer log of a file
reset_file_log() {
  echo reset > "$(monitored_file_procdir "$1")/control"
}

# timereset_file_log <filename>
# reset iotracer log of a file
timereset_file_log() {
  echo timereset > "$(monitored_file_procdir "$1")/control"
}

# check_file_log_contains_only_write <filename>
check_file_log_contains_only_write() {
  local proc_dir=$(monitored_file_procdir "$1")

  local nb_events=$(awk '{print $4}' "${proc_dir}/control")
  local w_events=$(awk -F\; '$2=="W"' "${proc_dir}/log" | wc -l)
  test "${w_events} -gt 0 -a ${w_events} = ${nb_events}"
}

# check_file_log_contains_only_read <filename>
check_file_log_contains_only_read() {
  local proc_dir=$(monitored_file_procdir "$1")

  local nb_events=$(awk '{print $4}' "${proc_dir}/control")
  local r_events=$(awk -F\; '$2=="R"' "${proc_dir}/log" | wc -l)
  test "${r_events} -gt 0 -a ${r_events} = ${nb_events}"
}

if [ "${script_sourced}" = "false" -a $# -ge 1 ]; then
  eval "$@"
fi

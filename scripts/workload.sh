#!/bin/sh
#/*!**************************************************************
#* \copyright (C) Copyright 2015-2016 b<>com
#* This program is free software; you can redistribute it and/or
#* modify it under the terms of the GNU General Public Licence
#* as published by the Free Software Foundation; either version
#* 2 of the Licence, or (at your option) any later version.
#***************************************************************/

show_usage() {
  echo "Usage: $0 {create|exec} <io_pattern> [<size>]"
  exit 3
}

clear_cache() {
    sync
    sudo sysctl vm.drop_caches=3 > /dev/null
}

if [ $# -lt 2 ]; then
  show_usage
fi

pattern="$2"

iolog="${pattern}".iolog

case "$1" in
  create)
    if [ $# -gt 2 ]; then
        size="$3"
    else
        size="250M"
    fi
    clear_cache
    fio --output=/dev/null --gtod_reduce=1 --name="${pattern}" --ioengine=sync --direct=1 --end_fsync=1 --bs=4096 --rw="${pattern}" --size="${size}" --write_iolog="${iolog}"
    clear_cache
    ;;
  exec)
    if [ ! -r "${iolog}" ]; then
      echo Cannot read "${iolog}"
      exit 2
    fi
    clear_cache
    fio --output=/dev/null --gtod_reduce=1 --name="${pattern}" --ioengine=sync --direct=1 -read_iolog="${iolog}"
    clear_cache
    ;;
  *)
    show_usage
    ;;
esac


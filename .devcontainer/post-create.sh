#!/bin/bash
sudo apt update
sudo apt install -y \
  cpio \
  u-boot-tools \
  netpbm

git submodule update --init --recursive

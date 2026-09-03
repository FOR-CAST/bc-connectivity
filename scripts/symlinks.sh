#!/bin/bash

## Optional convenience: put the bulky, machine-independent parts on shared storage so several
## machines (and collaborators) work against one copy. Nothing in the code requires this -- paths
## all go through get_path() / district_path(), and the pipeline creates plain directories if these
## are absent. Edit the prefix below, or skip this script entirely.

PREFIX=/mnt/projects/HRV/BC_CONN

ln -s "$PREFIX"/_targets ./
ln -s "$PREFIX"/Data ./
ln -s "$PREFIX"/Outputs ./
ln -s "$PREFIX"/Teams ./

## Per-district stores (see _targets.yaml). Sharing these is what makes a district build resumable
## from any machine: work done on one host is visible from the others.
##
## `targets` does not lock a store across hosts, so do not run the SAME project on two machines at
## once -- different projects in parallel are fine, which is the point of splitting them.
for d in quesnel chilcotin hundred_mile; do
  ln -s "$PREFIX"/_targets_dataprep_"$d" ./
  ln -s "$PREFIX"/_targets_omniscape_"$d" ./
done

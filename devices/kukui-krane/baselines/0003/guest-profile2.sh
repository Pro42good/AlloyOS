#!/bin/sh
sleep 20
awk '{pid=FILENAME; sub("/proc/","",pid); sub("/stat","",pid); comm=$2; gsub(/[()]/,"",comm); print pid, comm, $14, $15}' /proc/[0-9]*/stat > /tmp/prof.cpu0
awk '{fn=FILENAME; pid=fn; sub("/proc/","",pid); sub("/status","",pid); if ($1=="voluntary_ctxt_switches:") v=$2; if ($1=="nonvoluntary_ctxt_switches:") print pid, v+0, $2}' /proc/[0-9]*/status > /tmp/prof.ctx0
awk '{fn=FILENAME; pid=fn; sub("/proc/","",pid); sub("/io","",pid); if ($1=="write_bytes:") print pid, $2}' /proc/[0-9]*/io > /tmp/prof.w0 2>/dev/null
cp /proc/vmstat /tmp/prof.vm0; grep '^intr ' /proc/stat > /tmp/prof.i0
sleep 60
awk '{pid=FILENAME; sub("/proc/","",pid); sub("/stat","",pid); comm=$2; gsub(/[()]/,"",comm); print pid, comm, $14, $15}' /proc/[0-9]*/stat > /tmp/prof.cpu1
awk '{fn=FILENAME; pid=fn; sub("/proc/","",pid); sub("/status","",pid); if ($1=="voluntary_ctxt_switches:") v=$2; if ($1=="nonvoluntary_ctxt_switches:") print pid, v+0, $2}' /proc/[0-9]*/status > /tmp/prof.ctx1
awk '{fn=FILENAME; pid=fn; sub("/proc/","",pid); sub("/io","",pid); if ($1=="write_bytes:") print pid, $2}' /proc/[0-9]*/io > /tmp/prof.w1 2>/dev/null
cp /proc/vmstat /tmp/prof.vm1; grep '^intr ' /proc/stat > /tmp/prof.i1
cd /tmp && tar cf - prof.*

#!/bin/zsh
# Samples load once a second for S4 (docs/M0-PLAN.md): CPU % of the given process and of
# WindowServer (ps), and GPU "Device Utilization %" (ioreg IOAccelerator). No sudo.
# Usage: measure-load.sh <seconds> <pid or 0> > file.tsv
set -euo pipefail
seconds=$1 pid=$2
windowserver=$(pgrep -x WindowServer)
print "t\tprocessCPU\twindowServerCPU\tgpuDevicePercent"
for (( i = 0; i < seconds; i++ )); do
    proc=0
    (( pid > 0 )) && proc=$(ps -o %cpu= -p $pid 2>/dev/null | tr -d ' ' || print 0)
    ws=$(ps -o %cpu= -p $windowserver | tr -d ' ')
    gpu=$(ioreg -r -d 1 -c IOAccelerator | { grep -o '"Device Utilization %"=[0-9]*' || true; } | head -1 | cut -d= -f2)
    print "$i\t${proc:-0}\t$ws\t${gpu:-NA}"
    sleep 1
done

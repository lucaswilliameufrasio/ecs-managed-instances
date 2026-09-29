#!/usr/bin/env python3
"""Sample one Linux process's CPU share and resident memory to stdout CSV."""

import os
import sys
import time
from pathlib import Path


pid = int(sys.argv[1])
process = Path(f"/proc/{pid}")
clock_ticks = os.sysconf("SC_CLK_TCK")
previous_cpu = None
previous_time = None

while True:
    try:
        stat = (process / "stat").read_text(encoding="utf-8")
        fields = stat[stat.rfind(")") + 2 :].split()
        cpu_ticks = int(fields[11]) + int(fields[12])
        status = (process / "status").read_text(encoding="utf-8")
    except FileNotFoundError:
        break

    resident_kib = next(
        int(line.split()[1])
        for line in status.splitlines()
        if line.startswith("VmRSS:")
    )
    now = time.monotonic()
    if previous_cpu is not None and previous_time is not None:
        elapsed = now - previous_time
        cpu_percent = (cpu_ticks - previous_cpu) / clock_ticks / elapsed * 100
        print(f"{cpu_percent:.2f},{resident_kib / 1024:.2f}", flush=True)
    previous_cpu, previous_time = cpu_ticks, now
    time.sleep(1)

#!/usr/bin/env python3
"""Warm-X-server launch/exit benchmark; this is not cold startup time."""
import os
import statistics
import subprocess
import sys
import time

binary = sys.argv[1] if len(sys.argv) > 1 else './fastst-compat-gas'
count = int(sys.argv[2]) if len(sys.argv) > 2 else 40
samples = []
for i in range(count):
    t0 = time.perf_counter_ns()
    subprocess.run([binary, '-e', '/bin/true'], check=True,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    samples.append((time.perf_counter_ns() - t0) / 1e6)
values = sorted(samples)
print(f'runs={count} min={min(values):.2f} ms '
      f'median={statistics.median(values):.2f} ms '
      f'p90={values[max(0, int(.9*(count-1)))]:.2f} ms')

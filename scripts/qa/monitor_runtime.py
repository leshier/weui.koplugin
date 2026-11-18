"""Run the isolated native QA process and sample CPU/RSS without command lines."""
import csv
import os
import subprocess
import sys
import time

runtime, entrypoint, artifacts = sys.argv[1:]
process = subprocess.Popen([runtime, entrypoint], cwd=os.path.dirname(runtime))
with open(os.path.join(artifacts, "process.tsv"), "w", newline="") as output:
    writer = csv.writer(output, delimiter="\t")
    writer.writerow(["elapsed_s", "pid", "cpu_pct", "rss_kb"])
    started = time.monotonic()
    while process.poll() is None:
        sample = subprocess.run(
            ["ps", "-p", str(process.pid), "-o", "%cpu=", "-o", "rss="],
            capture_output=True, text=True, check=False,
        ).stdout.split()
        if len(sample) == 2:
            writer.writerow([f"{time.monotonic() - started:.2f}", process.pid, *sample])
            output.flush()
        time.sleep(0.2)
sys.exit(process.wait())

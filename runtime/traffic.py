#!/usr/bin/env python3
"""Run on EC2 through SSM: python3 traffic.py --scenario cpu --seconds 300."""
import argparse
import collections
import concurrent.futures
import time
import urllib.error
import urllib.request

parser = argparse.ArgumentParser()
parser.add_argument("--scenario", choices=["normal", "slow", "cpu", "error"], default="normal")
parser.add_argument("--seconds", type=int, default=120)
parser.add_argument("--workers", type=int, default=2)
parser.add_argument("--url", default="http://127.0.0.1:8080")
args = parser.parse_args()
if args.seconds < 1 or not 1 <= args.workers <= 8:
    parser.error("seconds must be positive; workers must be between 1 and 8")
end = time.monotonic() + args.seconds

def worker(_):
    counts = collections.Counter()
    while time.monotonic() < end:
        try:
            with urllib.request.urlopen(
                f"{args.url}/checkout?scenario={args.scenario}", timeout=10) as response:
                response.read()
                counts[response.status] += 1
        except urllib.error.HTTPError as exc:
            counts[exc.code] += 1
            exc.close()
        except (urllib.error.URLError, TimeoutError):
            counts["connection_error"] += 1
        time.sleep(0.2)
    return counts

with concurrent.futures.ThreadPoolExecutor(max_workers=args.workers) as pool:
    total = sum(pool.map(worker, range(args.workers)), collections.Counter())
print(dict(total))

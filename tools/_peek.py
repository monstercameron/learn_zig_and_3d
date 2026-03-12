import csv
rows = list(csv.DictReader(open('artifacts/perf/frame_times.csv')))
print(f"{'frame':>5s}  {'cpu_ms':>8s}  {'total_ms':>8s}  {'sw_wait':>8s}  {'present':>8s}")
for r in rows[::10]:
    print(f"{r['frame']:>5s}  {float(r['cpu_ms']):8.2f}  {float(r['total_ms']):8.2f}  {float(r['software_wait_ms']):8.2f}  {float(r['present_wait_ms']):8.2f}")

import csv

rows = list(csv.DictReader(open('artifacts/perf/frame_times.csv')))

print("=== SPIKE FRAMES (total_ms > 50) ===")
for r in rows:
    t = float(r['total_ms'])
    if t > 50:
        f = r['frame']
        c = float(r['cpu_ms'])
        s = float(r['software_wait_ms'])
        p = float(r['present_wait_ms'])
        d = float(r['deadline_error_ms'])
        print(f"  frame {f:>4s}  total={t:6.2f}  cpu={c:6.2f}  sw={s:6.2f}  present={p:6.2f}  deadline_err={d:6.2f}")

print()
data = rows[5:]  # skip warmup

totals = [float(r['total_ms']) for r in data]
cpus = [float(r['cpu_ms']) for r in data]
sw = [float(r['software_wait_ms']) for r in data]
pw = [float(r['present_wait_ms']) for r in data]
de = [float(r['deadline_error_ms']) for r in data]

print("=== BUDGET BREAKDOWN (excl 5 warmup) ===")
print(f"  cpu_ms:       mean={sum(cpus)/len(cpus):6.2f}  range=[{min(cpus):5.2f}, {max(cpus):5.2f}]")
print(f"  sw_wait_ms:   mean={sum(sw)/len(sw):6.2f}  range=[{min(sw):5.2f}, {max(sw):5.2f}]")
print(f"  present_wait: mean={sum(pw)/len(pw):6.2f}  range=[{min(pw):5.2f}, {max(pw):5.2f}]")
print(f"  total_ms:     mean={sum(totals)/len(totals):6.2f}  range=[{min(totals):5.2f}, {max(totals):5.2f}]")
print(f"  deadline_err: mean={sum(de)/len(de):6.2f}  range=[{min(de):5.2f}, {max(de):5.2f}]")
print()

# Frames where present_wait < 1ms (compensation ran out of budget)
no_comp = sum(1 for p in pw if p < 1.0)
print(f"  Frames with present_wait < 1ms: {no_comp}/{len(pw)} ({100*no_comp/len(pw):.1f}%)")

# Spike periodicity
spike_frames = [int(r['frame']) for r in rows if float(r['total_ms']) > 50]
if len(spike_frames) > 1:
    gaps = [spike_frames[i+1] - spike_frames[i] for i in range(len(spike_frames)-1)]
    print(f"  Spike frames: {spike_frames}")
    print(f"  Gaps between spikes: {gaps}")
    print(f"  Mean gap: {sum(gaps)/len(gaps):.1f} frames")
elif spike_frames:
    print(f"  Single spike at frame: {spike_frames}")

print()
# Characterize the sw_wait pattern - does it ramp/cycle?
print("=== SW_WAIT + PRESENT_WAIT PHASE PATTERN ===")
print("  (checking if they sum to a constant)")
sums = [s + p for s, p in zip(sw, pw)]
print(f"  sw+present sum: mean={sum(sums)/len(sums):6.2f}  range=[{min(sums):5.2f}, {max(sums):5.2f}]")

# Check: total = cpu + sw_wait + present_wait? Or is there unaccounted time?
unaccounted = [t - c - s - p for t, c, s, p in zip(totals, cpus, sw, pw)]
print(f"  Unaccounted:    mean={sum(unaccounted)/len(unaccounted):6.2f}  range=[{min(unaccounted):5.2f}, {max(unaccounted):5.2f}]")

# Show sw_wait declining pattern (frames 0-10)
print()
print("=== FIRST 20 FRAMES (warmup pattern) ===")
for r in rows[:20]:
    f = r['frame']
    t = float(r['total_ms'])
    c = float(r['cpu_ms'])
    s = float(r['software_wait_ms'])
    p = float(r['present_wait_ms'])
    d = float(r['deadline_error_ms'])
    print(f"  frame {f:>3s}  total={t:6.2f}  cpu={c:6.2f}  sw={s:6.2f}  present={p:6.2f}  derr={d:5.2f}")

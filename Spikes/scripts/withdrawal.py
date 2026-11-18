#!/usr/bin/env python3
"""M1 stage 2: input -> withdrawal and onset timings (M1-PLAN 7.2). All times are systemUptime.

usage: withdrawal.py <fixture input.jsonl> <capture.jsonl> <nagi trace.txt>
  fixture: NagiFixture --scene input (events "input" with eventTimestamp)
  capture: NagiSpike-granted --run capture --watch x,y over Nagi's debug patch ("watch" label)
  trace:   `log show` lines from Nagi --trace ("<event> t=<seconds>")

Per showing of nagi that input ended: the first input after it showed, the detection (phase
leaving), the overlay ordered out (hidden, watchdog or guard), and the first captured frame whose
watch label matches the label seen while nagi is not shown. Missing steps are counted.
Per onset: the last input before nagi entered, and the gap (T_onset is 3.0 s).
"""
import json
import re
import statistics
import sys


def jsonl(path):
    with open(path) as f:
        return [json.loads(line) for line in f if line.startswith("{")]


def percentiles(name, values):
    if not values:
        print(f"{name}: none")
        return
    values = sorted(values)
    p95 = values[min(len(values) - 1, int(len(values) * 0.95))]
    print(f"{name}: n={len(values)} min={values[0]*1000:.0f} p50={statistics.median(values)*1000:.0f} "
          f"p95={p95*1000:.0f} max={values[-1]*1000:.0f} ms")


# "-" instead of a fixture log: use the simulated inputs in the trace (--debug-fake-input).
fixture = [] if sys.argv[1] == "-" else jsonl(sys.argv[1])
inputs = sorted(e["eventTimestamp"] for e in fixture if e["event"] == "input")
clock = [e["now"] - e["eventTimestamp"] for e in fixture if e["event"] == "input"]
with open(sys.argv[3]) as f:
    inputs += sorted(float(m.group(1)) for m in re.finditer(r"fakeinput t=([0-9.]+)", f.read()))
watch = [(e["t"], e["labels"].get("watch")) for e in jsonl(sys.argv[2]) if e["event"] == "s4-sample"]
trace = []
with open(sys.argv[3]) as f:
    for line in f:
        m = re.search(r"\b(phase [a-z]+|shown|hidden|watchdog|guard cleanup|guard|stall|unstall)\b.*?t=([0-9.]+)", line)
        if m:
            trace.append((float(m.group(2)), m.group(1)))
trace.sort()

trace.append((float("inf"), "end"))
shown_at = [t for t, e in trace if e == "shown"]
# Windows ordered out: the normal path, the watchdog, or the cleanup after the guard. The guard
# itself only hides the layers (reported separately).
outs = [t for t, e in trace if e in ("hidden", "watchdog", "guard cleanup", "end")]
guard_hides = [t for t, e in trace if e == "guard"]
intervals = [(s, min(o for o in outs if o > s)) for s in shown_at]

# The watch point's label while nagi is not visible (after the guard hid the layers, too):
# what "gone" looks like.
# The capture logs label changes only, so take each sample's label as holding until the next one.
visible = [(s, min([o for o in outs + guard_hides if o > s])) for s in shown_at]
outside = [label for t, label in watch if not any(a <= t <= b for a, b in visible)]
before_first = [label for t, label in watch if shown_at and t < shown_at[0]]
candidates = outside or before_first
baseline = max(set(candidates), key=candidates.count) if candidates else "white"

stalls = [(t, next((u for u, e in trace if e == "unstall" and u > t), float("inf"))) for t, e in trace if e == "stall"]
detect, gone, captured, missing = [], [], [], {"detection": 0, "ordered out": 0, "captured": 0,
                                             "unmatched (nagi saw input before the fixture did)": 0}
gone_in_stall, layers_hidden = [], []
next_shown = {s: min([t for t in shown_at if t > s] + [float("inf")]) for s in shown_at}
for shown, out in intervals:
    first = next((x for x in inputs if shown < x <= out), None)
    if first is None:
        continue  # nagi ended without input (preview expiry, pause, end of run)
    # Nagi may see input the fixture never gets (a touch on the trackpad): then the fixture's
    # event did not trigger the withdrawal, and timing from it would understate.
    if any(e == "phase leaving" and shown < t < first for t, e in trace):
        missing["unmatched (nagi saw input before the fixture did)"] += 1
        continue
    leaving = next((t for t, e in trace if e == "phase leaving" and t >= first), None)
    if leaving is None or leaving > out:
        missing["detection"] += 1
    else:
        detect.append(leaving - first)
    if out == float("inf"):
        missing["ordered out"] += 1
    else:
        gone.append(out - first)
        if any(a <= first <= b for a, b in stalls):
            gone_in_stall.append(out - first)
        hid = next((t for t in guard_hides if first < t <= out), None)
        if hid:
            layers_hidden.append(hid - first)
    # Only this showing's samples, and only if the patch was seen before the input. The coarse
    # labels turn back to the baseline when the fading patch is nearly gone (alpha < ~0.15),
    # so this slightly understates; "ordered out" is the exact figure.
    seen = any(shown <= t <= first and label == "purple" for t, label in watch)
    frame = next((t for t, label in watch if first < t < next_shown[shown] and label == baseline), None)
    if not seen or frame is None:
        missing["captured"] += 1
    else:
        captured.append(frame - first)

onset = []
for t, e in trace:
    if e == "phase entering":
        before = [x for x in inputs if x <= t]
        if before:
            onset.append(t - before[-1])

print(f"inputs={len(inputs)}  NSEvent.timestamp vs systemUptime at handling: "
      f"min={min(clock)*1000:.1f} max={max(clock)*1000:.1f} ms" if clock else "no inputs")
percentiles("input -> detection (phase leaving)", detect)
percentiles("input -> ordered out", gone)
percentiles("input -> layers hidden by the guard", layers_hidden)
percentiles("input -> first captured frame with the background's label (coarse: a faint patch may remain)", captured)
percentiles("  of which the input fell in a main-thread stall: input -> windows ordered out", gone_in_stall)
percentiles("last input -> entering (onset)", onset)
print("baseline label:", baseline, " missing:", missing)
print("watchdog fired:", sum(1 for _, e in trace if e == "watchdog"), " guard fired:", len(guard_hides))

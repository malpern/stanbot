#!/usr/bin/env python3
"""Turn a head-following session log into one self-contained HTML page.

    python3 tools/follow_replay.py ~/Library/Logs/Stanbot/follow-20260916-165311.log
    python3 tools/follow_replay.py LOG --out replay.html

Reads what the app writes during a session: the robot's follow trace
(SBPD follow_trace: commanded and measured yaw and pitch, and the tracker mode),
its result (SBMV), loop stats (SBFL), power summary (SBPW), the telemetry
check, and the app's per-frame APP lines (faces found, selection state, the
target sent). Draws yaw, pitch and the face's position in the frame against
time, shaded by mode, and a summary: how far the head was from its goal, how
often it reversed, how many targets went out, and whether the telemetry
arrived intact.

Time alignment is approximate. The trace is timed from the robot's power
window opening; APP lines are timed by the Mac. The first APP line is taken as
time zero, which is when the app started the session, a fraction of a second
before the window opened. Stdlib only.
"""
import argparse
import html
import json
import os
import sys

MODES = {0: ("idle", "#9aa0a6"), 1: ("attending", "#1a73e8"), 2: ("returning", "#f29900"), 3: ("searching", "#9334e6")}


def parse(lines):
    """Everything the page needs, from the log's lines."""
    session = {"trace": [], "frames": [], "desk": [], "result": None, "loop": None, "power": None,
               "check": None, "telemetry": [], "in_block": False, "end": None}
    for raw in lines:
        line = raw.rstrip("\r\n")
        tag, _, body = line.partition(" ")
        try:
            data = json.loads(body) if body.startswith("{") else None
        except ValueError:
            data = None
        if tag == "SBTB":
            session["in_block"], session["telemetry"] = True, []
            continue
        if tag == "SBTE":
            session["in_block"], session["end"] = False, line
            continue
        if session["in_block"] and tag.startswith("SB"):
            session["telemetry"].append(line)
        if data is None:
            continue
        if tag == "SBPD" and data.get("phase") == "follow_trace":
            session["trace"].append(data)
        elif tag == "SBMV" and data.get("plan") == "follow":
            session["result"] = data
        elif tag == "SBFL":
            session["loop"] = data
        elif tag == "SBPW" and "elapsed_ms" in data:
            session["power"] = data
        elif tag == "APP" and "telemetry_check" in data:
            session["check"] = data["telemetry_check"]
        elif tag == "DESK" and "t" in data:
            session["desk"].append(data)
        elif tag == "APP" and "t" in data:
            session["frames"].append(data)
    if session["check"] is None and session["end"] is not None:
        sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "companion"))
        from sbstream import telemetry_check
        session["check"] = telemetry_check(session["telemetry"], session["end"])
    return session


def summarize(session):
    trace, frames = session["trace"], session["frames"]
    out = {"trace_points": len(trace), "frames": len(frames),
           "frames_with_face": sum(1 for f in frames if f.get("faces", 0) > 0),
           "targets_sent": sum(1 for f in frames if "sent" in f)}
    for axis in ("yaw", "pitch"):
        errors = [abs(p[axis + "_goal"] - p[axis]) for p in trace if p.get(axis, -1) >= 0]
        moves = [p[axis] for p in trace if p.get(axis, -1) >= 0]
        reversals, direction = 0, 0
        for a, b in zip(moves, moves[1:]):
            step = (b > a) - (b < a)
            if abs(b - a) >= 3 and step:
                if direction and step != direction:
                    reversals += 1
                direction = step
        out[axis] = {"median_error": sorted(errors)[len(errors) // 2] if errors else None,
                     "max_error": max(errors) if errors else None,
                     "range": [min(moves), max(moves)] if moves else None,
                     "reversals": reversals}
    modes = {}
    for a, b in zip(trace, trace[1:]):
        name = MODES.get(a.get("mode"), ("?", ""))[0]
        modes[name] = modes.get(name, 0) + b["elapsed_ms"] - a["elapsed_ms"]
    out["mode_ms"] = modes
    desk = session["desk"]
    classes = [face[7] for d in desk for face in d.get("faces", []) if len(face) > 7]
    out["desk"] = {"frames": len(desk),
                   "faces_by_facing": {c: classes.count(c) for c in sorted(set(classes))},
                   "frames_during_call": sum(1 for d in desk if d.get("in_use_by_another_app")),
                   "frames_center_stage": sum(1 for d in desk if d.get("center_stage_active"))}
    out["result"] = (session["result"] or {}).get("result")
    out["telemetry"] = session["check"] or "not in log"
    return out


def polyline(points, x0, x1, y0, y1, width, height, colour, dash=""):
    if len(points) < 2:
        return ""
    sx = width / max(x1 - x0, 1e-9)
    sy = height / max(y1 - y0, 1e-9)
    path = " ".join(f"{(x - x0) * sx:.1f},{height - (y - y0) * sy:.1f}" for x, y in points)
    style = f' stroke-dasharray="{dash}"' if dash else ""
    return f'<polyline fill="none" stroke="{colour}" stroke-width="1.6"{style} points="{path}"/>'


def chart(title, series, t_end, width=900, height=180, y_range=None, mode_bands=None, markers=None):
    """series: [(label, [(t_s, value)], colour, dash)]."""
    values = [v for _, pts, _, _ in series for _, v in pts]
    if y_range is None:
        if not values:
            return f"<h2>{html.escape(title)}</h2><p>No data.</p>"
        lo, hi = min(values), max(values)
        pad = max((hi - lo) * 0.1, 4)
        y_range = (lo - pad, hi + pad)
    y0, y1 = y_range
    parts = [f'<svg viewBox="0 0 {width} {height}" role="img" aria-label="{html.escape(title)}">']
    for start, stop, colour in mode_bands or []:
        x = start / t_end * width
        w = max((stop - start) / t_end * width, 0.5)
        parts.append(f'<rect x="{x:.1f}" y="0" width="{w:.1f}" height="{height}" fill="{colour}" opacity="0.10"/>')
    for label, pts, colour, dash in series:
        parts.append(polyline(pts, 0, t_end, y0, y1, width, height, colour, dash))
    for t, v, colour in markers or []:
        cx = t / t_end * width
        cy = height - (v - y0) / (y1 - y0) * height
        parts.append(f'<circle cx="{cx:.1f}" cy="{cy:.1f}" r="2.5" fill="{colour}"/>')
    parts.append(f'<text x="4" y="12" class="tick">{y1:.0f}</text><text x="4" y="{height - 4}" class="tick">{y0:.0f}</text>')
    parts.append("</svg>")
    legend = " ".join(f'<span class="key"><i style="background:{c}"></i>{html.escape(l)}</span>' for l, _, c, _ in series)
    return f"<h2>{html.escape(title)}</h2><div class='legend'>{legend}</div>{''.join(parts)}"


def render(session, name):
    trace, frames = session["trace"], session["frames"]
    summary = summarize(session)
    t0 = frames[0]["t"] if frames else 0
    t_end = max([p["elapsed_ms"] / 1000 for p in trace] + [f["t"] - t0 for f in frames] + [1])
    bands = []
    for a, b in zip(trace, trace[1:]):
        bands.append((a["elapsed_ms"] / 1000, b["elapsed_ms"] / 1000, MODES.get(a.get("mode"), ("", "#000"))[1]))
    series = lambda key: [(p["elapsed_ms"] / 1000, p[key]) for p in trace if p.get(key, -1) >= 0]
    yaw_series = [("commanded", series("yaw_goal"), "#1a73e8", "4 3"), ("measured", series("yaw"), "#174ea6", "")]
    # Where the eyes aimed, as a head direction: the head plus the eyes' offset
    # in the image (eye_x is image units x 1000; 96 raw per image unit, head_tracker.h).
    eye_aim = [(p["elapsed_ms"] / 1000, p["yaw"] + p["eye_x"] / 1000 * 96) for p in trace if "eye_x" in p and p.get("yaw", -1) >= 0]
    if eye_aim:
        yaw_series.append(("eyes aim (head + eyes)", eye_aim, "#e8710a", ""))
    yaw = chart("Yaw (raw)", yaw_series, t_end, mode_bands=bands)
    pitch = chart("Pitch (raw)", [("commanded", series("pitch_goal"), "#e37400", "4 3"), ("measured", series("pitch"), "#b06000", "")],
                  t_end, mode_bands=bands)
    face_x, face_y, sent = [], [], []
    for f in frames:
        if f.get("detections"):
            d = f["detections"][0]
            face_x.append((f["t"] - t0, d[0] * 2 - 1))
            face_y.append((f["t"] - t0, d[1] * 2 - 1))       # plotted up = higher in the frame
        if "sent" in f:
            sent.append((f["t"] - t0, f["x"], "#188038"))
            if "y" in f:
                sent.append((f["t"] - t0, -f["y"], "#a142f4"))
    face = chart("Face offset from the centre of the frame (first detection)",
                 [("x: + is right of centre", face_x, "#188038", ""), ("y: + is above centre", face_y, "#a142f4", "")],
                 t_end, y_range=(-1.05, 1.05), mode_bands=bands, markers=sent)
    legend = " ".join(f'<span class="key"><i style="background:{c};opacity:.35"></i>{n}</span>' for n, c in MODES.values())
    rows = []
    for label, value in [("Result", summary["result"]), ("Telemetry", summary["telemetry"]),
                         ("Trace points", summary["trace_points"]), ("Frames analysed", summary["frames"]),
                         ("Frames with a face", summary["frames_with_face"]), ("Targets sent", summary["targets_sent"]),
                         ("Yaw error median / max", f'{summary["yaw"]["median_error"]} / {summary["yaw"]["max_error"]}'),
                         ("Yaw range, reversals", f'{summary["yaw"]["range"]}, {summary["yaw"]["reversals"]}'),
                         ("Pitch error median / max", f'{summary["pitch"]["median_error"]} / {summary["pitch"]["max_error"]}'),
                         ("Pitch range, reversals", f'{summary["pitch"]["range"]}, {summary["pitch"]["reversals"]}'),
                         ("Time by mode (ms)", ", ".join(f"{k} {v}" for k, v in summary["mode_ms"].items())),
                         ("Desk camera", f'{summary["desk"]["frames"]} frames, faces {summary["desk"]["faces_by_facing"]}, '
                                         f'{summary["desk"]["frames_during_call"]} during a call, '
                                         f'{summary["desk"]["frames_center_stage"]} with Center Stage')]:
        rows.append(f"<tr><th>{html.escape(label)}</th><td>{html.escape(str(value))}</td></tr>")
    warn = ""
    if summary["telemetry"] == "corrupted":
        warn = "<p class='warn'>The telemetry block arrived damaged. Do not trust these numbers.</p>"
    return f"""<!doctype html><meta charset="utf-8"><title>{html.escape(name)}</title>
<style>
body{{font:14px -apple-system,system-ui,sans-serif;margin:24px;max-width:960px;color:#202124;background:#fff}}
h1{{font-size:20px}} h2{{font-size:15px;margin:22px 0 4px}}
svg{{width:100%;height:auto;border:1px solid #dadce0;border-radius:6px;background:#fff}}
.tick{{font-size:10px;fill:#5f6368}} table{{border-collapse:collapse}} th{{text-align:left;padding:3px 14px 3px 0;color:#5f6368;font-weight:500}}
.legend,.modes{{font-size:12px;color:#5f6368}} .key{{margin-right:14px}} .key i{{display:inline-block;width:12px;height:3px;margin-right:4px;vertical-align:middle}}
.warn{{color:#c5221f;font-weight:600}}
</style>
<h1>{html.escape(name)}</h1>{warn}
<table>{''.join(rows)}</table>
<p class="modes">Shading: {legend}. Dots: targets sent. Time in seconds; alignment between robot and app is approximate.</p>
{yaw}{pitch}{face}
"""


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("log")
    parser.add_argument("--out", help="HTML path (default: next to the log)")
    parser.add_argument("--json", action="store_true", help="print the summary as JSON instead")
    args = parser.parse_args(argv)
    with open(args.log, encoding="utf-8", errors="replace") as f:
        session = parse(f)
    if args.json:
        print(json.dumps(summarize(session), indent=2))
        return 0
    out = args.out or os.path.splitext(args.log)[0] + ".html"
    with open(out, "w", encoding="utf-8") as f:
        f.write(render(session, os.path.basename(args.log)))
    print(out)
    return 0


if __name__ == "__main__":
    sys.exit(main())

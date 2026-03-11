#!/usr/bin/env python3
"""
Convert Chrome trace JSON (profile.json) into folded stacks and an HTML canvas flame graph.

Usage:
  python tools/trace-to-flamegraph.py --input profile.json --out artifacts/flame

Outputs:
  - <out>.folded   (always)
  - <out>.html     (always)
  - <out>.svg      (optional, if flamegraph.pl is available or passed via --flamegraph-pl)
"""

from __future__ import annotations

import argparse
import json
import math
import shutil
import subprocess
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, List, Tuple


@dataclass
class Event:
    name: str
    tid: int
    start_us: float
    end_us: float


@dataclass
class Active:
    name: str
    end_us: float
    self_us: float
    stack: List[str]


def load_trace(path: Path) -> List[Event]:
    with path.open("r", encoding="utf-8") as f:
        data = json.load(f)
    if not isinstance(data, list):
        raise ValueError("Expected top-level JSON array in trace file")

    events: List[Event] = []
    for item in data:
        if not isinstance(item, dict):
            continue
        if item.get("ph") != "X":
            continue
        name = item.get("name")
        ts = item.get("ts")
        dur = item.get("dur")
        tid = item.get("tid")
        if not isinstance(name, str):
            continue
        if not isinstance(ts, (int, float)) or not isinstance(dur, (int, float)):
            continue
        if not isinstance(tid, (int, float)):
            continue
        start_us = float(ts)
        end_us = start_us + float(dur)
        events.append(Event(name=name, tid=int(tid), start_us=start_us, end_us=end_us))
    return events


def collapse_self_time(events: List[Event], min_self_us: float) -> Dict[str, int]:
    by_tid: Dict[int, List[Event]] = {}
    for e in events:
        by_tid.setdefault(e.tid, []).append(e)

    folded: Dict[str, int] = {}

    for tid, evts in by_tid.items():
        # Stable order: earlier start first; for same start, longer span first.
        evts.sort(key=lambda e: (e.start_us, -(e.end_us - e.start_us), e.name))
        stack: List[Active] = []

        def flush_finished(until_start_us: float) -> None:
            while stack and until_start_us >= stack[-1].end_us:
                node = stack.pop()
                if node.self_us < min_self_us:
                    continue
                key = ";".join(node.stack)
                folded[key] = folded.get(key, 0) + int(round(node.self_us))

        for e in evts:
            flush_finished(e.start_us)

            if stack:
                parent = stack[-1]
                overlap = max(0.0, min(parent.end_us, e.end_us) - e.start_us)
                if overlap > 0.0:
                    parent.self_us -= overlap

            names = [f"tid:{tid}"] + [n.name for n in stack] + [e.name]
            stack.append(
                Active(
                    name=e.name,
                    end_us=e.end_us,
                    self_us=(e.end_us - e.start_us),
                    stack=names,
                )
            )

        flush_finished(float("inf"))

    return folded


def write_folded(path: Path, folded: Dict[str, int]) -> None:
    lines = [f"{stack} {count}" for stack, count in sorted(folded.items()) if count > 0]
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(lines) + ("\n" if lines else ""), encoding="utf-8")


def build_metadata(events: List[Event], folded: Dict[str, int]) -> dict:
    if events:
        min_start = min(e.start_us for e in events)
        max_end = max(e.end_us for e in events)
        span_us = max(0.0, max_end - min_start)
        tids = sorted({e.tid for e in events})
    else:
        span_us = 0.0
        tids = []
    top = sorted(folded.items(), key=lambda kv: kv[1], reverse=True)[:12]
    return {
        "event_count": len(events),
        "thread_count": len(tids),
        "threads": tids,
        "capture_span_us": int(round(span_us)),
        "folded_rows": len(folded),
        "total_self_us": int(sum(max(0, v) for v in folded.values())),
        "top_stacks": [{"stack": k, "self_us": int(v)} for k, v in top],
    }


PASS_HINTS: List[Tuple[str, str]] = [
    ("skybox", "skybox"),
    ("shadow", "shadow"),
    ("hybrid_shadow", "hybrid_shadow"),
    ("ssao", "ssao"),
    ("ssgi", "ssgi"),
    ("ssr", "ssr"),
    ("depth_fog", "depth_fog"),
    ("taa", "taa"),
    ("motion_blur", "motion_blur"),
    ("god_rays", "god_rays"),
    ("bloom", "bloom"),
    ("lens_flare", "lens_flare"),
    ("dof", "dof"),
    ("chromatic", "chromatic_aberration"),
    ("film_grain", "film_grain_vignette"),
    ("vignette", "film_grain_vignette"),
    ("grade", "color_grade"),
    ("renderer.render", "frame"),
]


def infer_labels(name: str) -> Tuple[str, str]:
    lower = name.lower()
    pass_label = "unknown"
    for hint, label in PASS_HINTS:
        if hint in lower:
            pass_label = label
            break

    entity = "generic"
    if "meshlet" in lower:
        entity = "meshlet"
    elif "tile" in lower:
        entity = "tile"
    elif "shadow" in lower:
        entity = "shadow"
    elif "triangle" in lower or "vertex" in lower:
        entity = "vertex_or_triangle"
    elif "pass" in lower:
        entity = "pass"
    return pass_label, entity


def prepare_event_rows(events: List[Event]) -> List[dict]:
    if not events:
        return []
    min_start = min(e.start_us for e in events)
    rows: List[dict] = []
    next_id = 1
    by_tid: Dict[int, List[Event]] = {}
    for e in events:
        by_tid.setdefault(e.tid, []).append(e)
    for tid in sorted(by_tid.keys()):
        evts = sorted(by_tid[tid], key=lambda e: (e.start_us, -(e.end_us - e.start_us), e.name))
        lane_ends: List[float] = []
        for e in evts:
            lane = 0
            while lane < len(lane_ends) and lane_ends[lane] > e.start_us:
                lane += 1
            if lane == len(lane_ends):
                lane_ends.append(e.end_us)
            else:
                lane_ends[lane] = e.end_us
            pass_label, entity = infer_labels(e.name)
            rows.append({
                "id": next_id,
                "tid": tid,
                "lane": lane,
                "name": e.name,
                "func": e.name,
                "pass": pass_label,
                "entity": entity,
                "start_us": int(round(e.start_us - min_start)),
                "dur_us": int(round(max(1.0, e.end_us - e.start_us))),
            })
            next_id += 1
    return rows


def write_html_canvas(path: Path, folded: Dict[str, int], title: str, metadata: dict, events: List[Event]) -> None:
    tree = {"name": "root", "value": 0, "children": {}}
    for stack, value in folded.items():
        if value <= 0:
            continue
        parts = stack.split(";")
        node = tree
        node["value"] += value
        for part in parts:
            children = node["children"]
            if part not in children:
                children[part] = {"name": part, "value": 0, "children": {}}
            node = children[part]
            node["value"] += value

    def encode_node(n):
        kids = [encode_node(k) for _, k in sorted(n["children"].items(), key=lambda kv: kv[1]["value"], reverse=True)]
        return {"name": n["name"], "value": n["value"], "children": kids}

    payload = json.dumps(encode_node(tree), separators=(",", ":"))
    meta_json = json.dumps(metadata, separators=(",", ":"))
    rows_json = json.dumps(prepare_event_rows(events), separators=(",", ":"))
    html = f"""<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width,initial-scale=1" />
  <title>{title}</title>
  <style>
    :root {{ --bg:#0f1115; --panel:#171a21; --panel2:#1f2430; --text:#e8edf7; --muted:#9aa3b2; --accent:#6cb2ff; --border:#2a3140; }}
    * {{ box-sizing: border-box; }}
    body {{ margin:0; font:12px/1.45 ui-sans-serif, system-ui, Segoe UI, Roboto, Arial; background:var(--bg); color:var(--text); }}
    .shell {{ display:grid; grid-template-columns: 340px 1fr; min-height:100vh; }}
    .side {{ background:var(--panel); border-right:1px solid var(--border); padding:10px; overflow:auto; }}
    .main {{ display:flex; flex-direction:column; min-width:0; }}
    .bar {{ padding:8px 10px; border-bottom:1px solid var(--border); background:var(--panel); display:flex; gap:8px; align-items:center; flex-wrap:wrap; }}
    .title {{ font-weight:700; color:var(--accent); }}
    .crumbs {{ color:var(--muted); white-space:nowrap; overflow:hidden; text-overflow:ellipsis; max-width:540px; }}
    input, button {{ background:var(--panel2); color:var(--text); border:1px solid var(--border); border-radius:6px; padding:6px 8px; }}
    input {{ min-width:220px; }}
    button {{ cursor:pointer; }}
    #tabs button {{ padding:4px 8px; }}
    #timeline {{ display:block; width:100%; height: calc(100vh - 54px); background:#12151c; }}
    #flame {{ display:none; width:100%; height: calc(100vh - 54px); background:#12151c; }}
    .k {{ color:var(--muted); }}
    .v {{ color:var(--text); font-weight:600; }}
    .meta-grid {{ display:grid; grid-template-columns: 1fr 1fr; gap:6px 10px; margin-bottom:10px; }}
    .toplist {{ border-top:1px solid var(--border); padding-top:8px; }}
    .topitem {{ padding:4px 0; border-bottom:1px dashed #2a3140; }}
    .topitem .stack {{ color:#cfd7e6; font-family: ui-monospace, SFMono-Regular, Consolas, monospace; word-break:break-all; }}
    .topitem .us {{ color:#8dd17e; }}
    .detail {{ border-top:1px solid var(--border); margin-top:8px; padding-top:8px; }}
    .detail code {{ color:#ffd68a; }}
  </style>
</head>
<body>
  <div class="shell">
    <aside class="side">
      <div class="title">Trace Metadata</div>
      <div id="meta" class="meta-grid"></div>
      <div class="toplist">
        <div class="title">Top Hot Stacks</div>
        <div id="top"></div>
      </div>
      <div class="detail">
        <div class="title">Selected Event</div>
        <div id="sel">Click a timeline cell</div>
      </div>
    </aside>
    <main class="main">
      <div class="bar">
        <strong class="title">{title}</strong>
        <span id="tabs">
          <button id="tabTimeline">Timeline</button>
          <button id="tabFlame">Flame</button>
        </span>
        <input id="search" placeholder="Search frame/function name..." />
        <button id="reset">Reset Zoom</button>
        <span id="crumbs" class="crumbs"></span>
        <span id="info"></span>
      </div>
      <canvas id="timeline"></canvas>
      <canvas id="flame"></canvas>
    </main>
  </div>
  <script>
    const root = {payload};
    const meta = {meta_json};
    const rows = {rows_json};
    const timeline = document.getElementById('timeline');
    const tctx = timeline.getContext('2d');
    const flame = document.getElementById('flame');
    const fctx = flame.getContext('2d');
    const info = document.getElementById('info');
    const crumbs = document.getElementById('crumbs');
    const search = document.getElementById('search');
    const metaEl = document.getElementById('meta');
    const topEl = document.getElementById('top');
    const sel = document.getElementById('sel');
    const tabTimeline = document.getElementById('tabTimeline');
    const tabFlame = document.getElementById('tabFlame');
    const resetBtn = document.getElementById('reset');
    const rowH = 18;
    let view = root;
    let flameRects = [];
    let timeRects = [];
    let hovered = null;
    let hoveredTime = null;
    let searchTerm = '';
    let mode = 'timeline';

    function hashColor(s) {{
      let h=0; for (let i=0;i<s.length;i++) h=((h<<5)-h+s.charCodeAt(i))|0;
      const hue = Math.abs(h)%360;
      return `hsl(${{hue}} 70% 58%)`;
    }}

    function depth(n) {{
      if (!n.children || n.children.length === 0) return 1;
      let m = 0; for (const c of n.children) m = Math.max(m, depth(c));
      return m + 1;
    }}

    function resize() {{
      const dpr = window.devicePixelRatio || 1;
      timeline.width = Math.floor(timeline.clientWidth * dpr);
      timeline.height = Math.floor(timeline.clientHeight * dpr);
      tctx.setTransform(dpr,0,0,dpr,0,0);
      flame.width = Math.floor(flame.clientWidth * dpr);
      flame.height = Math.floor(flame.clientHeight * dpr);
      fctx.setTransform(dpr,0,0,dpr,0,0);
      drawTimeline();
      drawFlame();
    }}

    function drawMeta() {{
      const rows = [
        ['Events', meta.event_count],
        ['Threads', meta.thread_count],
        ['Span (us)', meta.capture_span_us],
        ['Folded Rows', meta.folded_rows],
        ['Total Self (us)', meta.total_self_us],
      ];
      metaEl.innerHTML = rows.map(([k,v]) => `<div class="k">${{k}}</div><div class="v">${{v}}</div>`).join('');
      topEl.innerHTML = (meta.top_stacks || []).map((t) =>
        `<div class="topitem"><div class="us">${{t.self_us}} us</div><div class="stack">${{t.stack}}</div></div>`
      ).join('');
    }}

    function nodePath(n) {{
      const p = [];
      let cur = n;
      while (cur) {{
        p.push(cur.name);
        cur = cur._parent || null;
      }}
      return p.reverse().join(' > ');
    }}

    function attachParents(n, parent=null) {{
      n._parent = parent;
      if (!n.children) return;
      for (const c of n.children) attachParents(c, n);
    }}

    function drawFlame() {{
      const w = flame.clientWidth, h = flame.clientHeight;
      fctx.clearRect(0,0,w,h);
      flameRects = [];
      const maxD = depth(view);
      const total = Math.max(1, view.value);
      function rec(n, x, y, width, d) {{
        if (d > maxD || width < 1) return;
        if (n !== view) {{
          const r = {{x, y, w: width, h: rowH-1, n}};
          flameRects.push(r);
          const matched = searchTerm && n.name.toLowerCase().includes(searchTerm);
          fctx.fillStyle = matched ? '#ffd166' : hashColor(n.name);
          fctx.fillRect(r.x, r.y, r.w, r.h);
          if (hovered === n) {{
            fctx.strokeStyle = '#ffffff';
            fctx.lineWidth = 1;
            fctx.strokeRect(r.x + 0.5, r.y + 0.5, r.w - 1, r.h - 1);
          }}
          if (r.w > 60) {{
            fctx.fillStyle = '#111';
            fctx.fillText(`${{n.name}} (${{n.value}}us)`, r.x + 4, r.y + 12);
          }}
        }}
        if (!n.children || n.children.length === 0) return;
        let off = x;
        for (const c of n.children) {{
          const cw = width * (c.value / total) / (n===view ? 1 : (n.value / total));
          rec(c, off, y + rowH, cw, d + 1);
          off += cw;
        }}
      }}
      rec(view, 0, 0, w, 0);
      crumbs.textContent = nodePath(view);
    }}

    function drawTimeline() {{
      const w = timeline.clientWidth, h = timeline.clientHeight;
      tctx.clearRect(0,0,w,h);
      timeRects = [];
      const maxEnd = Math.max(1, ...rows.map(r => r.start_us + r.dur_us));
      const threads = [...new Set(rows.map(r => r.tid))];
      const laneOffsetByTid = new Map();
      let offset = 0;
      for (const tid of threads) {{
        const maxLane = rows.filter(r => r.tid===tid).reduce((m,r)=>Math.max(m,r.lane),0);
        laneOffsetByTid.set(tid, offset);
        offset += maxLane + 2;
      }}
      const totalLanes = Math.max(1, offset);
      const laneH = Math.max(12, Math.floor((h - 20) / totalLanes));
      for (const e of rows) {{
        if (searchTerm && !e.name.toLowerCase().includes(searchTerm) && !e.pass.includes(searchTerm)) continue;
        const x = (e.start_us / maxEnd) * w;
        const rw = Math.max(1, (e.dur_us / maxEnd) * w);
        const y = (laneOffsetByTid.get(e.tid) + e.lane) * laneH;
        const r = {{x, y, w: rw, h: laneH - 2, e}};
        timeRects.push(r);
        const matched = hoveredTime && hoveredTime.id === e.id;
        tctx.fillStyle = matched ? '#ffffff' : hashColor(`${{e.pass}}:${{e.func}}`);
        tctx.fillRect(r.x, r.y, r.w, r.h);
      }}
      tctx.fillStyle = '#7f8aa0';
      tctx.fillText(`Capture span: ${{maxEnd}} us`, 8, h - 6);
    }}

    function renderSelected(e) {{
      sel.innerHTML = `
        <div><span class="k">Name:</span> <code>${{e.name}}</code></div>
        <div><span class="k">Pass:</span> <button onclick="filterBy('${{e.pass}}')">${{e.pass}}</button></div>
        <div><span class="k">Function:</span> <button onclick="filterBy('${{e.func}}')">${{e.func}}</button></div>
        <div><span class="k">Entity:</span> <button onclick="filterBy('${{e.entity}}')">${{e.entity}}</button></div>
        <div><span class="k">Thread:</span> ${{e.tid}} <span class="k">Lane:</span> ${{e.lane}}</div>
        <div><span class="k">Start:</span> ${{e.start_us}} us <span class="k">Dur:</span> ${{e.dur_us}} us</div>
      `;
    }}
    window.filterBy = (txt) => {{ search.value = txt; searchTerm = txt.toLowerCase(); drawTimeline(); drawFlame(); }};

    flame.addEventListener('mousemove', (e) => {{
      const x=e.offsetX, y=e.offsetY;
      hovered = null;
      for (let i=flameRects.length-1;i>=0;i--) {{
        const r=flameRects[i];
        if (x>=r.x && x<=r.x+r.w && y>=r.y && y<=r.y+r.h) {{
          hovered = r.n;
          info.textContent = `${{r.n.name}}  self=${{r.n.value}}us  share=${{((r.n.value/Math.max(1,view.value))*100).toFixed(1)}}%`;
          drawFlame();
          return;
        }}
      }}
      info.textContent = '';
      drawFlame();
    }});
    flame.addEventListener('click', (e) => {{
      const x=e.offsetX, y=e.offsetY;
      for (let i=flameRects.length-1;i>=0;i--) {{
        const r=flameRects[i];
        if (x>=r.x && x<=r.x+r.w && y>=r.y && y<=r.y+r.h) {{
          view = r.n;
          drawFlame();
          return;
        }}
      }}
    }});
    timeline.addEventListener('mousemove', (e) => {{
      const x=e.offsetX, y=e.offsetY;
      hoveredTime = null;
      for (let i=timeRects.length-1;i>=0;i--) {{
        const r=timeRects[i];
        if (x>=r.x && x<=r.x+r.w && y>=r.y && y<=r.y+r.h) {{
          hoveredTime = r.e;
          info.textContent = `${{r.e.pass}} :: ${{r.e.func}}  dur=${{r.e.dur_us}}us`;
          drawTimeline();
          return;
        }}
      }}
      info.textContent = '';
      drawTimeline();
    }});
    timeline.addEventListener('click', (e) => {{
      const x=e.offsetX, y=e.offsetY;
      for (let i=timeRects.length-1;i>=0;i--) {{
        const r=timeRects[i];
        if (x>=r.x && x<=r.x+r.w && y>=r.y && y<=r.y+r.h) {{
          renderSelected(r.e);
          return;
        }}
      }}
    }});
    search.addEventListener('input', () => {{
      searchTerm = search.value.trim().toLowerCase();
      drawTimeline();
      drawFlame();
    }});
    tabTimeline.addEventListener('click', () => {{ mode='timeline'; timeline.style.display='block'; flame.style.display='none'; }});
    tabFlame.addEventListener('click', () => {{ mode='flame'; timeline.style.display='none'; flame.style.display='block'; }});
    resetBtn.addEventListener('click', () => {{ view = root; drawFlame(); }});
    window.addEventListener('resize', resize);
    attachParents(root, null);
    drawMeta();
    resize();
  </script>
</body>
</html>"""
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(html, encoding="utf-8")


def resolve_flamegraph_pl(explicit: str | None) -> str | None:
    if explicit:
        return explicit
    in_path = shutil.which("flamegraph.pl")
    if in_path:
        return in_path
    local = Path("tools") / "FlameGraph" / "flamegraph.pl"
    if local.exists():
        return str(local)
    return None


def render_svg(flamegraph_pl: str, folded_path: Path, svg_path: Path, title: str) -> None:
    cmd = [flamegraph_pl, "--title", title, str(folded_path)]
    proc = subprocess.run(cmd, check=False, capture_output=True, text=False)
    if proc.returncode != 0:
        stderr = proc.stderr.decode("utf-8", errors="replace")
        raise RuntimeError(f"flamegraph.pl failed with code {proc.returncode}: {stderr}")
    svg_path.write_bytes(proc.stdout)


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description="Convert Chrome trace JSON into folded stacks and flame graph SVG")
    p.add_argument("--input", required=True, help="Input trace JSON path (e.g. profile.json)")
    p.add_argument("--out", required=True, help="Output prefix path (without extension)")
    p.add_argument("--title", default="CPU Flame Graph", help="Flame graph title")
    p.add_argument("--min-self-us", type=float, default=1.0, help="Drop folded rows below this self-time threshold")
    p.add_argument("--flamegraph-pl", default=None, help="Path to flamegraph.pl (optional)")
    p.add_argument("--no-svg", action="store_true", help="Skip optional SVG generation")
    return p.parse_args()


def main() -> int:
    args = parse_args()
    in_path = Path(args.input)
    out_prefix = Path(args.out)
    folded_path = out_prefix.with_suffix(".folded")
    html_path = out_prefix.with_suffix(".html")
    svg_path = out_prefix.with_suffix(".svg")

    events = load_trace(in_path)
    folded = collapse_self_time(events, min_self_us=max(0.0, args.min_self_us))
    metadata = build_metadata(events, folded)
    write_folded(folded_path, folded)
    print(f"[trace-to-flamegraph] wrote folded stacks: {folded_path}")
    write_html_canvas(html_path, folded, args.title, metadata, events)
    print(f"[trace-to-flamegraph] wrote html canvas flamegraph: {html_path}")

    if args.no_svg:
        return 0

    flamegraph_pl = resolve_flamegraph_pl(args.flamegraph_pl)
    if not flamegraph_pl:
        print("[trace-to-flamegraph] flamegraph.pl not found, skipping SVG (folded output is ready)")
        return 0

    render_svg(flamegraph_pl, folded_path, svg_path, args.title)
    print(f"[trace-to-flamegraph] wrote svg: {svg_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

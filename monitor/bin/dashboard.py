#!/usr/bin/env python3
"""Read-only local web view over the files ``collect.py`` writes.

Deliberately small: one page, one JSON endpoint, no database, no build step and
no dependency. It binds to 127.0.0.1 because the numbers it shows are the
machine's own, and exposing them is a decision that belongs to whoever runs the
machine, not to this script's default.

    MONITOR_PORT=8899 python3 bin/dashboard.py
"""

import gzip
import json
import os
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

HOURS_SHOWN = 24


def resolve_dirs():
    home = Path(os.environ.get("MONITOR_HOME", str(Path.home() / "gpu-monitor")))
    data = Path(os.environ.get("MONITOR_DATA_DIR", str(home / "data")))
    return data, data / "samples", data / "archives"


DATA, SAMPLES, ARCHIVES = resolve_dirs()


def parse_time(value):
    return datetime.fromisoformat(value.replace("Z", "+00:00"))


def read_json(path):
    try:
        return json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None


def read_samples(path):
    """Read one sample file, plain or gzipped."""
    opener = gzip.open if path.suffix == ".gz" else open
    try:
        with opener(path, "rt", encoding="utf-8") as fh:
            lines = fh.read().splitlines()
    except OSError:
        return []
    rows = []
    for line in lines:
        if not line.strip():
            continue
        try:
            rows.append(json.loads(line))
        except ValueError:
            continue
    return rows


def sample_files_for_window(start, end):
    day = start.date()
    while day <= end.date():
        base = SAMPLES / day.isoformat()
        if (base.with_suffix(".jsonl")).exists():
            yield base.with_suffix(".jsonl")
        if (base.with_suffix(".jsonl.gz")).exists():
            yield base.with_suffix(".jsonl.gz")
        day += timedelta(days=1)


def load_recent(hours=HOURS_SHOWN):
    end = datetime.now(timezone.utc)
    start = end - timedelta(hours=hours)
    rows = []
    for path in sample_files_for_window(start, end):
        for row in read_samples(path):
            payload = row.get("payload") or {}
            collected_at = payload.get("collected_at")
            if not collected_at:
                continue
            try:
                ts = parse_time(collected_at)
            except ValueError:
                continue
            if start <= ts <= end:
                rows.append(row)
    rows.sort(key=lambda row: row["payload"]["collected_at"])
    return rows


def compact_sample(row):
    """The slice of a sample the page draws: no process text, no filesystem names."""
    payload = row["payload"]
    summary = row.get("summary") or {}
    gpus = []
    for gpu in payload.get("gpus", []):
        total = max(gpu.get("memory_total_mib", 1), 1)
        gpus.append({
            "index": gpu.get("index"),
            "util": gpu.get("utilization_gpu_pct"),
            "mem_pct": round(gpu.get("memory_used_mib", 0) / total * 100, 2),
            "power": gpu.get("power_draw_w"),
            "temp": gpu.get("temperature_c"),
        })
    return {
        "t": payload["collected_at"],
        "status": summary.get("status", "offline"),
        "avg_util": summary.get("avg_util"),
        "avg_mem_pct": summary.get("avg_mem_pct"),
        "total_power_w": summary.get("total_power_w"),
        "max_temp_c": summary.get("max_temp_c"),
        "cpu_util": summary.get("cpu_util_pct"),
        "mem_used_pct": summary.get("mem_used_pct"),
        "disk_risk": summary.get("disk_risk", "ok"),
        "gpus": gpus,
        "disks": [
            {"mount": disk.get("mount"), "use_pct": disk.get("use_pct")}
            for disk in payload.get("disks", [])
        ],
    }


def read_archives(limit=14):
    items = []
    for path in sorted(ARCHIVES.glob("*.summary.json"), reverse=True)[:limit]:
        item = read_json(path)
        if item:
            items.append(item)
    return items


def build_snapshot():
    latest = read_json(DATA / "latest.json")
    rows = load_recent()
    return {
        "ok": True,
        "generated_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "hours": HOURS_SHOWN,
        "latest": latest,
        "series": [compact_sample(row) for row in rows],
        "archives": read_archives(),
    }


def response(handler, status, body, content_type):
    raw = body.encode("utf-8")
    handler.send_response(status)
    handler.send_header("content-type", content_type)
    handler.send_header("content-length", str(len(raw)))
    handler.send_header("cache-control", "no-store")
    handler.end_headers()
    handler.wfile.write(raw)


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        return

    def do_GET(self):
        if self.path == "/" or self.path.startswith("/?"):
            response(self, 200, PAGE, "text/html; charset=utf-8")
            return
        if self.path == "/api/snapshot":
            body = json.dumps(build_snapshot(), ensure_ascii=False)
            response(self, 200, body, "application/json; charset=utf-8")
            return
        response(self, 404, "Not found", "text/plain; charset=utf-8")


PAGE = r"""<!doctype html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Local GPU Monitor</title>
  <style>
    :root{color-scheme:dark;--bg:#0c1117;--panel:#121a24;--panel2:#172231;--line:#273547;--text:#e6edf3;--muted:#8fa1b4;--good:#5eead4;--warn:#fbbf24;--bad:#fb7185;--blue:#60a5fa;--violet:#a78bfa}
    *{box-sizing:border-box}body{margin:0;background:radial-gradient(circle at 18% 0%,rgba(96,165,250,.12),transparent 34rem),#0c1117;color:var(--text);font-family:Inter,ui-sans-serif,system-ui,-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif}
    main{width:min(1420px,calc(100vw - 28px));margin:0 auto;padding:24px 0 38px}header{display:flex;justify-content:space-between;gap:16px;align-items:flex-end;border-bottom:1px solid var(--line);padding-bottom:16px}
    h1{margin:0;font-size:clamp(28px,4vw,42px);letter-spacing:0}.muted{color:var(--muted)}.grid{display:grid;grid-template-columns:repeat(4,1fr);gap:1px;background:var(--line);border:1px solid var(--line);border-radius:8px;overflow:hidden;margin-top:18px}.metric{background:var(--panel);padding:14px;min-height:88px}.metric span{display:block;color:var(--muted);font-size:13px}.metric strong{display:block;margin-top:8px;font-size:25px}
    .status{display:inline-flex;border:1px solid var(--line);border-radius:999px;padding:6px 10px;font-size:14px}.full{color:var(--good)}.warm{color:var(--blue)}.partial{color:var(--warn)}.idle,.offline{color:var(--bad)}
    .charts{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:16px;margin-top:16px}.card{border:1px solid var(--line);border-radius:8px;background:var(--panel);padding:16px}.card h2{font-size:18px;margin:0 0 10px}.chart{width:100%;height:240px;display:block}.wide{grid-column:1/-1}.split{display:grid;grid-template-columns:1.1fr .9fr;gap:16px;margin-top:16px}
    table{width:100%;border-collapse:collapse;font-size:14px}th,td{text-align:left;border-bottom:1px solid var(--line);padding:9px 8px;vertical-align:top}th{color:var(--muted)}code{color:#c4b5fd}.empty{border:1px dashed var(--line);border-radius:8px;padding:24px;color:var(--muted);margin-top:18px}.legend{display:flex;gap:10px;flex-wrap:wrap;color:var(--muted);font-size:13px}.swatch{display:inline-block;width:10px;height:10px;border-radius:2px;margin-right:5px}
    @media(max-width:980px){.charts,.split{grid-template-columns:1fr}.grid{grid-template-columns:repeat(2,1fr)}header{align-items:flex-start;flex-direction:column}.wide{grid-column:auto}}@media(max-width:560px){.grid{grid-template-columns:1fr}.chart{height:210px}}
  </style>
</head>
<body><main><header><div><h1>本地 GPU 看板</h1><div class="muted">最近 24h 分钟级曲线；服务仅监听 127.0.0.1。</div></div><div id="stamp" class="muted">加载中...</div></header><section id="summary"></section><section class="charts" id="charts"></section><section class="split"><div class="card"><h2>当前进程</h2><div id="processes"></div></div><div class="card"><h2>每日归档</h2><div id="archives"></div></div></section></main>
<script>
const label={full:"满载",warm:"接近满载",partial:"低利用",idle:"空闲",offline:"未上报"};
const colors=["#5eead4","#60a5fa","#a78bfa","#fbbf24","#fb7185","#34d399","#f472b6","#c084fc"];
const num=v=>v===null||v===undefined||v===""||!isFinite(Number(v))?null:Number(v);
const pct=v=>{const n=num(v);return n===null?"—":Math.round(n)+"%"};
const esc=s=>String(s??"").replace(/[&<>"']/g,c=>({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"}[c]));
function age(iso){if(!iso)return"未上报";const m=Math.round((Date.now()-Date.parse(iso))/60000);return m<2?"刚刚":m<90?m+" 分钟前":(m/60).toFixed(1)+" 小时前"}
function metric(k,v){return `<div class="metric"><span>${k}</span><strong>${v}</strong></div>`}
function seriesByGpu(series,key){const out={};for(const row of series){for(const gpu of row.gpus||[]){(out[gpu.index]??=[]).push({t:row.t,y:num(gpu[key])})}}return out}
function scalarSeries(series,key){return {avg:series.map(row=>({t:row.t,y:num(row[key])}))}}
function drawChart(canvas,groups,maxY,hours){const ctx=canvas.getContext("2d"),dpr=window.devicePixelRatio||1,w=canvas.clientWidth,h=canvas.clientHeight;canvas.width=w*dpr;canvas.height=h*dpr;ctx.scale(dpr,dpr);ctx.clearRect(0,0,w,h);const t1=Date.now(),t0=t1-hours*3600e3;const X=t=>38+(w-48)*Math.max(0,Math.min(1,(t-t0)/(t1-t0)));const Y=v=>16+(h-34)*(1-Math.max(0,Math.min(maxY,v))/maxY);ctx.strokeStyle="#273547";ctx.lineWidth=1;ctx.font="12px system-ui";ctx.fillStyle="#8fa1b4";for(let i=0;i<=4;i++){const y=16+(h-34)*i/4;ctx.beginPath();ctx.moveTo(38,y);ctx.lineTo(w-8,y);ctx.stroke();ctx.fillText(Math.round(maxY*(1-i/4)),4,y+4)}let ci=0;for(const [name,pts] of Object.entries(groups)){ctx.strokeStyle=colors[ci++%colors.length];ctx.lineWidth=1.8;ctx.beginPath();let drawing=false;for(const p of pts){if(p.y===null){drawing=false;continue}const x=X(Date.parse(p.t)),y=Y(p.y);if(!drawing){ctx.moveTo(x,y);drawing=true}else ctx.lineTo(x,y)}ctx.stroke()}ctx.fillStyle="#8fa1b4";ctx.fillText("过去 "+hours+"h",w-78,h-5)}
function chartCardH(title,groups,maxY,hours){const id="c"+Math.random().toString(36).slice(2);setTimeout(()=>drawChart(document.getElementById(id),groups||100,24,hours),0);const legend=Object.keys(groups).map((k,i)=>`<span><i class="swatch" style="background:${colors[i%colors.length]}"></i>${esc(k)}</span>`).join("");return `<div class="card"><h2>${title}</h2><canvas class="chart" id="${id}"></canvas><div class="legend">${legend}</div></div>`}
function render(data){const latest=data.latest,series=data.series||[];if(!latest){document.querySelector("#summary").innerHTML='<div class="empty">还没有采样数据。</div>';return}const p=latest.payload,s=latest.summary||{},procs=p.processes||[],m=p.memory||{},c=p.cpu||{};const maxPower=Math.max(100,...series.flatMap(r=>(r.gpus||[]).map(g=>num(g.power)||0)),...(series.map(r=>num(r.total_power_w)||0)));document.querySelector("#summary").innerHTML=`<div class="grid">${metric("机器",esc(p.machine))}${metric("状态",`<span class="status ${esc(s.status||"offline")}">${label[s.status]||esc(s.status||"offline")}</span>`)}${metric("GPU 平均利用率",pct(s.avg_util))}${metric("显存占用",pct(s.avg_mem_pct))}${metric("CPU 使用率",pct(s.cpu_util_pct))}${metric("内存使用",pct(s.mem_used_pct))}${metric("整机功率",num(s.total_power_w)===null?"—":Math.round(s.total_power_w)+" W")}${metric("最高温度",num(s.max_temp_c)===null?"—":Math.round(s.max_temp_c)+" C")}${metric("磁盘风险",esc(s.disk_risk))}${metric("最后采样",age(p.collected_at))}</div>`;document.querySelector("#charts").innerHTML=chartCardH("GPU 利用率（单卡）",seriesByGpu(series,"util"),100)+chartCardH("显存占用（单卡）",seriesByGpu(series,"mem_pct"),100)+chartCardH("CPU 使用率",scalarSeries(series,"cpu_util"),100)+chartCardH("系统内存使用",scalarSeries(series,"mem_used_pct"),100)+chartCardH("功率（单卡）",seriesByGpu(series,"power"),maxPower)+chartCardH("温度（单卡）",seriesByGpu(series,"temp"),100);document.querySelector("#processes").innerHTML=`<table><thead><tr><th>GPU</th><th>用户</th><th>进程</th><th>运行</th><th>显存</th><th>命令摘要</th></tr></thead><tbody>${procs.map(x=>`<tr><td>${esc(x.gpu)}</td><td>${esc(x.user)}</td><td>${esc(x.process_name)}</td><td>${esc(x.elapsed)}</td><td>${esc(x.used_memory_mib)} MiB</td><td><code>${esc(x.command||"")}</code></td></tr>`).join("")||'<tr><td colspan="6">无 GPU 进程</td></tr>'}</tbody></table>`;document.querySelector("#archives").innerHTML=`<table><thead><tr><th>日期</th><th>GPU 利用率</th><th>CPU</th><th>满载分钟</th><th>电量估计</th></tr></thead><tbody>${(data.archives||[]).map(a=>`<tr><td>${esc(a.day)}</td><td>${pct(a.avg_gpu_util)}</td><td>${pct(a.avg_cpu_util)}</td><td>${esc(a.full_minutes)}</td><td>${num(a.estimated_energy_kwh)===null?"—":Number(a.estimated_energy_kwh).toFixed(1)+" kWh"}</td></tr>`).join("")||'<tr><td colspan="5">暂无归档</td></tr>'}</tbody></table>`}
async function load(){const r=await fetch("/api/snapshot",{cache:"no-store"});const d=await r.json();render(d);document.querySelector("#stamp").textContent="页面生成 "+new Date().toLocaleString("zh-CN")}
load().catch(e=>document.querySelector("#summary").innerHTML='<div class="empty">加载失败：'+esc(e.message)+'</div>');setInterval(load,60000);addEventListener("resize",()=>load());
</script></body></html>"""


def main():
    host = os.environ.get("MONITOR_HOST", "127.0.0.1")
    port = int(os.environ.get("MONITOR_PORT", "8899"))
    server = ThreadingHTTPServer((host, port), Handler)
    print(f"dashboard on http://{host}:{port}/ (data: {DATA})", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()

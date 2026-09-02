import base64
import asyncio
from datetime import datetime, timezone
from threading import Lock
from typing import Any

import json
import logging

from fastapi import FastAPI, Request
from fastapi.responses import HTMLResponse

app = FastAPI(title="Harmless Diagnostic Sink", version="1.0.0")
requests_seen: list[dict[str, Any]] = []
requests_lock = Lock()
logger = logging.getLogger("uvicorn.error")


CONSOLE_HTML = r'''<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <title>Receiver evidence desk</title>
  <style>
    :root{--ink:#15202b;--paper:#f4f7f6;--panel:#fff;--line:#cbd5d1;--muted:#64736d;--signal:#d97706;--danger:#b42318;--safe:#18794e;--terminal:#101916}
    *{box-sizing:border-box} body{margin:0;background:var(--paper);color:var(--ink);font:16px/1.5 system-ui,-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif}
    button{font:inherit}.shell{min-height:100vh;display:grid;grid-template-rows:auto 1fr}
    header{background:var(--ink);color:#fff;padding:18px clamp(20px,4vw,56px);display:flex;align-items:center;justify-content:space-between;gap:24px}
    .brand{display:flex;align-items:center;gap:14px}.mark{width:38px;height:38px;border:2px solid #f2b84b;display:grid;place-items:center;font:800 13px ui-monospace,monospace;transform:rotate(-3deg)}
    h1{font-size:18px;margin:0;letter-spacing:.02em}.subtitle{color:#b9c7c1;font-size:13px}.live{display:flex;align-items:center;gap:9px;font:700 12px ui-monospace,monospace;text-transform:uppercase;letter-spacing:.12em}.dot{width:9px;height:9px;border-radius:50%;background:#6ee7a8;box-shadow:0 0 0 5px #6ee7a822}
    main{width:min(1180px,calc(100% - 32px));margin:36px auto}.hero{display:grid;grid-template-columns:1.6fr .8fr;gap:18px;margin-bottom:22px}.hero>div{background:var(--panel);border:1px solid var(--line);padding:26px}
    .eyebrow,.label{font:700 11px ui-monospace,monospace;text-transform:uppercase;letter-spacing:.14em;color:var(--muted)}h2{font-size:clamp(27px,4vw,46px);line-height:1.04;margin:8px 0 12px;max-width:760px}.hero p{margin:0;color:var(--muted);max-width:700px}.counter{font:800 58px/1 ui-monospace,monospace;color:var(--signal)}
    .signal{border-left:7px solid var(--signal);background:#fff8e8;padding:14px 18px;margin-bottom:20px;font:700 13px ui-monospace,monospace;color:#7a4300}.signal.quiet{border-color:var(--safe);background:#eefaf3;color:#12623e}
    .tabs{display:flex;gap:4px;border-bottom:1px solid var(--line)}.tab{border:0;border-bottom:3px solid transparent;background:transparent;padding:13px 18px;color:var(--muted);font-weight:750;cursor:pointer}.tab[aria-selected="true"]{color:var(--ink);border-color:var(--signal)}.tab:focus-visible{outline:3px solid #2563eb;outline-offset:2px}
    .view{display:none;padding-top:20px}.view.active{display:block}.cards{display:grid;gap:12px}.event{background:var(--panel);border:1px solid var(--line);padding:18px;display:grid;grid-template-columns:150px 1fr auto;gap:18px;align-items:start}.badge{font:750 11px ui-monospace,monospace;color:var(--danger);text-transform:uppercase;letter-spacing:.08em}.meta{font:12px ui-monospace,monospace;color:var(--muted)}
    pre{white-space:pre-wrap;overflow-wrap:anywhere;margin:0}.artifact{background:var(--panel);border:1px solid var(--line);display:grid;grid-template-columns:280px 1fr}.facts{padding:22px;border-right:1px solid var(--line)}.facts dl{margin:18px 0 0}.facts dt{font:700 10px ui-monospace,monospace;color:var(--muted);text-transform:uppercase;letter-spacing:.12em}.facts dd{margin:4px 0 16px}.content{padding:22px}.file{margin-top:12px;background:#18231f;color:#e6f3ed;padding:20px;min-height:180px;font:14px/1.7 ui-monospace,SFMono-Regular,monospace}
    .terminal{background:var(--terminal);color:#d5e7df;border-top:5px solid var(--signal);padding:20px;min-height:260px;font:14px/1.75 ui-monospace,SFMono-Regular,monospace}.terminal .warn{color:#ffc766}.empty{background:var(--panel);border:1px dashed var(--line);padding:46px;text-align:center;color:var(--muted)}
    @media(max-width:760px){.hero{grid-template-columns:1fr}.event{grid-template-columns:1fr}.artifact{grid-template-columns:1fr}.facts{border-right:0;border-bottom:1px solid var(--line)}header{align-items:flex-start}.subtitle{display:none}}
    @media(prefers-reduced-motion:no-preference){.dot{animation:pulse 2s infinite}@keyframes pulse{50%{box-shadow:0 0 0 9px #6ee7a800}}}
  </style>
</head>
<body><div class="shell">
<header><div class="brand"><div class="mark">RX</div><div><h1>Receiver evidence desk</h1><div class="subtitle">Isolated demonstration namespace · synthetic data only</div></div></div><div class="live"><span class="dot"></span>listening :8080</div></header>
<main>
  <section class="hero"><div><div class="eyebrow">Runtime evidence</div><h2>See what crossed the trust boundary.</h2><p>This view turns receiver logs into presentation evidence. It never opens a command channel to a workload.</p></div><div><div class="label">Recorded events</div><div class="counter" id="count">0</div><div class="meta" id="latest">No activity yet</div></div></section>
  <div class="signal quiet" id="signal">QUIET — waiting for the demonstration workflow</div>
  <nav class="tabs" aria-label="Evidence views"><button class="tab" aria-selected="true" data-view="events">Events</button><button class="tab" aria-selected="false" data-view="artifact">Artifact</button><button class="tab" aria-selected="false" data-view="callback">Callback</button></nav>
  <section id="events" class="view active"><div class="cards" id="eventList"></div></section>
  <section id="artifact" class="view"><div id="artifactView"></div></section>
  <section id="callback" class="view"><div id="callbackView"></div></section>
</main></div>
<script>
const esc=s=>String(s??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
document.querySelectorAll('.tab').forEach(b=>b.onclick=()=>{document.querySelectorAll('.tab').forEach(x=>x.setAttribute('aria-selected',x===b));document.querySelectorAll('.view').forEach(v=>v.classList.toggle('active',v.id===b.dataset.view));});
function render(rows){
  document.querySelector('#count').textContent=rows.length; const last=rows.at(-1); document.querySelector('#latest').textContent=last?new Date(last.received_at).toLocaleTimeString():'No activity yet';
  const signal=document.querySelector('#signal'); signal.className='signal '+(rows.length?'':'quiet'); signal.textContent=rows.length?'WARNING — SYNTHETIC RUNTIME DATA RECEIVED':'QUIET — waiting for the demonstration workflow';
  document.querySelector('#eventList').innerHTML=rows.length?[...rows].reverse().map(e=>`<article class="event"><div class="badge">${esc(e.event||'diagnostic')}</div><div><strong>${esc(e.artifact||e.session||'Connectivity event')}</strong><div class="meta">source ${esc(e.source_ip||e.source||'unknown')} · ${esc(e.received_at)}</div></div><div class="meta">${esc(e.bytes??'—')} bytes</div></article>`).join(''):'<div class="empty">No receiver activity. Run the normal workflow first, then introduce the demonstration email.</div>';
  const a=[...rows].reverse().find(e=>e.event==='synthetic-environment-file'); document.querySelector('#artifactView').innerHTML=a?`<div class="artifact"><div class="facts"><div class="label">Received artifact</div><dl><dt>Path</dt><dd>${esc(a.artifact)}</dd><dt>Size</dt><dd>${esc(a.bytes)} bytes</dd><dt>Source</dt><dd>${esc(a.source_ip)}</dd><dt>Received</dt><dd>${esc(a.received_at)}</dd></dl></div><div class="content"><div class="label">Synthetic file content</div><pre class="file">${esc(a.content)}</pre></div></div>`:'<div class="empty">No synthetic environment artifact has been received.</div>';
  const c=[...rows].reverse().find(e=>e.event==='synthetic-callback'); document.querySelector('#callbackView').innerHTML=c?`<pre class="terminal"><span class="warn">ONE-SHOT CALLBACK TRANSCRIPT — no live command channel</span>\nconnection accepted from ${esc(c.source_ip)}\nsession ${esc(c.session)}\n\n${esc(c.transcript)}</pre>`:'<div class="empty">No callback evidence. The email workflow can submit a bounded, one-shot command transcript here.</div>';
}
async function refresh(){try{const r=await fetch('/requests',{cache:'no-store'});render(await r.json())}catch(e){document.querySelector('#signal').textContent='RECEIVER UNAVAILABLE — retrying';}} refresh(); setInterval(refresh,2000);
</script></body></html>'''


@app.get("/", response_class=HTMLResponse)
def console() -> str:
    return CONSOLE_HTML


@app.get("/healthz")
def health() -> dict[str, str]:
    return {"status": "ok"}


@app.get("/diagnostic")
def diagnostic(request: Request) -> dict[str, str]:
    event = {
        "received_at": datetime.now(timezone.utc).isoformat(),
        "source": request.client.host if request.client else "unknown",
        "user_agent": request.headers.get("user-agent", "unknown"),
    }
    with requests_lock:
        requests_seen.append(event)
    return {"status": "harmless-demo-request-recorded"}


@app.post("/artifacts/environment")
async def receive_environment(request: Request) -> dict[str, str | int]:
    body = await request.body()
    if len(body) > 4096:
        return {"status": "rejected", "bytes": len(body)}
    content = body.decode("utf-8", errors="replace")
    event = {
        "received_at": datetime.now(timezone.utc).isoformat(),
        "source_ip": request.client.host if request.client else "unknown",
        "event": "synthetic-environment-file",
        "artifact": "/tmp/agent-runtime-context.snapshot",
        "bytes": len(body),
        "content": content,
    }
    with requests_lock:
        requests_seen.append(event)
    logger.warning("DEMO_ENV_FILE_RECEIVED %s", json.dumps(event, sort_keys=True))
    # Keep the harmless client process alive long enough for runtime sensors to
    # observe the short-lived curl child process reliably during the demo.
    await asyncio.sleep(3)
    return {"status": "synthetic-environment-file-recorded", "bytes": len(body)}


@app.post("/callbacks/connect")
async def record_callback(request: Request) -> dict[str, str]:
    """Record callback evidence without creating a command or shell channel."""
    body = await request.body()
    if len(body) > 8192:
        return {"status": "rejected", "session": "none"}
    identity = "uid=1001(agent)"
    workload = "ai-email-demo/openclaw"
    if request.headers.get("content-type", "").startswith("application/json"):
        supplied = json.loads(body or b"{}")
        identity = str(supplied.get("identity", identity))[:160]
        workload = str(supplied.get("workload", workload))[:160]
        transcript = (
            "$ id\n" + identity +
            "\n$ workload\n" + workload
        )
    else:
        transcript = body.decode("utf-8", errors="replace")
    event = {
        "received_at": datetime.now(timezone.utc).isoformat(),
        "source_ip": request.client.host if request.client else "unknown",
        "event": "synthetic-callback",
        "session": "demo-session",
        "bytes": len(body),
        "identity": identity,
        "workload": workload,
        "transcript": transcript,
    }
    with requests_lock:
        requests_seen.append(event)
    logger.warning("DEMO_CALLBACK_RECEIVED %s", json.dumps(event, sort_keys=True))
    # Hold the client open long enough for Collector to retain the short-lived
    # curl process in the runtime evidence, matching the artifact endpoint.
    await asyncio.sleep(3)
    return {"status": "synthetic-callback-recorded", "session": "demo-session"}


@app.get("/records/sync/{encoded_path:path}")
def webhook(encoded_path: str, request: Request) -> dict[str, str]:
    chunks = encoded_path.split("/")
    encoded = "".join(chunks)
    decoded = base64.b64decode(encoded, altchars=b"-_", validate=True).decode()
    event = {
        "received_at": datetime.now(timezone.utc).isoformat(),
        "source_ip": request.client.host if request.client else "unknown",
        "event": "synthetic-demo-artifact",
        "source": "openclaw-demo",
        "artifact": ".env",
        "simulation": "records-sync",
        "encoding": "base64url",
        "chunks": chunks,
        "decoded_synthetic_content": decoded,
    }
    with requests_lock:
        requests_seen.append(event)
    logger.warning("DEMO_WEBHOOK_EVENT %s", json.dumps(event, sort_keys=True))
    return {"status": "synthetic-demo-artifact-recorded"}


@app.get("/requests")
def list_requests() -> list[dict[str, Any]]:
    with requests_lock:
        return list(requests_seen)


@app.delete("/requests")
def clear_requests() -> dict[str, int]:
    with requests_lock:
        count = len(requests_seen)
        requests_seen.clear()
    return {"deleted": count}

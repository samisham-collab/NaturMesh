#!/usr/bin/env python3
"""
ShelterNet - offline LAN messaging.

Serves a web page and relays messages between everyone on the same network.
No internet, no accounts, no app install. Python 3 standard library only.

    python3 shelternet.py
    python3 shelternet.py --port 8080 --net "Sherman County EOC"

Then point phones, Macs, anything with a browser at the URL it prints.
"""

import argparse
import json
import queue
import re
import socket
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

HISTORY_MAX = 300
MAX_TEXT = 900
MAX_NAME = 24

_lock = threading.Lock()
_history = []
_clients = {}          # client id -> {"q": Queue, "name": str}
_next_id = 0
_next_seq = 0
NET_NAME = "ShelterNet"


# ---------------------------------------------------------------- plumbing

def _now():
    return time.time()


def _clean(s, limit):
    s = re.sub(r"[\x00-\x08\x0b\x0c\x0e-\x1f]", "", str(s or ""))
    return s.strip()[:limit]


def broadcast(event):
    with _lock:
        targets = [c["q"] for c in _clients.values()]
    for q in targets:
        try:
            q.put_nowait(event)
        except queue.Full:
            pass


def roster():
    with _lock:
        names = [c["name"] for c in _clients.values() if c["name"]]
    seen, out = set(), []
    for n in sorted(names, key=str.lower):
        if n.lower() not in seen:
            seen.add(n.lower())
            out.append(n)
    return out


def presence_event():
    names = roster()
    return {"type": "presence", "count": len(names), "names": names}


def add_message(name, text, urgent):
    global _next_seq
    with _lock:
        _next_seq += 1
        msg = {
            "type": "msg",
            "seq": _next_seq,
            "name": name,
            "text": text,
            "urgent": bool(urgent),
            "t": _now(),
        }
        _history.append(msg)
        del _history[:-HISTORY_MAX]
    broadcast(msg)
    return msg


def local_addresses():
    """Best-effort list of IPv4 addresses this box is reachable on."""
    found = []
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("192.0.2.1", 9))  # never actually sends
        found.append(s.getsockname()[0])
        s.close()
    except OSError:
        pass
    try:
        for info in socket.getaddrinfo(socket.gethostname(), None, socket.AF_INET):
            ip = info[4][0]
            if not ip.startswith("127.") and ip not in found:
                found.append(ip)
    except OSError:
        pass
    return found or ["127.0.0.1"]


# ---------------------------------------------------------------- the page

PAGE = r"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<meta name="color-scheme" content="dark">
<title>__NET__</title>
<style>
  :root{
    --panel:#0F1519;
    --raised:#161F25;
    --rule:#26333B;
    --text:#E9EEF0;
    --dim:#8496A0;
    --signal:#FFB020;
    --live:#3FBF74;
    --alert:#FF5140;
    --shadow:rgba(0,0,0,.45);
  }
  *{box-sizing:border-box;margin:0;padding:0}
  html,body{height:100%}
  body{
    background:var(--panel);
    color:var(--text);
    font-family:system-ui,-apple-system,"Segoe UI",Roboto,sans-serif;
    font-size:17px;
    line-height:1.45;
    -webkit-text-size-adjust:100%;
    overflow:hidden;
  }
  .mono{font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;
        font-variant-numeric:tabular-nums}

  /* ---- shell ---- */
  .shell{display:flex;flex-direction:column;height:100dvh}

  /* ---- status strip: the readout ---- */
  header{
    flex:none;
    padding:calc(env(safe-area-inset-top) + 14px) 18px 14px;
    border-bottom:1px solid var(--rule);
    background:var(--panel);
    display:flex;align-items:baseline;gap:14px;
  }
  .count{
    font-size:38px;font-weight:650;letter-spacing:-.02em;
    line-height:1;color:var(--signal);
  }
  .count.solo{color:var(--dim)}
  .hgroup{flex:1;min-width:0}
  .hgroup h1{
    font-size:16px;font-weight:600;letter-spacing:-.01em;
    white-space:nowrap;overflow:hidden;text-overflow:ellipsis;
  }
  .hgroup p{font-size:13px;color:var(--dim)}
  .link{
    flex:none;display:flex;align-items:center;gap:7px;
    font-size:12px;color:var(--dim);
  }
  .dot{width:9px;height:9px;border-radius:50%;background:var(--dim)}
  .link[data-state="live"] .dot{background:var(--live)}
  .link[data-state="lost"] .dot{background:var(--alert);animation:pulse 1.1s infinite}
  @keyframes pulse{50%{opacity:.25}}
  @media (prefers-reduced-motion:reduce){.link[data-state="lost"] .dot{animation:none}}

  /* ---- log ---- */
  #log{
    flex:1;overflow-y:auto;overscroll-behavior:contain;
    -webkit-overflow-scrolling:touch;
    padding:6px 0 12px;
  }
  .entry{
    padding:11px 18px 12px;
    border-bottom:1px solid var(--rule);
  }
  .entry.mine{background:var(--raised)}
  .entry.urgent{border-left:3px solid var(--alert);padding-left:15px}
  .meta{display:flex;align-items:baseline;gap:9px;margin-bottom:3px}
  .who{font-size:13px;font-weight:650;color:var(--signal)}
  .entry.mine .who{color:var(--live)}
  .when{font-size:12px;color:var(--dim)}
  .flag{
    font-size:11px;font-weight:650;color:var(--alert);
    border:1px solid var(--alert);border-radius:3px;padding:0 5px;
  }
  .body{white-space:pre-wrap;word-wrap:break-word;max-width:68ch}
  .note{padding:14px 18px;color:var(--dim);font-size:14px;max-width:60ch}

  /* ---- composer ---- */
  footer{
    flex:none;border-top:1px solid var(--rule);background:var(--panel);
    padding:11px 14px calc(env(safe-area-inset-bottom) + 11px);
    box-shadow:0 -8px 20px var(--shadow);
  }
  .row{display:flex;gap:10px;align-items:flex-end}
  textarea,input{
    font:inherit;color:var(--text);background:var(--raised);
    border:1px solid var(--rule);border-radius:8px;padding:11px 12px;width:100%;
  }
  textarea{resize:none;max-height:8.5em;min-height:46px;line-height:1.4}
  :focus-visible{outline:2px solid var(--signal);outline-offset:2px}
  button{
    font:inherit;font-weight:600;cursor:pointer;border-radius:8px;
    border:1px solid var(--rule);background:var(--raised);color:var(--text);
    padding:11px 14px;flex:none;
  }
  #send{background:var(--signal);border-color:var(--signal);color:#11181C}
  #send:disabled{opacity:.4;cursor:default}
  #urgent{width:46px;height:46px;font-size:19px;line-height:1}
  #urgent[aria-pressed="true"]{
    background:var(--alert);border-color:var(--alert);color:#fff}
  .strip{
    display:flex;justify-content:space-between;align-items:center;
    font-size:12px;color:var(--dim);margin-bottom:9px;gap:12px;
  }
  .strip button{
    background:none;border:none;color:var(--dim);padding:0;
    text-decoration:underline;font-size:12px;font-weight:400;
  }

  /* ---- name gate ---- */
  #gate{
    position:fixed;inset:0;background:var(--panel);z-index:20;
    display:flex;flex-direction:column;justify-content:center;
    padding:28px;gap:18px;
  }
  #gate.done{display:none}
  #gate h2{font-size:27px;font-weight:650;letter-spacing:-.02em}
  #gate p{color:var(--dim);font-size:15px;max-width:44ch}
  #gate .row{max-width:460px}
  #gate button{background:var(--signal);border-color:var(--signal);color:#11181C}
</style>
</head>
<body>

<div class="shell">
  <header>
    <div class="count solo" id="count">1</div>
    <div class="hgroup">
      <h1 id="netname">__NET__</h1>
      <p id="who">on this net</p>
    </div>
    <div class="link" id="link" data-state="lost">
      <span class="dot"></span><span id="linktext">connecting</span>
    </div>
  </header>

  <div id="log" aria-live="polite">
    <p class="note" id="empty">No messages yet. Anything sent here reaches
      everyone on this network, with or without internet.</p>
  </div>

  <footer>
    <div class="strip">
      <span>Signed in as <b id="myname" class="mono"></b></span>
      <button id="rename" type="button">Change name</button>
    </div>
    <div class="row">
      <textarea id="text" rows="1" placeholder="Message everyone"
                maxlength="900" enterkeyhint="send"></textarea>
      <button id="urgent" type="button" aria-pressed="false"
              title="Mark urgent" aria-label="Mark urgent">!</button>
      <button id="send" type="button" disabled>Send</button>
    </div>
  </footer>
</div>

<div id="gate">
  <h2>Who's on the radio?</h2>
  <p>Pick a name others will recognize — a call sign, a room number, or
     just your first name. Nothing is stored anywhere but this machine.</p>
  <div class="row">
    <input id="namein" maxlength="24" placeholder="e.g. Sam / Shelter 2 / Bus 14"
           autocomplete="off" enterkeyhint="go">
    <button id="join" type="button">Join</button>
  </div>
</div>

<script>
(function(){
  var $ = function(id){ return document.getElementById(id); };
  var name = "", urgent = false, es = null, seen = {};

  /* ---------- name gate ---------- */
  try { name = localStorage.getItem("shelternet.name") || ""; } catch(e){}

  function enter(n){
    n = (n||"").trim().slice(0,24);
    if(!n) { $("namein").focus(); return; }
    name = n;
    try { localStorage.setItem("shelternet.name", n); } catch(e){}
    $("myname").textContent = n;
    $("gate").classList.add("done");
    $("text").focus();
    connect();
  }
  $("join").onclick = function(){ enter($("namein").value); };
  $("namein").onkeydown = function(e){ if(e.key === "Enter") enter(this.value); };
  $("rename").onclick = function(){
    $("gate").classList.remove("done");
    $("namein").value = name;
    $("namein").focus();
    if(es){ es.close(); es = null; }
  };

  /* ---------- log ---------- */
  var log = $("log");
  function atBottom(){
    return log.scrollHeight - log.scrollTop - log.clientHeight < 90;
  }
  function clock(t){
    var d = new Date(t*1000);
    return String(d.getHours()).padStart(2,"0") + ":" +
           String(d.getMinutes()).padStart(2,"0");
  }
  function render(m){
    if(seen[m.seq]) return;
    seen[m.seq] = 1;
    var stick = atBottom();
    var e = document.createElement("div");
    e.className = "entry" + (m.name === name ? " mine" : "") +
                            (m.urgent ? " urgent" : "");
    var meta = document.createElement("div"); meta.className = "meta";
    var who = document.createElement("span"); who.className = "who";
    who.textContent = m.name;
    var when = document.createElement("span"); when.className = "when mono";
    when.textContent = clock(m.t);
    meta.appendChild(who); meta.appendChild(when);
    if(m.urgent){
      var f = document.createElement("span");
      f.className = "flag"; f.textContent = "urgent";
      meta.appendChild(f);
    }
    var body = document.createElement("div");
    body.className = "body"; body.textContent = m.text;
    e.appendChild(meta); e.appendChild(body);
    log.appendChild(e);
    var empty = $("empty"); if(empty) empty.remove();
    if(stick) log.scrollTop = log.scrollHeight;
  }

  /* ---------- presence ---------- */
  function presence(p){
    $("count").textContent = p.count;
    $("count").classList.toggle("solo", p.count < 2);
    $("who").textContent = p.count === 1
      ? "only you so far" : "on this net";
    $("netname").title = p.names.join(", ");
  }

  /* ---------- link state ---------- */
  function link(state, label){
    $("link").dataset.state = state;
    $("linktext").textContent = label;
  }

  /* ---------- stream ---------- */
  function connect(){
    if(es) es.close();
    es = new EventSource("/events?name=" + encodeURIComponent(name));
    es.onopen = function(){ link("live","live"); };
    es.onerror = function(){ link("lost","reconnecting"); };
    es.onmessage = function(ev){
      var d;
      try { d = JSON.parse(ev.data); } catch(e){ return; }
      if(d.type === "msg") render(d);
      else if(d.type === "presence") presence(d);
    };
  }

  /* ---------- composer ---------- */
  var text = $("text");
  function resize(){
    text.style.height = "auto";
    text.style.height = Math.min(text.scrollHeight, 136) + "px";
    $("send").disabled = !text.value.trim();
  }
  text.addEventListener("input", resize);
  text.addEventListener("keydown", function(e){
    if(e.key === "Enter" && !e.shiftKey && !e.isComposing){
      e.preventDefault(); send();
    }
  });
  $("urgent").onclick = function(){
    urgent = !urgent;
    this.setAttribute("aria-pressed", urgent ? "true" : "false");
  };
  $("send").onclick = send;

  function send(){
    var body = text.value.trim();
    if(!body) return;
    text.value = ""; resize();
    var payload = JSON.stringify({name:name, text:body, urgent:urgent});
    urgent = false;
    $("urgent").setAttribute("aria-pressed","false");
    fetch("/send", {method:"POST", headers:{"Content-Type":"application/json"},
                    body:payload})
      .catch(function(){
        render({seq:"e"+Date.now(), name:"ShelterNet", t:Date.now()/1000,
                urgent:true, text:"Not delivered — no link to the server. "+
                "Your message is back in the box; try again."});
        text.value = body; resize();
      });
  }

  document.addEventListener("visibilitychange", function(){
    if(!document.hidden && name && (!es || es.readyState === 2)) connect();
  });

  if(name){ enter(name); } else { $("namein").focus(); }
})();
</script>
</body>
</html>
"""


# ---------------------------------------------------------------- handler

class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "ShelterNet"

    def log_message(self, fmt, *args):
        pass  # keep the console readable

    # -- helpers ---------------------------------------------------------

    def _send(self, code, body, ctype="text/plain; charset=utf-8", extra=None):
        if isinstance(body, str):
            body = body.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(body)

    # -- routes ----------------------------------------------------------

    def do_GET(self):
        route = urlparse(self.path)
        if route.path in ("/", "/index.html"):
            self._send(200, PAGE.replace("__NET__", NET_NAME),
                       "text/html; charset=utf-8")
        elif route.path == "/events":
            self.stream(parse_qs(route.query).get("name", [""])[0])
        elif route.path == "/health":
            self._send(200, json.dumps({"ok": True, "here": len(roster())}),
                       "application/json")
        else:
            self._send(404, "not found")

    def do_POST(self):
        if urlparse(self.path).path != "/send":
            self._send(404, "not found")
            return
        try:
            length = int(self.headers.get("Content-Length", "0"))
            data = json.loads(self.rfile.read(min(length, 4096)) or b"{}")
        except (ValueError, OSError):
            self._send(400, "bad request")
            return
        name = _clean(data.get("name"), MAX_NAME) or "unnamed"
        text = _clean(data.get("text"), MAX_TEXT)
        if not text:
            self._send(400, "empty message")
            return
        add_message(name, text, data.get("urgent"))
        self._send(200, "ok")

    # -- server-sent events ----------------------------------------------

    def stream(self, name):
        global _next_id
        name = _clean(name, MAX_NAME)
        q = queue.Queue(maxsize=400)

        with _lock:
            _next_id += 1
            cid = _next_id
            _clients[cid] = {"q": q, "name": name}
            backlog = list(_history)

        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Connection", "keep-alive")
        self.send_header("X-Accel-Buffering", "no")
        self.end_headers()

        try:
            self.wfile.write(b"retry: 2000\n\n")
            for msg in backlog:
                self.push(msg)
            broadcast(presence_event())
            while True:
                try:
                    self.push(q.get(timeout=15))
                except queue.Empty:
                    self.wfile.write(b": keepalive\n\n")
                    self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError, OSError):
            pass
        finally:
            with _lock:
                _clients.pop(cid, None)
            broadcast(presence_event())

    def push(self, event):
        payload = json.dumps(event, separators=(",", ":"))
        self.wfile.write(("data: " + payload + "\n\n").encode("utf-8"))
        self.wfile.flush()


# ---------------------------------------------------------------- startup

def main():
    global NET_NAME
    ap = argparse.ArgumentParser(description="Offline LAN messaging.")
    ap.add_argument("--port", type=int, default=8000)
    ap.add_argument("--host", default="0.0.0.0")
    ap.add_argument("--net", default="ShelterNet",
                    help="name shown at the top of the page")
    args = ap.parse_args()
    NET_NAME = _clean(args.net, 48) or "ShelterNet"

    srv = ThreadingHTTPServer((args.host, args.port), Handler)
    srv.daemon_threads = True

    print("\n  " + NET_NAME + " is up. Anyone on this network can join at:\n")
    for ip in local_addresses():
        print("      http://%s:%d" % (ip, args.port))
    print("\n  No internet required. Ctrl-C to stop.\n")

    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        print("  Stopped.\n")


if __name__ == "__main__":
    main()

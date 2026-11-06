#!/usr/bin/env python3
"""Registers this Android phone (Termux) with the EMISSARY Supervisor, exactly like the
Windows Worker enrollment: POST /api/compute/nodes with a per-node credential.
The owner still has to approve it on the MSI (authorize_research_worker.py)."""
import json, os, platform, sys, urllib.request
from pathlib import Path

CONFIG_DIR = Path(os.environ.get("EMISSARY_WORKER_CONFIG_DIR", str(Path.home() / "EMISSARY_Worker" / "config")))
ENROLL = CONFIG_DIR / "worker_enrollment.json"
BASE = os.environ.get("EMISSARY_SUPERVISOR_BASE_URL", "https://msi.tail21a0f7.ts.net").rstrip("/")
NAME = os.environ.get("EMISSARY_NODE_NAME", "samsung-node")

def ram():
    try:
        for line in open("/proc/meminfo"):
            if line.startswith("MemTotal:"):
                return int(line.split()[1]) * 1024
    except OSError:
        return None

if ENROLL.exists() and "--force" not in sys.argv:
    print(f"[ok] Already enrolled: {json.loads(ENROLL.read_text())['node_id']} (use --force to re-enroll)")
    sys.exit(0)
caps = {"operating_system": "Android (Termux)", "architecture": platform.machine(), "cpu_cores": os.cpu_count(),
        "total_ram_bytes": ram(), "inference_runtimes": ["ollama"], "worker_version": "android-1.0.0"}
body = json.dumps({"node_type": "MOBILE", "node_name": NAME, "platform": "Android", "capabilities": caps,
                   "transport": "TAILSCALE", "issue_credential": True, "workspace_id": "ws-1"}).encode()
req = urllib.request.Request(BASE + "/api/compute/nodes", data=body, method="POST",
                             headers={"Content-Type": "application/json"})
try:
    with urllib.request.urlopen(req, timeout=30) as r:
        reply = json.loads(r.read().decode())
except Exception as e:
    sys.exit(f"[!] Could not reach the Supervisor at {BASE} - is Tailscale on? ({e})")
if not reply.get("node_id"):
    sys.exit(f"[!] Registration refused: {reply.get('error')}")
CONFIG_DIR.mkdir(parents=True, exist_ok=True)
ENROLL.write_text(json.dumps({"node_id": reply["node_id"], "base_url": BASE, "worker_token": reply.get("worker_token")}))
os.chmod(ENROLL, 0o600)
print(f"[ok] Registered as {reply['node_id']}. Now approve it on the MSI: python authorize_research_worker.py")

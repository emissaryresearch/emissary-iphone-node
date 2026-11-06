#!/usr/bin/env python3
"""EMISSARY generic Windows worker (bounded, pull-based).

Uses the existing Supervisor task APIs. STATUS_REPORT and DOCUMENTATION never
invoke a shell/subprocess/agent CLI - unknown capabilities or any execution
permission other than "none" are rejected for both. CLAUDE_CODE_EXECUTION
(Remote Claude Code Execution V1) is the one deliberate, DOUBLE opt-in
exception - see claude_code_execution()'s own docstring for the complete,
enforced invariant list: it requires BOTH this device's own
EMISSARY_ENABLE_CLAUDE_CODE_EXECUTION=1 AND the MSI operator's separate
authorization_scope={"claude_code_execution": true} grant (enforced
server-side by bridge.compute_orchestrator) - neither alone is enough, and
it still never runs with execution_permission="none" (that value is
reserved for the no-subprocess capabilities above; CLAUDE_CODE_EXECUTION
requires the distinct "claude_code_bounded").
"""
from __future__ import annotations
import hashlib, http.client, threading, ipaddress, json, os, platform, re, shutil, socket, ssl, subprocess, time, urllib.error, urllib.parse, urllib.request
from datetime import datetime, timezone
from pathlib import Path

WORKER_VERSION = "1.5.1"
CONFIG_DIR = Path(os.environ.get("EMISSARY_WORKER_CONFIG_DIR", str(Path.home() / "EMISSARY_Worker" / "config")))
ENROLLMENT_FILE = CONFIG_DIR / "worker_enrollment.json"
ARTIFACT_DIR = Path(os.environ.get("EMISSARY_ARTIFACT_DIR", str(Path.home() / "EMISSARY_Worker" / "artifacts")))
POLL_SECONDS = max(5.0, float(os.environ.get("EMISSARY_POLL_INTERVAL_SECONDS", "15")))
HEARTBEAT_SECONDS = max(15.0, float(os.environ.get("EMISSARY_HEARTBEAT_INTERVAL_SECONDS", "45")))
# Bounded exponential backoff ceiling for heartbeat re-attempt pacing,
# same convention as worker_client/chromebook_worker_client.py - a
# genuinely offline Supervisor gets retried less and less often rather
# than hammered every HEARTBEAT_SECONDS forever.
MAX_HEARTBEAT_BACKOFF_SECONDS = max(HEARTBEAT_SECONDS, float(os.environ.get("EMISSARY_MAX_HEARTBEAT_BACKOFF_SECONDS", "300")))
MAX_ARTIFACT_BYTES = 64 * 1024
SAFE_TASK_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$")
CAPABILITIES = {"STATUS_REPORT", "DOCUMENTATION", "CLAUDE_CODE_EXECUTION", "LOCAL_MODEL_RESEARCH"}
PERMISSION = "none"
CLAUDE_PERMISSION = "claude_code_bounded"
REQUIRED_PERMISSION = {"STATUS_REPORT": PERMISSION, "DOCUMENTATION": PERMISSION, "CLAUDE_CODE_EXECUTION": CLAUDE_PERMISSION, "LOCAL_MODEL_RESEARCH": PERMISSION}
# Remote Claude Code Execution V1 - see claude_code_execution()'s own docstring.
CLAUDE_WORKSPACE_ROOT = Path(os.environ.get("EMISSARY_CLAUDE_WORKSPACE_ROOT", str(ARTIFACT_DIR / "claude_workspace")))
CLAUDE_ALLOWED_TOOLS = os.environ.get("EMISSARY_CLAUDE_ALLOWED_TOOLS", "Read,Write,Edit")
CLAUDE_TIMEOUT_SECONDS = float(os.environ.get("EMISSARY_CLAUDE_TIMEOUT_SECONDS", "600"))
CLAUDE_MODEL = os.environ.get("EMISSARY_CLAUDE_MODEL", "claude-sonnet-5")
MAX_CLAUDE_MANIFEST_FILE_BYTES = 4 * 1024 * 1024

def claude_execution_enabled():
    return os.environ.get("EMISSARY_ENABLE_CLAUDE_CODE_EXECUTION", "").strip() == "1"
# Best-effort persistent log alongside stdout - same convention as
# worker_client/chromebook_worker_client.py's own WORKER_LOG_PATH, so an
# unattended run (no attached terminal) still leaves a readable trail.
LOG_PATH = Path(os.environ.get("EMISSARY_WORKER_LOG", str(Path.home() / "EMISSARY_Worker" / "worker.log")))

def now():
    return datetime.now(timezone.utc).isoformat()

def log(line):
    print(line)
    try:
        LOG_PATH.parent.mkdir(parents=True, exist_ok=True)
        with LOG_PATH.open("a", encoding="utf-8") as fh:
            fh.write(f"{now()} {line}\n")
    except OSError:
        pass  # stdout above already carries this line

def load_config():
    if not ENROLLMENT_FILE.is_file():
        raise RuntimeError(f"Enrollment file missing: {ENROLLMENT_FILE}; run windows_worker_setup.ps1 first.")
    data = json.loads(ENROLLMENT_FILE.read_text(encoding="utf-8"))
    node_id, base_url = data.get("node_id"), data.get("base_url")
    if not isinstance(node_id, str) or not node_id or not isinstance(base_url, str) or not base_url.startswith("https://"):
        raise RuntimeError("Enrollment file lacks a valid node_id or HTTPS base_url.")
    parsed = urllib.parse.urlsplit(base_url)
    if not parsed.hostname or parsed.username or parsed.password or parsed.path not in ("", "/"):
        raise RuntimeError("Supervisor base URL must be an HTTPS origin with no credentials or path.")
    connect_ip = data.get("connect_ip")
    if connect_ip:
        ipaddress.ip_address(connect_ip)
    worker_token = data.get("worker_token")  # None for a pre-Security-Hardening-V2 enrollment - handled honestly below
    return node_id, base_url.rstrip("/"), connect_ip, parsed.hostname, worker_token

class PinnedHTTPSConnection(http.client.HTTPSConnection):
    def __init__(self, *args, connect_ip, **kwargs):
        super().__init__(*args, **kwargs); self._connect_ip = connect_ip
    def connect(self):
        sock = socket.create_connection((self._connect_ip, self.port or 443), self.timeout)
        self.sock = self._context.wrap_socket(sock, server_hostname=self.host)

class PinnedHTTPSHandler(urllib.request.HTTPSHandler):
    def __init__(self, connect_ip):
        super().__init__(); self.connect_ip = connect_ip
    def https_open(self, req):
        return self.do_open(lambda host, **kw: PinnedHTTPSConnection(host, connect_ip=self.connect_ip, **kw),
                            req, context=ssl.create_default_context())

class Client:
    def __init__(self, node_id, base_url, connect_ip, worker_token=None):
        self.node_id, self.base_url, self.worker_token = node_id, base_url, worker_token
        handlers = [urllib.request.ProxyHandler({})]
        if connect_ip: handlers.append(PinnedHTTPSHandler(connect_ip))
        self.opener = urllib.request.build_opener(*handlers)
    def _with_token(self, body):
        # Sent on every call so a Supervisor that issued this node a
        # credential (Security Hardening V2) can verify identity, not
        # just node_id. Harmless to send even if the Supervisor never
        # issued one - verify_worker_credential() ignores it for a
        # legacy/no-credential node.
        if self.worker_token:
            body["worker_token"] = self.worker_token
        return body
    def request(self, method, path, body=None, timeout=15):
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(self.base_url + path, data=data, method=method,
                                     headers={"Content-Type":"application/json"})
        try:
            with self.opener.open(req, timeout=timeout) as resp:
                raw = resp.read()
                return json.loads(raw.decode()) if raw else {}
        except urllib.error.HTTPError as e:
            try: return json.loads(e.read().decode())
            except Exception: return {"success":False,"error":str(e),"http_status":e.code}
        except (urllib.error.URLError, TimeoutError, OSError) as e:
            return {"success":False,"error":f"network_error: {e}"}
    def heartbeat(self):
        return self.request("POST", f"/api/compute/nodes/{urllib.parse.quote(self.node_id,safe='')}/heartbeat",
                            self._with_token({"health":{"healthy":True,"worker_version":WORKER_VERSION}}))
    def report_capabilities(self, snapshot):
        return self.request("POST", f"/api/compute/nodes/{urllib.parse.quote(self.node_id,safe='')}/capabilities",
                            self._with_token({"capabilities":snapshot}))
    def tasks(self, phase):
        q = urllib.parse.urlencode({"node_id":self.node_id,"phase":phase})
        r = self.request("GET", "/api/compute/tasks?"+q)
        return r.get("tasks",[]) if r.get("success") else []
    def start(self, task_id):
        return self.request("POST", f"/api/compute/tasks/{urllib.parse.quote(task_id,safe='')}/start", self._with_token({"node_id":self.node_id}))
    def complete(self, task_id, result):
        return self.request("POST", f"/api/compute/tasks/{urllib.parse.quote(task_id,safe='')}/complete",
                            self._with_token({"node_id":self.node_id,"result":result}))
    def fail(self, task_id, reason):
        return self.request("POST", f"/api/compute/tasks/{urllib.parse.quote(task_id,safe='')}/fail",
                            self._with_token({"node_id":self.node_id,"stopping_reason":"task_failure","error":reason}))

def status_report(node_id, task):
    tid=task.get("task_id")
    if not isinstance(tid,str) or not SAFE_TASK_ID.fullmatch(tid): raise ValueError("unsafe or missing task_id")
    ARTIFACT_DIR.mkdir(parents=True,exist_ok=True)
    rp=ARTIFACT_DIR/(tid+".result.json")
    if rp.exists(): return json.loads(rp.read_text(encoding="utf-8"))
    result={"worker_identity":node_id,"worker_version":WORKER_VERSION,"worker_hostname":socket.gethostname(),
            "platform":platform.platform(),"python_version":platform.python_version(),"cpu_cores":os.cpu_count(),
            "task_id":tid,"capability":"STATUS_REPORT","timestamp":now(),
            "execution_permission":"none","shell_execution":False,
            "supported_capabilities":sorted(CAPABILITIES)}
    rp.write_text(json.dumps(result,sort_keys=True),encoding="utf-8")
    return result

def documentation(node_id, base_url, task):
    tid=task.get("task_id")
    if not isinstance(tid,str) or not SAFE_TASK_ID.fullmatch(tid): raise ValueError("unsafe or missing task_id")
    ARTIFACT_DIR.mkdir(parents=True,exist_ok=True)
    rp=ARTIFACT_DIR/(tid+".result.json")
    if rp.exists(): return json.loads(rp.read_text(encoding="utf-8"))
    prov=task.get("input_provenance") or {}
    lines=[
        "# "+str(prov.get("title") or "EMISSARY Worker Report").replace("\n"," "),
        "",f"- Generated UTC: {now()}",f"- Worker: {node_id}",f"- Hostname: {socket.gethostname()}",
        f"- Worker version: {WORKER_VERSION}",f"- Platform: {platform.platform()}",
        f"- Supervisor origin: {base_url}",f"- Task ID: {tid}",
        f"- Requested capability: {prov.get('capability')}",
        f"- Workload: {task.get('workload')}",f"- Assigned node: {task.get('assigned_node_id')}",
        f"- Execution permission: {prov.get('execution_permission')}",
        "", "## Objective supplied by Supervisor (not independently verified)",
        "", str(prov.get("summary") or "(no objective supplied)").replace("\n"," "),
        "", "## Execution boundary", "",
        "This worker performed a bounded documentation task. It did not invoke a shell, subprocess, installed AI agent, or arbitrary command.",
        "The returned SHA-256 identifies the exact artifact bytes; it does not independently prove the objective's claims.",
        ""
    ]
    content="\n".join(lines).encode("utf-8")
    if len(content)>MAX_ARTIFACT_BYTES: raise ValueError("artifact exceeds size limit")
    ap=ARTIFACT_DIR/(tid+".md")
    tmp=ap.with_suffix(".md.tmp"); tmp.write_bytes(content); os.replace(tmp,ap)
    result={"worker_identity":node_id,"worker_hostname":socket.gethostname(),"worker_version":WORKER_VERSION,
            "platform":platform.platform(),"capability":"DOCUMENTATION","task_id":tid,"generated_at":now(),
            "execution_permission":"none","artifact_filename":ap.name,"artifact_media_type":"text/markdown",
            "artifact_bytes":len(content),"artifact_sha256":hashlib.sha256(content).hexdigest(),
            "artifact_worker_path":str(ap),"artifact_content":content.decode("utf-8")}
    rp.write_text(json.dumps(result,sort_keys=True),encoding="utf-8")
    return result

def claude_code_execution(node_id, task):
    """The one, deliberate, double-opted-in exception to this file's own
    no-subprocess rule for every other capability - enforced HERE:
    - Checked again here (not just by validate()) that this device opted in.
    - argv-only subprocess.run(..., shell=False) - the prompt is one argv
      element, never interpolated into a shell string.
    - Confined to a FRESH per-task directory under CLAUDE_WORKSPACE_ROOT -
      never an arbitrary/caller-supplied path (task_id is re-validated first).
    - --allowedTools restricted to CLAUDE_ALLOWED_TOOLS (default
      Read,Write,Edit - no Bash, no network-capable tool).
    - Mandatory timeout via subprocess's own timeout= - killed, not left
      running, on expiry.
    - Result validation: every file actually left in the confined workspace
      is walked and SHA-256'd into a manifest - never raw unbounded content.
    """
    if not claude_execution_enabled():
        raise ValueError("CLAUDE_CODE_EXECUTION is not enabled on this device (EMISSARY_ENABLE_CLAUDE_CODE_EXECUTION != '1')")
    tid=task.get("task_id")
    if not isinstance(tid,str) or not SAFE_TASK_ID.fullmatch(tid): raise ValueError("unsafe or missing task_id")
    executable=shutil.which("claude")
    if executable is None: raise ValueError("the 'claude' CLI was not found on PATH on this device")
    prov=task.get("input_provenance") or {}
    prompt=prov.get("summary") or prov.get("title")
    if not prompt: raise ValueError("no objective (input_provenance.summary/title) was supplied for this task")
    task_workspace=(CLAUDE_WORKSPACE_ROOT/tid).resolve()
    CLAUDE_WORKSPACE_ROOT.mkdir(parents=True,exist_ok=True)
    task_workspace.mkdir(parents=True,exist_ok=True)
    if task_workspace.parent != CLAUDE_WORKSPACE_ROOT.resolve():
        raise ValueError("workspace confinement check failed - refusing to execute")
    command=[executable,"-p",prompt,"--output-format","json","--permission-mode","acceptEdits",
             "--allowedTools",CLAUDE_ALLOWED_TOOLS,"--model",CLAUDE_MODEL]
    started=time.monotonic()
    try:
        proc=subprocess.run(command,cwd=str(task_workspace),capture_output=True,text=True,
                           timeout=CLAUDE_TIMEOUT_SECONDS,shell=False)
    except subprocess.TimeoutExpired:
        raise ValueError(f"claude CLI did not finish within {CLAUDE_TIMEOUT_SECONDS:g}s - killed")
    duration=time.monotonic()-started
    if proc.returncode != 0:
        raise ValueError(f"claude CLI exited with code {proc.returncode}: {(proc.stderr or '').strip()[:500]}")
    try:
        payload=json.loads(proc.stdout)
    except json.JSONDecodeError:
        raise ValueError("claude CLI returned non-JSON output")
    if payload.get("is_error"):
        raise ValueError(f"claude reported an error: {str(payload.get('result'))[:500]}")
    manifest=[]; total_bytes=0
    for path in sorted(task_workspace.rglob("*")):
        if not path.is_file(): continue
        size=path.stat().st_size
        if size>MAX_CLAUDE_MANIFEST_FILE_BYTES:
            manifest.append({"path":str(path.relative_to(task_workspace)),"bytes":size,"sha256":None,
                             "note":"exceeds per-file hashing limit - not hashed"})
            continue
        data=path.read_bytes(); total_bytes+=len(data)
        manifest.append({"path":str(path.relative_to(task_workspace)),"bytes":len(data),"sha256":hashlib.sha256(data).hexdigest()})
    return {"worker_identity":node_id,"worker_hostname":socket.gethostname(),"worker_version":WORKER_VERSION,
            "platform":platform.platform(),"capability":"CLAUDE_CODE_EXECUTION","task_id":tid,"generated_at":now(),
            "execution_permission":CLAUDE_PERMISSION,"claude_model":CLAUDE_MODEL,"allowed_tools":CLAUDE_ALLOWED_TOOLS,
            "duration_seconds":round(duration,3),"claude_result_summary":str(payload.get("result"))[:4000],
            "research_findings":read_findings(task_workspace),
            "workspace_manifest":manifest,"workspace_file_count":len(manifest),"workspace_total_bytes":total_bytes}

MAX_FINDINGS_BYTES = 48 * 1024

def read_findings(task_workspace):
    """Milestone 31 (Distributed Research Jobs): return the text of the
    confined workspace's own findings.md (bounded), so the Supervisor gets the
    research itself, not only file hashes. None when there is no such file."""
    path=task_workspace/"findings.md"
    if not path.is_file(): return None
    data=path.read_bytes()[:MAX_FINDINGS_BYTES]
    return data.decode("utf-8","replace")

# -- Milestone 31b: LOCAL_MODEL_RESEARCH ------------------------------------
# A research piece answered by THIS computer's own local model (Ollama), using
# this computer's own RAM/CPU/GPU. No Claude sign-in, no tools, no shell, no
# internet: the only call made is to the local Ollama server on this machine's
# loopback address (anything else is refused). Output is bounded and returned
# as research_findings, exactly like a Claude Code piece.
LOCAL_MODEL = os.environ.get("EMISSARY_LOCAL_MODEL", "qwen3:1.7b")
OLLAMA_URL = os.environ.get("EMISSARY_OLLAMA_URL", "http://127.0.0.1:11434").rstrip("/")
LOCAL_MODEL_TIMEOUT_SECONDS = float(os.environ.get("EMISSARY_LOCAL_MODEL_TIMEOUT_SECONDS", "1200"))
LOCAL_MODEL_NUM_CTX = int(os.environ.get("EMISSARY_LOCAL_MODEL_NUM_CTX", "4096"))
_LOOPBACK_HOSTS = ("127.0.0.1", "localhost", "::1", "[::1]")
_THINK_BLOCK = re.compile(r"<think>.*?</think>", re.S)


def _local_model_enabled():
    return os.environ.get("EMISSARY_ENABLE_LOCAL_MODEL_RESEARCH", "1").strip() != "0"


def _ollama_url_is_local():
    from urllib.parse import urlparse
    parsed = urlparse(OLLAMA_URL)
    return parsed.scheme == "http" and (parsed.hostname or "") in _LOOPBACK_HOSTS


def _ram_bytes():
    """(total, available) physical RAM in bytes, or None where unknown."""
    try:
        info = {}
        with open("/proc/meminfo", encoding="ascii") as fh:
            for line in fh:
                key, _, rest = line.partition(":")
                info[key] = int(rest.split()[0]) * 1024
        return info.get("MemTotal"), info.get("MemAvailable")
    except (OSError, ValueError, IndexError):
        pass
    try:  # Windows
        import ctypes

        class _MemStatus(ctypes.Structure):
            _fields_ = [("dwLength", ctypes.c_ulong), ("dwMemoryLoad", ctypes.c_ulong),
                        ("ullTotalPhys", ctypes.c_ulonglong), ("ullAvailPhys", ctypes.c_ulonglong),
                        ("ullTotalPageFile", ctypes.c_ulonglong), ("ullAvailPageFile", ctypes.c_ulonglong),
                        ("ullTotalVirtual", ctypes.c_ulonglong), ("ullAvailVirtual", ctypes.c_ulonglong),
                        ("ullAvailExtendedVirtual", ctypes.c_ulonglong)]
        stat = _MemStatus()
        stat.dwLength = ctypes.sizeof(_MemStatus)
        if ctypes.windll.kernel32.GlobalMemoryStatusEx(ctypes.byref(stat)):
            return int(stat.ullTotalPhys), int(stat.ullAvailPhys)
    except Exception:  # noqa: BLE001 - RAM size is informational only
        pass
    return None, None


def _total_ram_bytes():
    return _ram_bytes()[0]


def _ollama_reachable():
    if not _ollama_url_is_local():
        return False
    try:
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        with opener.open(OLLAMA_URL + "/api/tags", timeout=3) as resp:
            return resp.status == 200
    except Exception:  # noqa: BLE001
        return False


def capability_snapshot():
    """What this Worker tells the Supervisor about its hardware, so the
    Supervisor can give bigger machines proportionally more research pieces.
    Measured, never estimated: unknown values are left out."""
    total, available = _ram_bytes()
    snap = {"cpu_cores": os.cpu_count(), "operating_system": platform.platform(),
            "architecture": platform.machine() or None, "total_ram_bytes": total, "available_ram_bytes": available,
            "inference_runtimes": ["ollama"] if (_local_model_enabled() and _ollama_reachable()) else []}
    return {k: v for k, v in snap.items() if v is not None}


def _ollama_generate_once(prompt, timeout=None):
    if not _ollama_url_is_local():
        raise ValueError(f"EMISSARY_OLLAMA_URL {OLLAMA_URL!r} is not this computer's loopback address - refused")
    if LOCAL_MODEL.lower().startswith("qwen3") and "/no_think" not in prompt:
        prompt = prompt + "\n/no_think"  # qwen3's soft switch; some Ollama versions ignore "think"
    body = json.dumps({"model": LOCAL_MODEL, "prompt": prompt, "stream": False, "think": False,
                       "options": {"num_ctx": LOCAL_MODEL_NUM_CTX}}).encode("utf-8")
    req = urllib.request.Request(OLLAMA_URL + "/api/generate", data=body, method="POST",
                                 headers={"Content-Type": "application/json"})
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))  # never route loopback through a proxy
    try:
        with opener.open(req, timeout=timeout or LOCAL_MODEL_TIMEOUT_SECONDS) as resp:
            data = json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", "replace")[:300]
        raise ValueError(f"local model {LOCAL_MODEL!r} refused the request (HTTP {exc.code}): {detail}. "
                         f"Is it pulled? Run: ollama pull {LOCAL_MODEL}") from exc
    except (urllib.error.URLError, socket.timeout) as exc:
        raise ValueError(f"cannot reach Ollama at {OLLAMA_URL} ({exc}). Is Ollama installed and running?") from exc
    text = str(data.get("response") or "")
    if "</think>" in text:  # 1.5.1: thinking with no opening tag (template opens it in the prompt)
        text = text.rsplit("</think>", 1)[1]
    text = _THINK_BLOCK.sub("", text).strip()
    if not text:
        raise ValueError(f"local model {LOCAL_MODEL!r} returned an empty answer")
    return text, data



def _ollama_has_model():
    try:
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        with opener.open(OLLAMA_URL + "/api/tags", timeout=5) as resp:
            names = [m.get("name", "") for m in json.loads(resp.read().decode("utf-8")).get("models", [])]
        want = LOCAL_MODEL if ":" in LOCAL_MODEL else LOCAL_MODEL + ":latest"
        return want in names or LOCAL_MODEL in names
    except Exception:  # noqa: BLE001
        return None  # unknown (Ollama not answering)


def _ollama_pull():
    """Self-heal: download this Worker's model into whichever Ollama is running, so a fresh install
    (or an Ollama that keeps its models in another folder) goes straight to work."""
    print(f"[model] {LOCAL_MODEL!r} is missing from Ollama - downloading it now (one time)...", flush=True)
    body = json.dumps({"name": LOCAL_MODEL, "model": LOCAL_MODEL, "stream": False}).encode("utf-8")
    req = urllib.request.Request(OLLAMA_URL + "/api/pull", data=body, method="POST",
                                 headers={"Content-Type": "application/json"})
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    with opener.open(req, timeout=3600) as resp:
        resp.read()
    print(f"[model] {LOCAL_MODEL!r} downloaded.", flush=True)


def ensure_local_model():
    """Called at start-up: if Ollama answers but lacks the model, pull it before taking work."""
    try:
        if _local_model_enabled() and _ollama_url_is_local() and _ollama_has_model() is False:
            _ollama_pull()
    except Exception as exc:  # noqa: BLE001 - never stop the Worker over this
        print(f"[model] could not download {LOCAL_MODEL!r} yet: {exc}", flush=True)


def _ollama_generate(prompt, timeout=None):
    try:
        return _ollama_generate_once(prompt, timeout)
    except ValueError as exc:
        if "not found" not in str(exc) or "HTTP 404" not in str(exc):
            raise
        _ollama_pull()  # model missing: fetch it once, then retry
        return _ollama_generate_once(prompt, timeout)

def local_model_research(node_id, task):
    """LOCAL_MODEL_RESEARCH handler. Idempotent per task_id (a cached result is
    re-submitted byte-for-byte after a crash, like the other handlers)."""
    tid = task.get("task_id")
    if not isinstance(tid, str) or not SAFE_TASK_ID.fullmatch(tid):
        raise ValueError("unsafe or missing task_id")
    prompt = (task.get("input_provenance") or {}).get("summary")
    if not isinstance(prompt, str) or not prompt.strip():
        raise ValueError("research piece has no prompt")
    ARTIFACT_DIR.mkdir(parents=True, exist_ok=True)
    result_path = ARTIFACT_DIR / (tid + ".result.json")
    if result_path.exists():
        return json.loads(result_path.read_text(encoding="utf-8"))
    started = time.monotonic()
    # Milestone 31e: the Supervisor sends a time budget per piece (heavy work gets
    # longer); never below this device's own setting, never above 2 hours.
    try:
        budget = float((task.get("input_provenance") or {}).get("time_budget_seconds") or 0)
    except (TypeError, ValueError):
        budget = 0.0
    timeout = min(max(LOCAL_MODEL_TIMEOUT_SECONDS, budget), 7200.0)
    text, raw = _ollama_generate(prompt[:20000], timeout=timeout)
    findings = text.encode("utf-8")[:MAX_FINDINGS_BYTES].decode("utf-8", "ignore")
    (ARTIFACT_DIR / (tid + ".findings.md")).write_text(findings, encoding="utf-8")
    result = {
        "worker_identity": node_id, "worker_version": WORKER_VERSION, "worker_hostname": socket.gethostname(),
        "platform": platform.platform(), "capability": "LOCAL_MODEL_RESEARCH", "task_id": tid,
        "execution_permission": "none", "shell_execution": False, "internet_access": False,
        "local_model": LOCAL_MODEL, "total_ram_bytes": _total_ram_bytes(), "cpu_cores": os.cpu_count(),
        "duration_seconds": round(time.monotonic() - started, 1),
        "model_eval_tokens": raw.get("eval_count"), "research_findings": findings,
    }
    result_path.write_text(json.dumps(result, sort_keys=True), encoding="utf-8")
    return result


def validate(node_id, task):
    tid=task.get("task_id")
    if not isinstance(tid,str) or not SAFE_TASK_ID.fullmatch(tid): return "unsafe or missing task_id"
    if task.get("assigned_node_id") != node_id: return "task is not assigned to this worker"
    prov=task.get("input_provenance") or {}
    capability=prov.get("capability")
    if capability not in CAPABILITIES: return "capability has no implemented handler"
    required=REQUIRED_PERMISSION[capability]
    if prov.get("execution_permission") != required:
        return f"execution_permission {prov.get('execution_permission')!r} is not permitted for capability {capability!r} (requires {required!r})"
    if capability=="CLAUDE_CODE_EXECUTION" and not claude_execution_enabled():
        return "CLAUDE_CODE_EXECUTION is not enabled on this device (EMISSARY_ENABLE_CLAUDE_CODE_EXECUTION != '1')"
    if capability=="LOCAL_MODEL_RESEARCH" and not _local_model_enabled():
        return "LOCAL_MODEL_RESEARCH is turned off on this device (EMISSARY_ENABLE_LOCAL_MODEL_RESEARCH=0)"
    return None

def main():
    ensure_local_model()
    node_id, base_url, connect_ip, hostname, worker_token = load_config()
    client=Client(node_id,base_url,connect_ip,worker_token)
    log(f"EMISSARY Windows Worker {WORKER_VERSION}; node={node_id}; supervisor={hostname} (log: {LOG_PATH})")
    log("Bounded handlers: " + ", ".join(sorted(CAPABILITIES)))
    log("Claude Code execution (this device): " + ("ENABLED - bounded, still requires the MSI operator's own separate authorization_scope grant" if claude_execution_enabled() else "disabled (EMISSARY_ENABLE_CLAUDE_CODE_EXECUTION != '1')"))
    log(f"Local-model research (this device): " + (f"on - model {LOCAL_MODEL} via {OLLAMA_URL}" if _local_model_enabled() else "off"))
    log("Credential: " + ("present (sent on every call)" if worker_token else "NONE - relying on node_id alone (pre-Security-Hardening-V2 enrollment)"))
    last_hb=0.0
    consecutive_heartbeat_failures=0
    last_caps=None
    while True:
        if last_caps is None or time.monotonic()-last_caps >= 3600:
            try:
                r=client.report_capabilities(capability_snapshot())
                log("[capabilities] reported" if r.get("success") else f"[capabilities] not accepted: {r.get('error')}")
            except Exception as e:  # noqa: BLE001 - informational only
                log(f"[capabilities] could not report: {e!r}")
            last_caps=time.monotonic()
        effective_hb_interval = min(HEARTBEAT_SECONDS * (2 ** consecutive_heartbeat_failures), MAX_HEARTBEAT_BACKOFF_SECONDS) \
            if consecutive_heartbeat_failures else HEARTBEAT_SECONDS
        now_m=time.monotonic()
        if now_m-last_hb >= effective_hb_interval:
            try:
                hb=client.heartbeat()
            except Exception as e:  # noqa: BLE001 - a single bad response must never kill the worker loop
                hb={"success":False,"error":f"unexpected_error: {e!r}"}
            if hb.get("success"):
                log("[heartbeat] ok")
                consecutive_heartbeat_failures=0
            elif hb.get("code") == "credential_required":
                log(f"[heartbeat-rejected] credential invalid or missing - {hb.get('error')}. Re-run windows_worker_setup.ps1 to re-enroll.")
                consecutive_heartbeat_failures+=1
            else:
                log(f"[heartbeat-failed] {hb.get('error','not confirmed')} - will retry, no success claimed")
                consecutive_heartbeat_failures+=1
            last_hb=now_m
        found=False
        try:
            for phase in ("assigned","running"):
                for task in client.tasks(phase):
                    found=True
                    tid=task.get("task_id")
                    reason=validate(node_id,task)
                    if reason:
                        log(f"[reject] {tid}: {reason}")
                        if isinstance(tid,str) and SAFE_TASK_ID.fullmatch(tid): client.fail(tid,reason)
                        continue
                    prov=task.get("input_provenance") or {}
                    cap=prov.get("capability")
                    if phase=="assigned":
                        ack=client.start(tid)
                        if not ack.get("success"):
                            log(f"[start-failed] {tid}: {ack.get('error','not confirmed')}")
                            continue
                    stop_beat=threading.Event()
                    def _beat():
                        # Milestone 31d: heartbeat while a long task runs (shows online-and-busy)
                        while not stop_beat.wait(HEARTBEAT_SECONDS):
                            try: client.heartbeat()
                            except Exception: pass  # noqa: BLE001 - a missed beat is harmless
                    threading.Thread(target=_beat,name="busy-heartbeat",daemon=True).start()
                    try:
                        if cap=="STATUS_REPORT": result=status_report(node_id,task)
                        elif cap=="DOCUMENTATION": result=documentation(node_id,base_url,task)
                        elif cap=="LOCAL_MODEL_RESEARCH": result=local_model_research(node_id,task)
                        else: result=claude_code_execution(node_id,task)
                        done=client.complete(tid,result)
                        log(f"[complete] {tid}: {done.get('phase') if done.get('success') else done.get('error','not confirmed')}")
                    except (OSError,ValueError,KeyError,TypeError) as e:
                        client.fail(tid,f"bounded worker failed: {e}")
                        log(f"[failed] {tid}: {e}")
                    finally:
                        stop_beat.set()
        except Exception as e:  # noqa: BLE001 - one bad task/response must not end the whole worker process
            log(f"[error] unexpected failure while polling/handling tasks: {e!r} - continuing")
        if not found: time.sleep(POLL_SECONDS)

if __name__=="__main__":
    try: raise SystemExit(main())
    except KeyboardInterrupt: print("\nWorker stopped by operator."); raise SystemExit(0)

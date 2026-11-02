#!/usr/bin/env python3
"""Builds the benchmark servers, checks that each answers the spec, and loads
each one with wrk. Writes bench/results/results.json and results.md, and the
same table to $GITHUB_STEP_SUMMARY when it runs in GitHub Actions.

    python3 bench/run.py                       # every server whose toolchain is installed
    python3 bench/run.py --only honk,go,c      # some of them
    python3 bench/run.py --duration 5 --connections 8,64

Needs wrk on PATH. bench/README.md has the spec and the method.
"""
import argparse
import json
import os
import platform
import re
import shutil
import signal
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BENCH = os.path.join(ROOT, "bench")
BUILD = os.path.join(BENCH, "build")
URL = "http://127.0.0.1:8000"
EXE = ".exe" if os.name == "nt" else ""


def path(*parts):
    return os.path.join(BENCH, *parts)


# Each server: what it needs installed, how to build it, how to run it, and
# the command that reports its toolchain's version.
SERVERS = [
    {"name": "honk", "label": "Honk (Goose)", "needs": ["goose"],
     "build": [["goose", "build", "-o", path("build", "honk" + EXE), path("servers", "honk", "server.goose")]],
     "run": [path("build", "honk" + EXE)], "version": ["goose", "version"]},
    {"name": "c", "label": "C (hand-written)", "needs": ["cc"],
     "build": [["cc", "-O2", "-pthread", path("servers", "c", "server.c"), "-o", path("build", "c" + EXE)]],
     "run": [path("build", "c" + EXE)], "version": ["cc", "--version"]},
    {"name": "cpp", "label": "C++ (hand-written)", "needs": ["c++"],
     "build": [["c++", "-std=c++20", "-O2", "-pthread", path("servers", "cpp", "server.cpp"),
                "-o", path("build", "cpp" + EXE)]],
     "run": [path("build", "cpp" + EXE)], "version": ["c++", "--version"]},
    {"name": "go", "label": "Go (net/http)", "needs": ["go"],
     "build": [["go", "build", "-C", path("servers", "go"), "-o", path("build", "go" + EXE), "."]],
     "run": [path("build", "go" + EXE)], "version": ["go", "version"]},
    {"name": "java", "label": "Java (JDK HttpServer)", "needs": ["javac", "java"],
     "build": [["javac", "-d", path("build", "java"), path("servers", "java", "Server.java")]],
     "run": ["java", "-cp", path("build", "java"), "Server"], "version": ["java", "-version"]},
    {"name": "csharp", "label": "C# (ASP.NET Core)", "needs": ["dotnet"],
     "build": [["dotnet", "publish", path("servers", "csharp"), "-c", "Release", "-o", path("build", "csharp"),
                "--nologo", "-v", "quiet"]],
     "run": [path("build", "csharp", "server" + EXE)], "version": ["dotnet", "--version"]},
    {"name": "node", "label": "JavaScript (Node http)", "needs": ["node"],
     "build": [], "run": ["node", path("servers", "node", "server.js")], "version": ["node", "--version"]},
    {"name": "python", "label": "Python (http.server)", "needs": ["python3"],
     "build": [], "run": [sys.executable, path("servers", "python", "server.py")],
     "version": [sys.executable, "--version"]},
]

WORKLOADS = [
    {"name": "hello", "title": "GET /hello", "path": "/hello", "script": None},
    {"name": "path", "title": "GET /items/42?q=geese", "path": "/items/42?q=geese", "script": None},
    {"name": "post", "title": "POST /items (JSON body)", "path": "/items", "script": path("workloads", "post.lua")},
]

# What every server must answer before it is measured: (method, path, body, status, JSON).
CHECKS = [
    ("GET", "/hello", None, 200, {"message": "Honk!"}),
    ("GET", "/items/5?q=geese", None, 200, {"item_id": 5, "q": "geese"}),
    ("GET", "/items/x", None, 422, None),
    ("POST", "/items", {"name": "Egg", "price": 2.5}, 201, {"name": "Egg", "price": 2.5, "price_with_tax": 3.0}),
    ("POST", "/items", {"name": "Egg"}, 422, None),
]


def call(method, target, body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(URL + target, data=data, method=method,
                                 headers={"content-type": "application/json"} if data else {})
    try:
        with urllib.request.urlopen(req, timeout=5) as r:
            return r.status, r.read()
    except urllib.error.HTTPError as e:
        return e.code, e.read()


def same(a, b):
    if isinstance(a, (int, float)) and isinstance(b, (int, float)) and not isinstance(a, bool):
        return abs(a - b) < 1e-9
    if isinstance(a, dict) and isinstance(b, dict):
        return a.keys() == b.keys() and all(same(a[k], b[k]) for k in a)
    return a == b


def call_retrying(method, target, body=None, tries=3):
    """A check request, tried again if the connection drops: a server that has
    only just started can close one before all of its workers are up."""
    for attempt in range(tries):
        try:
            return call(method, target, body)
        except OSError:
            if attempt == tries - 1:
                raise
            time.sleep(0.3)


def check(server):
    for method, target, body, status, want in CHECKS:
        try:
            got_status, got = call_retrying(method, target, body)
        except OSError as e:
            return f"{method} {target}: {e}"
        if got_status != status:
            return f"{method} {target}: status {got_status}, want {status}"
        if want is not None and not same(json.loads(got), want):
            return f"{method} {target}: {got.decode()[:120]}, want {json.dumps(want)}"
    return None


def wait_ready(proc, seconds=60):
    end = time.time() + seconds
    while time.time() < end:
        if proc.poll() is not None:
            return False
        try:
            if call("GET", "/hello")[0] == 200:
                return True
        except OSError:
            time.sleep(0.2)
    return False


def port_free():
    import socket
    with socket.socket() as s:
        return s.connect_ex(("127.0.0.1", 8000)) != 0


class Memory:
    """Samples the resident memory of a process group, every worker included."""

    def __init__(self, pgid):
        self.pgid, self.peak, self.running = pgid, 0, True
        self.thread = threading.Thread(target=self.sample, daemon=True)
        self.thread.start()

    def sample(self):
        while self.running:
            try:
                out = subprocess.run(["ps", "-A", "-o", "pgid=,rss="], capture_output=True, text=True).stdout
                total = sum(int(r) for g, r in (line.split() for line in out.splitlines() if line.strip())
                            if int(g) == self.pgid)
                self.peak = max(self.peak, total)
            except (OSError, ValueError):
                pass
            time.sleep(0.25)

    def stop(self):
        self.running = False
        self.thread.join()
        return self.peak / 1024.0   # MiB


def wrk(workload, connections, threads, duration):
    cmd = ["wrk", "-t", str(min(threads, connections)), "-c", str(connections), "-d", f"{duration}s",
           "--latency", "--timeout", "5s"]
    if workload["script"]:
        cmd += ["-s", workload["script"]]
    out = subprocess.run(cmd + [URL + workload["path"]], capture_output=True, text=True).stdout
    def num(pattern, default=0.0):
        m = re.search(pattern, out)
        return float(m.group(1)) if m else default
    def latency(pct):
        m = re.search(rf"^\s+{pct}%\s+([\d.]+)(us|ms|s)\b", out, re.M)
        if not m:
            return None
        return float(m.group(1)) * {"us": 0.001, "ms": 1.0, "s": 1000.0}[m.group(2)]
    errors = sum(int(x) for x in re.findall(r"(?:connect|read|write|timeout) (\d+)", out))
    errors += int(num(r"Non-2xx or 3xx responses: (\d+)"))
    return {"rps": num(r"Requests/sec:\s+([\d.]+)"), "p50_ms": latency(50), "p99_ms": latency(99),
            "errors": errors}


def version(cmd):
    """The toolchain's version line, or None when it does not run (macOS has a
    `java` stub that only says no runtime is installed)."""
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
        if r.returncode != 0:
            return None
        return (r.stdout or r.stderr).strip().splitlines()[0]
    except (OSError, IndexError, subprocess.TimeoutExpired):
        return None


def stop(proc):
    try:
        os.killpg(proc.pid, signal.SIGKILL)
    except (ProcessLookupError, PermissionError):
        pass
    proc.wait()
    for _ in range(50):
        if port_free():
            return
        time.sleep(0.1)


def bench(server, args, cores):
    result = {"name": server["name"], "label": server["label"], "runs": {}}
    missing = [t for t in server["needs"] if not shutil.which(t)]
    if missing:
        result["skipped"] = "not installed: " + ", ".join(missing)
        return result
    result["version"] = version(server["version"])
    if result["version"] is None:
        result["skipped"] = "not installed: " + " ".join(server["version"][:1]) + " does not run"
        return result
    for step in server["build"]:
        r = subprocess.run(step, capture_output=True, text=True, cwd=ROOT)
        if r.returncode != 0:
            result["skipped"] = "build failed: " + (r.stderr or r.stdout).strip()[-400:]
            return result
    if not port_free():
        result["skipped"] = "port 8000 is in use"
        return result
    proc = subprocess.Popen(server["run"], cwd=ROOT, start_new_session=True,
                            stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    try:
        if not wait_ready(proc):
            result["skipped"] = "did not start: " + (proc.stderr.read().decode()[-400:] if proc.poll() is not None else "timeout")
            return result
        problem = check(server)
        if problem:
            result["skipped"] = "wrong answer: " + problem
            return result
        memory = Memory(os.getpgid(proc.pid))
        for workload in WORKLOADS:
            for connections in args.connections:
                wrk(workload, connections, args.threads, args.warmup)
                run = wrk(workload, connections, args.threads, args.duration)
                result["runs"][f"{workload['name']}@{connections}"] = run
                print(f"  {workload['title']:<26} c={connections:<4} {run['rps']:>10.0f} req/s  "
                      f"p99 {run['p99_ms'] or 0:.2f} ms  errors {run['errors']}", flush=True)
        result["peak_rss_mib"] = round(memory.stop(), 1)
    finally:
        stop(proc)
    return result


def table(results, args, env):
    lines = ["# Honk benchmarks", "",
             f"{env['cpu']}, {env['cores']} cores, {env['os']}. wrk with {args.threads} threads, "
             f"{args.duration}s per run after a {args.warmup}s warm-up, on the same machine as the server.", ""]
    for workload in WORKLOADS:
        for connections in args.connections:
            key = f"{workload['name']}@{connections}"
            rows = [r for r in results if key in r.get("runs", {})]
            if not rows:
                continue
            rows.sort(key=lambda r: -r["runs"][key]["rps"])
            lines += [f"## {workload['title']}, {connections} connections", "",
                      "| Server | Requests/s | p50 ms | p99 ms | Errors |", "|---|---:|---:|---:|---:|"]
            for r in rows:
                run = r["runs"][key]
                fmt = lambda v: f"{v:.2f}" if v is not None else "-"
                lines.append(f"| {r['label']} | {run['rps']:,.0f} | {fmt(run['p50_ms'])} | "
                             f"{fmt(run['p99_ms'])} | {run['errors']} |")
            lines.append("")
    lines += ["## Peak memory", "", "| Server | Peak RSS (MiB), all processes |", "|---|---:|"]
    for r in sorted((r for r in results if "peak_rss_mib" in r), key=lambda r: r["peak_rss_mib"]):
        lines.append(f"| {r['label']} | {r['peak_rss_mib']:.1f} |")
    lines += ["", "## Toolchains", "", "| Server | Version or reason skipped |", "|---|---|"]
    for r in results:
        lines.append(f"| {r['label']} | {r.get('skipped') or r.get('version', '')} |".replace("\n", " "))
    return "\n".join(lines) + "\n"


def cpu_name():
    try:
        if platform.system() == "Darwin":
            return subprocess.run(["sysctl", "-n", "machdep.cpu.brand_string"], capture_output=True, text=True).stdout.strip()
        with open("/proc/cpuinfo") as f:
            for line in f:
                if line.startswith("model name"):
                    return line.split(":", 1)[1].strip()
    except OSError:
        pass
    return platform.processor() or "unknown CPU"


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--only", help="comma-separated server names: " + ",".join(s["name"] for s in SERVERS))
    p.add_argument("--duration", type=int, default=10, help="seconds per measured run (default 10)")
    p.add_argument("--warmup", type=int, default=2, help="seconds of warm-up before each run (default 2)")
    p.add_argument("--connections", default=None,
                   help="comma-separated connection counts (default: the core count, and 256)")
    p.add_argument("--threads", type=int, default=None, help="wrk threads (default: half the cores, at most 8)")
    p.add_argument("--out", default=os.path.join(BENCH, "results"))
    args = p.parse_args()

    if not shutil.which("wrk"):
        sys.exit("wrk is not installed: brew install wrk, or apt-get install wrk")
    cores = os.cpu_count() or 1
    args.connections = [int(c) for c in args.connections.split(",")] if args.connections else [cores, 256]
    args.threads = args.threads or max(1, min(8, cores // 2))
    os.makedirs(BUILD, exist_ok=True)
    os.makedirs(args.out, exist_ok=True)

    chosen = [s for s in SERVERS if not args.only or s["name"] in args.only.split(",")]
    env = {"cpu": cpu_name(), "cores": cores, "os": f"{platform.system()} {platform.release()}",
           "wrk": version(["wrk", "--version"]) or "?"}
    results = []
    for server in chosen:
        print(f"{server['label']}", flush=True)
        try:
            r = bench(server, args, cores)
        except Exception as e:     # one server's failure must not end the run
            r = {"name": server["name"], "label": server["label"], "runs": {},
                 "skipped": f"did not start: {type(e).__name__}: {e}"}
        if "skipped" in r:
            print(f"  skipped: {r['skipped']}", flush=True)
        results.append(r)

    report = table(results, args, env)
    with open(os.path.join(args.out, "results.json"), "w") as f:
        json.dump({"environment": env, "settings": vars(args), "results": results}, f, indent=2)
    with open(os.path.join(args.out, "results.md"), "w") as f:
        f.write(report)
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as f:
            f.write(report)
    print(f"\nwrote {os.path.relpath(args.out, ROOT)}/results.md and results.json")
    if any(r.get("skipped", "").startswith(("wrong answer", "build failed", "did not start")) for r in results):
        sys.exit(1)


if __name__ == "__main__":
    main()

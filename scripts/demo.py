#!/usr/bin/env python3
"""Run rill against an isolated, ephemeral, real Redis instance. Never touches port 6379."""
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parent.parent
binary = shutil.which("redis-server")
app = ROOT / "build/rill.app/Contents/MacOS/rill"
if not binary or not app.exists():
    raise SystemExit("Requires redis-server and build/rill.app. Run ./scripts/build-app.sh first.")

with socket.socket() as reservation:
    reservation.bind(("127.0.0.1", 0))
    port = reservation.getsockname()[1]

with tempfile.TemporaryDirectory(prefix="rill-demo-") as directory:
    log = open(ROOT / "build/demo-redis.log", "wb")
    server = subprocess.Popen([binary, "--bind", "127.0.0.1", "--port", str(port), "--save", "", "--appendonly", "no", "--dir", directory], stdout=log, stderr=log)
    client = None
    application = None
    try:
        for attempt in range(100):
            if server.poll() is not None:
                raise RuntimeError("Demo Redis failed to start; see build/demo-redis.log")
            try:
                client = socket.create_connection(("127.0.0.1", port), timeout=2)
                break
            except OSError:
                time.sleep(0.03)
        if client is None:
            raise RuntimeError("Demo Redis timed out")
        def execute(*args):
            values = [arg if isinstance(arg, bytes) else str(arg).encode() for arg in args]
            payload = b"*%d\r\n" % len(values) + b"".join(b"$%d\r\n" % len(value) + value + b"\r\n" for value in values)
            client.sendall(payload)
            response = client.recv(65536)
            if response.startswith(b"-"):
                raise RuntimeError(response.decode())
        execute("SET", "app:settings", json.dumps({"name": "rill", "environment": "development", "theme": "system", "features": {"native_ui": True, "safe_edits": True, "scan_batch_size": 200}, "message": "让 Redis 工作，轻松一点。"}, ensure_ascii=False, indent=2))
        execute("SET", "app:version", "1.0.0")
        execute("SET", "cache:homepage", json.dumps({"title": "Hello, rill", "cached": True}, indent=2), "EX", 3600)
        execute("SET", "cache:binary", b"\x00\x01\x02\xffRedis\r\n\x10\x80")
        execute("SET", "cache:empty", "")
        execute("SET", "counter:pageviews", "128493")
        execute("HSET", "user:1001", "name", "林晓", "email", "lin@example.test", "role", "developer", "plan", "pro", "joined_at", "2026-10-01")
        execute("HSET", "user:1002", "name", "Alex", "email", "alex@example.test", "role", "designer")
        execute("HSET", "user:1003", "name", "Morgan", "email", "morgan@example.test", "role", "engineer")
        execute("RPUSH", "queue:notifications", "welcome_email", "weekly_digest", "deploy_success")
        execute("RPUSH", "queue:jobs", *[f"task:{i:04d}" for i in range(1, 451)])
        execute("SADD", "tags:popular", "redis", "swift", "macOS", "native", "developer-tools")
        execute("SADD", "user:online", "1001", "1002", "1003")
        execute("ZADD", "leaderboard:weekly", "9850", "Lin", "8240", "Alex", "7100", "Morgan", "6500", "Jamie")
        for event, user in [("signed_in", "1001"), ("created_project", "1002"), ("deployed", "1001")]:
            execute("XADD", "events:activity", "*", "event", event, "user_id", user)
        execute("SET", "session:demo", "active", "EX", 7200)
        client.close()
        print(f"Isolated demo Redis: 127.0.0.1:{port}; closes when this app exits.", flush=True)
        app_log = open(ROOT / "build/demo-app.log", "wb")
        application = subprocess.Popen([str(app)], env={**os.environ, "RILL_DEMO_PORT": str(port)}, stdout=app_log, stderr=app_log)
        application.wait()
    except KeyboardInterrupt:
        if application and application.poll() is None:
            application.terminate()
    finally:
        if client:
            client.close()
        server.terminate()
        try:
            server.wait(timeout=5)
        except subprocess.TimeoutExpired:
            server.kill()
            server.wait()
        log.close()

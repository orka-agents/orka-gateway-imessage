#!/usr/bin/env python3
"""Run an Orka checkout's gateway conformance tool against a local adapter.

The adapter talks to scripts/fake-imsg, so no real message is sent.
"""

import argparse
import json
import os
from pathlib import Path
import secrets
import socket
import subprocess
import tempfile
import time
import urllib.error
import urllib.request

CONFORMANCE_CHAT = "iMessage;-;+15555550100"


def stop(process):
    if process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=5)


def wait_ready(process, endpoint):
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise RuntimeError("adapter exited before readiness")
        try:
            with opener.open(endpoint + "/readyz", timeout=0.5) as response:
                if response.status == 200:
                    return
        except (urllib.error.URLError, TimeoutError, ConnectionError):
            pass
        time.sleep(0.05)
    raise RuntimeError("adapter readiness timed out")


def check(root, repo, adapter_binary, conformance_binary):
    with socket.socket() as reserve:
        reserve.bind(("127.0.0.1", 0))
        port = reserve.getsockname()[1]
    endpoint = f"http://127.0.0.1:{port}"
    outbound = secrets.token_hex(32)
    sends = root / "sends.log"
    sends.touch()
    # Avoid inheriting credentials or *_FILE settings from the caller.
    base_env = {key: os.environ[key] for key in ("PATH", "HOME", "TMPDIR", "LANG", "LC_ALL") if key in os.environ}
    adapter_env = dict(
        base_env, LISTEN_ADDRESS=f"127.0.0.1:{port}", DATABASE_PATH=str(root / "adapter.db"),
        IMSG_PATH=str(repo / "scripts/fake-imsg"), FAKE_IMSG_SENDS=str(sends),
        IMESSAGE_ACCOUNT_ID="compat-account", IMESSAGE_ALLOWED_SENDERS="+15555550100",
        IMESSAGE_CONFORMANCE_CHAT_GUID=CONFORMANCE_CHAT,
        ORKA_GATEWAY_INGRESS_URL="http://127.0.0.1:9/api/v1/gateways/compat/imessage/events",
        ORKA_GATEWAY_INBOUND_TOKEN=secrets.token_hex(32), ORKA_GATEWAY_OUTBOUND_TOKEN=outbound,
        REQUEST_TIMEOUT="5s", SHUTDOWN_TIMEOUT="5s",
    )
    cli_env = dict(base_env, COMPAT_CONFORMANCE_TOKEN=outbound)
    for phase in ("fresh database", "after adapter restart"):
        with (root / "adapter.log").open("ab") as log:
            process = subprocess.Popen([str(adapter_binary)], env=adapter_env, stdout=log, stderr=log)
            try:
                wait_ready(process, endpoint)
                run = subprocess.run(
                    [str(conformance_binary), "--endpoint", endpoint,
                     "--token-env", "COMPAT_CONFORMANCE_TOKEN", "--timeout", "10s"],
                    env=cli_env, capture_output=True, text=True, timeout=60,
                )
                result = json.loads(run.stdout)
                if run.returncode != 0 or not result.get("Passed"):
                    raise RuntimeError(f"Orka conformance failed: {result.get('Message', 'no detail')}")
                print(f"Passed Orka conformance: {phase}", flush=True)
            finally:
                stop(process)
    recorded = [json.loads(line) for line in sends.read_text().splitlines()]
    # Two interim messages and one final; the restart run replays all three.
    if len(recorded) != 3 or any(entry["chat_guid"] != CONFORMANCE_CHAT for entry in recorded):
        raise RuntimeError(f"expected three sends to the conformance chat across replays and restart; got {recorded}")
    print("Passed durable replay: exactly three sends to the fake imsg conformance chat", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--orka-dir", required=True, help="local Orka source checkout")
    args = parser.parse_args()
    orka_dir = Path(args.orka_dir).expanduser().resolve()
    if not (orka_dir / "cmd/orka-gateway-conformance/main.go").is_file():
        parser.error("--orka-dir does not contain Orka's gateway conformance command")
    repo = Path(__file__).resolve().parents[1]
    revision = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=orka_dir, text=True).strip()
    print(f"Checking against Orka {revision}", flush=True)
    with tempfile.TemporaryDirectory(prefix="orka-imessage-compat-") as temporary:
        root = Path(temporary)
        adapter_binary = root / "adapter"
        conformance_binary = root / "orka-conformance"
        subprocess.run(["go", "build", "-mod=readonly", "-o", str(adapter_binary), "./cmd/orka-gateway-imessage"],
                       cwd=repo, check=True)
        subprocess.run(["go", "build", "-mod=readonly", "-o", str(conformance_binary), "./cmd/orka-gateway-conformance"],
                       cwd=orka_dir, check=True)
        try:
            check(root, repo, adapter_binary, conformance_binary)
        except Exception:
            log = root / "adapter.log"
            if log.exists():
                print(log.read_text()[-4000:], flush=True)
            raise


if __name__ == "__main__":
    main()

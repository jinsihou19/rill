#!/usr/bin/env python3
"""Verify packaging protects a running app, including alternate path spellings."""
import os
from pathlib import Path
import subprocess
import tempfile
import time

script = Path(__file__).resolve().with_name("build-app.sh")
with tempfile.TemporaryDirectory(prefix="rill-build-guard-") as directory:
    root = Path(directory)
    app = root / "Running app.app"
    executable = app / "Contents/MacOS/rill"
    executable.parent.mkdir(parents=True)
    subprocess.run(["xcrun", "clang", "-x", "c", "-", "-o", str(executable)],
                   input="#include <unistd.h>\nint main(void) { sleep(30); return 0; }\n", text=True, check=True)
    alias = root / "alias.app"
    alias.symlink_to(app, target_is_directory=True)
    tools = root / "bin"
    tools.mkdir()
    swift = tools / "swift"
    swift.write_text("#!/bin/sh\nexit 77\n")
    swift.chmod(0o700)
    env = {**os.environ, "PATH": str(tools) + os.pathsep + os.environ["PATH"]}
    original = executable.read_bytes()
    process = subprocess.Popen([str(executable)])
    try:
        for _ in range(100):
            if subprocess.run(["/usr/sbin/lsof", "-t", str(executable)], capture_output=True).returncode == 0:
                break
            time.sleep(0.01)
        else:
            raise AssertionError("Fixture executable did not start")
        for target in (app, alias):
            result = subprocess.run(["/bin/zsh", str(script)], env={**env, "RILL_BUILD_APP_PATH": str(target)}, capture_output=True, text=True)
            assert result.returncode == 1, (target, process.poll(), result)
            assert "Cannot replace an app that is in use" in result.stderr, result.stderr
            assert executable.read_bytes() == original
            assert process.poll() is None
    finally:
        process.terminate()
        process.wait()
    for target in (app, root / "New app.app"):
        result = subprocess.run(["/bin/zsh", str(script)], env={**env, "RILL_BUILD_APP_PATH": str(target)}, capture_output=True, text=True)
        assert result.returncode == 77, result
print("PASS: running app and symlink are protected; stopped and new app paths reach the build.")

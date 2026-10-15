#!/usr/bin/env python3
"""Compile the actual app sources after a Dev build, then run synthetic offline checks."""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

repo = Path(__file__).resolve().parent.parent
derived = Path(sys.argv[1]).resolve()
products = derived / "Build/Products/Debug Dev"
build = derived / "RedactionHarness"
build.mkdir(exist_ok=True)
lock = Path("/private/tmp/screendrop-team/bench.lock")
if lock.exists():
    sys.exit("Another benchmark owns bench.lock; wait before running.")

sources = sorted(str(p) for p in (repo / "Screendrop").rglob("*.swift") if p.name != "AppEntry.swift")
sources.append(str(repo / "scripts/check-video-redaction.swift"))
source_list = build / "sources"
source_list.write_text("\n".join(sources))
binary = build / "check-video-redaction"
command = [
    "lockf", "/private/tmp/screendrop-team/build.lock", "xcrun", "swiftc", "-parse-as-library",
    "-module-name", "Screendrop", "-target", "arm64-apple-macos27.0", "-default-isolation", "MainActor",
    "-enable-upcoming-feature", "MemberImportVisibility",
    "-enable-upcoming-feature", "NonisolatedNonsendingByDefault", "-D", "DEBUG",
    "-I", str(products), str(products / "DockProgress.o"), "@" + str(source_list), "-o", str(binary),
]
with (build / "compile.log").open("w") as log:
    result = subprocess.run(command, cwd=repo, stdout=log, stderr=subprocess.STDOUT)
if result.returncode:
    sys.exit(f"Harness compile failed: {build / 'compile.log'}")

library = products / "Sukusho Dev.app/Contents/Resources/default.metallib"
if library.exists():
    shutil.copyfile(library, build / "default.metallib")
home = tempfile.mkdtemp(prefix="screendrop-redaction-", dir="/private/tmp")
print(f"Synthetic artifacts: {home}", flush=True)
with lock.open("x") as file:
    file.write(f"F2 offline harness {os.getpid()}\n")
try:
    subprocess.run([str(binary)], cwd=repo, env=dict(os.environ, CFFIXED_USER_HOME=home, F2_FIXTURE_HOME=home), check=True)
finally:
    lock.unlink()

#!/usr/bin/env python3
"""Build after the Dev app; pass its DerivedData folder. Never launches the app."""
import os
from pathlib import Path
import platform
import subprocess
import sys
import tempfile
import uuid

repo = Path(__file__).resolve().parent.parent
derived = Path(sys.argv[1]).resolve()
products = derived / "Build/Products/Debug Dev"
sparkle = derived / "SourcePackages/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64"
build = derived / "IdleSaveHarness"
build.mkdir(exist_ok=True)
lock = Path("/private/tmp/screendrop-team/bench.lock")
lock.parent.mkdir(parents=True, exist_ok=True)
if lock.exists():
    sys.exit("Another benchmark owns bench.lock; stop and coordinate before running.")

sources = sorted(str(p) for p in (repo / "Screendrop").rglob("*.swift") if p.name != "AppEntry.swift")
sources.append(str(repo / "scripts/check-editor-idle-save.swift"))
source_list = build / "sources"
source_list.write_text("\n".join(sources))
binary = build / "check-editor-idle-save"
command = [
    "xcrun", "swiftc", "-parse-as-library", "-module-name", "Screendrop",
    "-target", f"{platform.machine()}-apple-macos27.0", "-default-isolation", "MainActor",
    "-enable-upcoming-feature", "MemberImportVisibility",
    "-enable-upcoming-feature", "NonisolatedNonsendingByDefault", "-D", "DEBUG",
    "-I", str(products), "-F", str(sparkle), "-framework", "Sparkle",
    "-Xlinker", "-rpath", "-Xlinker", str(sparkle),
    str(products / "DockProgress.o"), "@" + str(source_list), "-o", str(binary),
]
with (build / "compile.log").open("w") as log:
    result = subprocess.run(command, cwd=repo, stdout=log, stderr=subprocess.STDOUT)
if result.returncode:
    sys.exit(f"Harness compile failed: {build / 'compile.log'}")

owner = f"Sol idle-save harness {uuid.uuid4()}\n"
with lock.open("x") as file:
    file.write(owner)
try:
    with tempfile.TemporaryDirectory(prefix="screendrop-idle-save-", dir="/private/tmp") as root:
        environment = dict(os.environ, CFFIXED_USER_HOME=root)
        subprocess.run([str(binary)], env=environment, check=True)
finally:
    if lock.read_text() == owner:
        lock.unlink()

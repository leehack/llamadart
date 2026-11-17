#!/usr/bin/env python3
"""Xcode phase: stage only explicitly enabled, signed Release suite resources."""

import base64
import os
from pathlib import Path
import shutil

import mobile_default_assets as mobile


def stage(env):
    destination = Path(env["TARGET_BUILD_DIR"]) / env["UNLOCALIZED_RESOURCES_FOLDER_PATH"] / mobile.RESOURCE
    enabled = env.get("STUDIO_MOBILE_DEFAULT_ACCEPTANCE") == "YES"
    source = env.get("STUDIO_MOBILE_DEFAULT_MODELS")
    target = env.get("FLUTTER_TARGET", "lib/main.dart")
    selected = target in (mobile.TARGET, str(Path(__file__).resolve().parents[1] / mobile.TARGET))
    defines = [base64.b64decode(value, validate=True).decode()
               for value in env.get("DART_DEFINES", "").split(",") if value]
    opted_in = "STUDIO_MOBILE_DEFAULT_ACCEPTANCE=true" in defines
    if not enabled:
        if source or selected or opted_in:
            raise ValueError("Mobile default resources require the explicit Xcode opt-in")
        # Xcode can reuse a products directory after a qualification build.
        if destination.is_symlink():
            destination.unlink()
        elif destination.exists():
            shutil.rmtree(destination)
        return
    if (not selected or not opted_in or env.get("CONFIGURATION") != "Release"
            or not env.get("SDK_NAME", "").startswith("iphoneos")
            or env.get("CODE_SIGNING_ALLOWED") != "YES" or not source):
        raise ValueError("Mobile staging requires exact target, define, signed Release and iphoneos")
    root = Path(source)
    mobile.verify_stage(root)
    if destination.is_symlink():
        raise ValueError("Resource destination must not be a symlink")
    if destination.exists():
        shutil.rmtree(destination)
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copytree(root, destination)
    mobile.verify_stage(destination)


if __name__ == "__main__":
    stage(os.environ)

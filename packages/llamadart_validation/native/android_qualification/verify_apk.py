"""Static paired-runtime admission only; never implies Android launch or inference."""
import argparse
import hashlib
import json
from pathlib import Path
import struct
import zipfile

def verify(apk, binding, plan):
    with zipfile.ZipFile(apk) as archive:
        names = archive.namelist()
        if len(names) != len(set(names)):
            raise ValueError("Duplicate APK entries")
        prefix = "assets/llamadart_android_qualification/"
        if json.loads(archive.read(prefix + "binding.json")) != binding:
            raise ValueError("APK build binding mismatch")
        if archive.read(prefix + "plan.json") != plan:
            raise ValueError("APK request contract mismatch")
        if hashlib.sha256(plan).hexdigest() != binding["plan_sha256"]:
            raise ValueError("APK request hash mismatch")
        expected = set(binding["libraries"])
        observed = {Path(name).name for name in names if name.startswith("lib/arm64-v8a/")
                    and Path(name).name.startswith(("libllama", "libggml", "libmtmd"))}
        if observed != expected:
            raise ValueError("APK paired-runtime inventory mismatch")
        for name, lock in binding["libraries"].items():
            if Path(name).name != name:
                raise ValueError("Unsafe APK runtime name")
            entry = "lib/arm64-v8a/" + name
            info = archive.getinfo(entry)
            if info.file_size != lock["bytes"] or info.file_size > 256 * 1024 * 1024:
                raise ValueError("APK library size mismatch")
            data = archive.read(entry)
            if hashlib.sha256(data).hexdigest() != lock["sha256"]:
                raise ValueError("APK library bytes differ from admitted archive/probe")
            if data[:6] != b"\x7fELF\x02\x01" or struct.unpack_from("<H", data, 18)[0] != 183:
                raise ValueError("Expected arm64 ELF runtime")
            phoff = struct.unpack_from("<Q", data, 32)[0]
            size, count = struct.unpack_from("<HH", data, 54)
            if size != 56 or count < 1 or phoff + size * count > len(data):
                raise ValueError("Invalid ELF program headers")
            for index in range(count):
                offset = phoff + index * size
                kind = struct.unpack_from("<I", data, offset)[0]
                alignment = struct.unpack_from("<Q", data, offset + 48)[0]
                if kind == 1 and alignment < 16384:
                    raise ValueError("Runtime lacks 16 KiB LOAD alignment")
            if name == "libllamadart_android_qualification.so":
                if struct.unpack_from("<Q", data, 24)[0] == 0:
                    raise ValueError("Diagnostic probe lacks an executable entry point")
    return {"qualified": False, "android_launch_observed": False,
            "apk_sha256": hashlib.sha256(apk.read_bytes()).hexdigest()}

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("apk", "binding", "plan"):
        parser.add_argument("--" + name, type=Path, required=True)
    args = parser.parse_args()
    print(json.dumps(verify(args.apk, json.loads(args.binding.read_text()), args.plan.read_bytes())))

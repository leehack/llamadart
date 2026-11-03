"""Model-free hostile artifact controls for diagnostic preparation/admission."""
import hashlib
import io
import json
from pathlib import Path
import struct
import tarfile
import tempfile
import unittest
import zipfile

import build_probe
import verify_apk

class PreparationTest(unittest.TestCase):
    def test_archive_traversal_and_links_fail(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            for index, name in enumerate(("../escape", "/absolute", "link")):
                archive = root / (str(index) + ".tar")
                with tarfile.open(archive, "w") as target:
                    entry = tarfile.TarInfo(name)
                    if name == "link":
                        entry.type = tarfile.SYMTYPE
                        entry.linkname = "../escape"
                    else:
                        entry.size = 1
                    target.addfile(entry, io.BytesIO(b"x"))
                with self.assertRaises(ValueError):
                    build_probe.unpack(archive, root / str(index), build_probe.sha(archive))
            self.assertFalse((root / "escape").exists())

    def test_apk_hash_inventory_and_elf_controls(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            elf = bytearray(120)
            elf[:6] = b"\x7fELF\x02\x01"
            struct.pack_into("<H", elf, 18, 183)
            struct.pack_into("<Q", elf, 24, 1)
            struct.pack_into("<Q", elf, 32, 64)
            struct.pack_into("<HH", elf, 54, 56, 1)
            struct.pack_into("<I", elf, 64, 1)
            struct.pack_into("<Q", elf, 112, 16384)
            plan = b'{"schema":1}'
            names = ["libllama.so", "libggml-vulkan.so", "libllamadart_android_qualification.so"]
            binding = {"plan_sha256": hashlib.sha256(plan).hexdigest(), "libraries": {
                name: {"bytes": len(elf), "sha256": hashlib.sha256(elf).hexdigest()} for name in names}}
            def apk(mode):
                path = root / (mode + ".apk")
                with zipfile.ZipFile(path, "w") as target:
                    target.writestr("assets/llamadart_android_qualification/binding.json", json.dumps(binding))
                    target.writestr("assets/llamadart_android_qualification/plan.json", plan)
                    for name in names:
                        if mode == "missing" and name == names[0]:
                            continue
                        data = bytes(elf)
                        if mode == "changed" and name == names[0]:
                            data = data[:-1] + b"x"
                        target.writestr("lib/arm64-v8a/" + name, data)
                    if mode == "extra":
                        target.writestr("lib/arm64-v8a/libggml-opencl.so", elf)
                return path
            result = verify_apk.verify(apk("good"), binding, plan)
            self.assertFalse(result["qualified"])
            self.assertFalse(result["android_launch_observed"])
            for mode in ("missing", "changed", "extra"):
                with self.assertRaises(ValueError):
                    verify_apk.verify(apk(mode), binding, plan)

if __name__ == "__main__":
    unittest.main()

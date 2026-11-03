"""Compile the real child on a recording C ABI; no SD runtime/model is used."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

import run as operator

HEADER = r'''
#pragma once
#include <cstdint>
struct sd_ctx_t {};
struct sd_ctx_params_t {
 const char *model_path,*taesd_path,*backend,*flash_attn_mode,*conv_direct_mode;
 int n_threads,conditioning_cache_size;
 bool eager_load,batched_cfg,flash_attn,diffusion_flash_attn,diffusion_conv_direct,vae_conv_direct,auto_fit;
};
enum { EULER_SAMPLE_METHOD=0, DISCRETE_SCHEDULER=0 };
struct sd_img_gen_params_t {
 const char* prompt; int width,height; int64_t seed;
 struct { int sample_steps,sample_method,scheduler; struct { float txt_cfg; } guidance; } sample_params;
};
struct sd_image_t { uint32_t width,height,channel; uint8_t* data; };
extern "C" {
void sd_ctx_params_init(sd_ctx_params_t*);
void sd_img_gen_params_init(sd_img_gen_params_t*);
sd_ctx_t* sd_dart_new_sd_ctx(const sd_ctx_params_t*);
const char* sd_get_model_version_name(sd_ctx_t*);
bool sd_dart_generate_image(sd_ctx_t*,const sd_img_gen_params_t*,sd_image_t**,int*);
void free_sd_images(sd_image_t*,int);
void sd_dart_exit_free(sd_ctx_t*);
}
'''
STUB = r'''
#include "stable-diffusion.h"
#include <cstdlib>
#include <cstring>
#include <cstdio>
extern "C" {
void sd_ctx_params_init(sd_ctx_params_t*p){std::memset(p,0,sizeof(*p));p->conditioning_cache_size=4;}
void sd_img_gen_params_init(sd_img_gen_params_t*p){std::memset(p,0,sizeof(*p));}
sd_ctx_t* sd_dart_new_sd_ctx(const sd_ctx_params_t*p){
 bool orig=p->taesd_path!=nullptr;
 if(std::strcmp(p->backend,"cpu")||p->n_threads!=4||!p->eager_load||p->batched_cfg)return nullptr;
 if(p->conditioning_cache_size!=(orig?4:0)||std::strcmp(p->flash_attn_mode,orig?"off,diffusion=on":"off")||std::strcmp(p->conv_direct_mode,"off"))return nullptr;
 if(orig&&(!p->diffusion_flash_attn||p->vae_conv_direct||p->diffusion_conv_direct||p->auto_fit||p->flash_attn))return nullptr;
 return std::getenv("FAIL_LOAD")?nullptr:new sd_ctx_t;
}
const char* sd_get_model_version_name(sd_ctx_t*){return "SD 2.x";}
bool sd_dart_generate_image(sd_ctx_t*,const sd_img_gen_params_t*p,sd_image_t**out,int*n){
 if(std::strcmp(p->prompt,"a red fox in a green forest, watercolor painting")||p->width!=128||p->height!=128||p->seed!=42||p->sample_params.sample_steps!=1||p->sample_params.guidance.txt_cfg!=1||p->sample_params.sample_method!=EULER_SAMPLE_METHOD||p->sample_params.scheduler!=DISCRETE_SCHEDULER)return false;
 if(std::getenv("FAIL_GENERATE"))return false;
 *n=1;*out=new sd_image_t[1];**out={128,128,3,new uint8_t[128*128*3]};
 for(int i=0;i<128*128*3;++i)(*out)->data[i]=std::getenv("TRIVIAL")?0:i%256;
 return true;
}
void free_sd_images(sd_image_t*p,int){delete[] p->data;delete[]p;}
void sd_dart_exit_free(sd_ctx_t*p){delete p;std::fputs("FIXTURE_CONTEXT_FREED\n",stderr);}
}
'''


@unittest.skipIf(sys.platform == "win32", "POSIX dladdr fixture")
class NativeChildTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        compiler = shutil.which("c++")
        if not compiler:
            if os.environ.get("CI"): raise AssertionError("C++ compiler required")
            raise unittest.SkipTest("C++ compiler unavailable")
        cls.temp = tempfile.TemporaryDirectory(prefix="sd24-native-model-free-")
        cls.addClassCleanup(cls.temp.cleanup)
        cls.root = Path(cls.temp.name)
        (cls.root / "stable-diffusion.h").write_text(HEADER)
        (cls.root / "sd_dart_wrapper.h").write_text('#include "stable-diffusion.h"\n')
        (cls.root / "stub.cpp").write_text(STUB)
        cls.source = operator.REPO / "example/basic_app/test/fixtures/image_container_native_reference.cpp"
        cls.compiler = compiler
        cls.binary = cls.build("child", cls.source)

    @classmethod
    def build(cls, name, source):
        binary = cls.root / name
        command = [cls.compiler, "-std=c++17", "-rdynamic", "-I" + str(cls.root), str(source), str(cls.root / "stub.cpp"), "-o", str(binary)]
        if sys.platform != "darwin": command.append("-ldl")
        result = subprocess.run(command, capture_output=True, text=True, timeout=120)
        if result.returncode: raise AssertionError(result.stderr[-8192:])
        return binary

    def invoke(self, name, original=True, env=None, binary=None):
        output = self.root / (name + ".ppm")
        argv = [str(binary or self.binary)] + (["--original-mode", "synthetic.pt", "synthetic-taesd.safetensors", str(output)] if original else ["synthetic.gguf", str(output)])
        result = subprocess.run(argv, capture_output=True, timeout=5, env={**os.environ, **(env or {})})
        return result, output

    def test_original_and_existing_modes_fill_distinct_real_call_parameters(self):
        for original in (False, True):
            result, output = self.invoke(str(original), original)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(len(output.read_bytes()), len(operator.PREFIX) + 49152)
            if original:
                rows = [json.loads(line[len(b"SD24_STAGE "):]) for line in result.stdout.splitlines() if line.startswith(b"SD24_STAGE ")]
                self.assertEqual([r["stage"] for r in rows], operator.STAGES)
                self.assertIn(b'"cache":4', result.stdout)

    def test_generation_failure_still_disposes_and_output_is_never_overwritten(self):
        result, output = self.invoke("failed", env={"FAIL_GENERATE": "1"})
        self.assertEqual(result.returncode, 4)
        self.assertFalse(output.exists())
        self.assertIn(b"FIXTURE_CONTEXT_FREED", result.stderr)
        result, output = self.invoke("existing")
        self.assertEqual(result.returncode, 0)
        before = output.read_bytes()
        result, _ = self.invoke("existing")
        self.assertEqual(result.returncode, 5)
        self.assertEqual(output.read_bytes(), before)

    def test_context_and_prompt_mutants_are_rejected_by_recording_abi(self):
        source = self.source.read_text()
        for i, (before, after) in enumerate([
                ('original_mode ? 4 : 0', '0'),
                ('context_params.diffusion_flash_attn = true;', 'context_params.diffusion_flash_attn = false;'),
                ('watercolor painting', 'oil painting')]):
            changed = self.root / ("mutant" + str(i) + ".cpp")
            self.assertIn(before, source)
            changed.write_text(source.replace(before, after))
            binary = self.build("mutant" + str(i), changed)
            result, _ = self.invoke("mutant" + str(i), binary=binary)
            self.assertNotEqual(result.returncode, 0)


if __name__ == "__main__": unittest.main()

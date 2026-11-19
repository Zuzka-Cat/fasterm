#!/usr/bin/env python3
"""Verify that an XftCharExists() clobber of caller-saved RDX cannot crash fastst.

Usage: python3 tests/regress_unicode_fallback.py ./fastst
Requires: cc, xvfb-run and Xft installed. Builds a test-only LD_PRELOAD shim.
"""
import os
import pathlib
import subprocess
import sys
import tempfile
import time

SHIM = r'''
#define _GNU_SOURCE
#include <dlfcn.h>
#include <unistd.h>

/* A legitimate ABI behavior: XftCharExists may modify RDX at will.
   Force the same bad value seen in the original GDB report. */
__attribute__((naked)) int XftCharExists(void *d, void *f, unsigned int cp) {
    __asm__ volatile("movl $0x20000000, %edx\n\t"
                     "xorl %eax, %eax\n\t"
                     "ret\n\t");
}

/* Signal when a Unicode draw actually runs; a live PID alone proves nothing. */
void XftDrawString32(void *d, void *color, void *font, int x, int y,
                     const unsigned int *s, int n) {
    static void (*next)(void*,void*,void*,int,int,const unsigned int*,int);
    if (!next) next = dlsym(RTLD_NEXT,"XftDrawString32");
    if (s && n > 0 && s[0] == 0x25BD)
        (void)write(STDERR_FILENO, "FASTST_UNICODE_RENDERED\n", 24);
    next(d,color,font,x,y,s,n);
}
'''

PROGRAM = '''import sys,time
sys.stdout.write('\\033[2J\\033[Hhtop  ▽ ⯿ ⛸ ␀ ⊧ ⹂  test\\r\\n')
sys.stdout.flush()
time.sleep(12)
'''


def child(binary: str, shim: str) -> int:
    env = dict(os.environ, LD_PRELOAD=shim)
    proc = subprocess.Popen([binary, "-e", sys.executable, "-c", PROGRAM],
                            env=env, stderr=subprocess.PIPE)
    try:
        # Wait for Unicode draw confirmation or a terminal crash.
        deadline = time.monotonic() + 10
        data = b""
        import select
        while time.monotonic() < deadline:
            ready, _, _ = select.select([proc.stderr], [], [], 0.2)
            if ready:
                block = os.read(proc.stderr.fileno(), 4096)
                if not block:
                    break
                data += block
                if b"FASTST_UNICODE_RENDERED" in data:
                    break
            if proc.poll() is not None:
                break
        if b"FASTST_UNICODE_RENDERED" not in data:
            print("FAIL: Unicode rendering was not observed; exit:", proc.poll(),
                  "stderr:", data.decode(errors="replace"), flush=True)
            return 1
        time.sleep(0.4)
        if proc.poll() is not None:
            print("FAIL: terminal crashed after Unicode draw; exit:", proc.returncode,
                  "stderr:", data.decode(errors="replace"), flush=True)
            return 1
        print("PASS: Unicode rendered with RDX deliberately clobbered; terminal alive")
        return 0
    finally:
        if proc.poll() is None:
            proc.terminate()
        try:
            proc.communicate(timeout=2)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.communicate()


def main() -> int:
    if len(sys.argv) == 4 and sys.argv[1] == "--child":
        return child(sys.argv[2], sys.argv[3])
    if len(sys.argv) != 2:
        print(__doc__)
        return 2
    binary = str(pathlib.Path(sys.argv[1]).resolve())
    with tempfile.TemporaryDirectory(prefix="fastst-fallback-") as tmp:
        src = pathlib.Path(tmp) / "shim.c"
        so = pathlib.Path(tmp) / "shim.so"
        src.write_text(SHIM)
        subprocess.run(["cc", "-shared", "-fPIC", "-O2", "-o", str(so),
                        str(src), "-ldl"], check=True)
        return subprocess.call(["xvfb-run", "-a", "-s", "-screen 0 1200x800x24",
                                sys.executable, __file__, "--child", binary, str(so)])


if __name__ == "__main__":
    raise SystemExit(main())

#!/usr/bin/env python3
"""Build the P3 Waypipe shared library from a pristine Waypipe 0.9.2 source tree."""

import argparse
from pathlib import Path
import shutil
import subprocess
import tempfile


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path, help="Unpacked Waypipe 0.9.2 source")
    parser.add_argument("native_sdk", type=Path, help="OHOS SDK native directory")
    parser.add_argument("output", type=Path, help="Destination libhish_waypipe.so")
    args = parser.parse_args()
    tools = args.native_sdk.resolve() / "llvm/bin"
    with tempfile.TemporaryDirectory(prefix="hish-waypipe-") as temp:
        work = Path(temp)
        source = shutil.copytree(args.source, work / "src", ignore=shutil.ignore_patterns(".git"))
        with (source / "src/meson.build").open("a") as meson:
            meson.write("""
shared_library(
    'hish_waypipe',
    ['waypipe.c', 'bench.c', 'client.c', 'server.c'],
    c_args: ['-Dmain=hish_waypipe_main'],
    link_with: lib_waypipe_src,
)
""")
        cross = work / "ohos.ini"
        cross.write_text(f"""[binaries]
c = '{tools}/aarch64-unknown-linux-ohos-clang'
ar = '{tools}/llvm-ar'
strip = '{tools}/llvm-strip'

[properties]
needs_exe_wrapper = true

[host_machine]
system = 'linux'
cpu_family = 'aarch64'
cpu = 'aarch64'
endian = 'little'
""")
        build = work / "build"
        disabled = ("with_video", "with_dmabuf", "with_lz4", "with_zstd",
                    "with_vaapi", "with_secctx", "man-pages")
        subprocess.run(["meson", "setup", str(build), str(source), "--cross-file", str(cross),
                        "-Dwith_systemtap=false", "-Dwerror=false",
                        *(f"-D{option}=disabled" for option in disabled)], check=True)
        subprocess.run(["meson", "compile", "-C", str(build), "hish_waypipe"], check=True)
        args.output.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(build / "src/libhish_waypipe.so", args.output)


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Build the P3 Waypipe probe from a pristine Waypipe 0.9.2 source tree."""

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
    parser.add_argument("--guest-output", type=Path, help="Also build a static Linux ARM64 executable")
    args = parser.parse_args()
    tools = args.native_sdk.resolve() / "llvm/bin"
    with tempfile.TemporaryDirectory(prefix="hish-waypipe-") as temp:
        work = Path(temp)
        source = shutil.copytree(args.source, work / "src", ignore=shutil.ignore_patterns(".git"))
        patches = Path(__file__).resolve().parent / "patches"
        patch = patches / "waypipe-0.9.2-virtio-serial.patch"
        subprocess.run(["patch", "-p1", "-i", str(patch)], cwd=source, check=True)
        patch = patches / "waypipe-0.9.2-ohos-shm.patch"
        subprocess.run(["patch", "-p1", "-i", str(patch)], cwd=source, check=True)
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
        options = ["-Dwith_systemtap=false", "-Dwerror=false",
                   *(f"-D{option}=disabled" for option in disabled)]
        subprocess.run(["meson", "setup", str(build), str(source), "--cross-file", str(cross),
                        *options], check=True)
        subprocess.run(["meson", "compile", "-C", str(build), "hish_waypipe"], check=True)
        args.output.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(build / "src/libhish_waypipe.so", args.output)
        if args.guest_output:
            guest_source = shutil.copytree(args.source, work / "guest-src", ignore=shutil.ignore_patterns(".git"))
            patch = patches / "waypipe-0.9.2-guest-virtio.patch"
            subprocess.run(["patch", "-p1", "-i", str(patch)], cwd=guest_source, check=True)
            cross = work / "linux.ini"
            cross.write_text("""[binaries]
c = 'aarch64-linux-gnu-gcc'
ar = 'aarch64-linux-gnu-ar'
strip = 'aarch64-linux-gnu-strip'

[built-in options]
c_link_args = ['-static']

[properties]
needs_exe_wrapper = true

[host_machine]
system = 'linux'
cpu_family = 'aarch64'
cpu = 'aarch64'
endian = 'little'
""")
            build = work / "guest"
            subprocess.run(["meson", "setup", str(build), str(guest_source),
                            "--cross-file", str(cross), *options], check=True)
            subprocess.run(["meson", "compile", "-C", str(build), "waypipe"], check=True)
            args.guest_output.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(build / "src/waypipe", args.guest_output)


if __name__ == "__main__":
    main()

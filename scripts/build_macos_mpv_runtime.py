#!/usr/bin/env python3
"""Build the pinned universal macOS runtime libraries used by PiliPlusX.

This deliberately builds only the runtime closure needed by mpv/libplacebo.
All expensive commands are logged separately under WORK_DIR/logs and can be
rerun in place. The final OUTPUT_DIR must be absent or empty.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import platform
import re
import shutil
import subprocess
import sys
import tarfile
import urllib.request
from pathlib import Path
from typing import Sequence


LIBPLACEBO_COMMIT = "1fd3c7bde7b943fe8985c893310b5269a09b46c5"
SOURCE_ARCHIVES = {
    "shaderc": ("https://github.com/google/shaderc/archive/refs/tags/v2026.4.tar.gz",
                "f06ce5bcca94e5df7f34e115743597d0ad2e13c5fe9213c67dc8c76031241947", "shaderc-2026.4"),
    "glslang": ("https://github.com/KhronosGroup/glslang/archive/e1b562a8bed273a02f30b59b66a5d499793cede5.tar.gz",
                "907174a24713c6202c146f164bf81783f1fbc79c8cb821a30f18f159eb980312", "glslang-e1b562a8bed273a02f30b59b66a5d499793cede5"),
    "spirv-tools": ("https://github.com/KhronosGroup/SPIRV-Tools/archive/ef96ed763b43b59b33b31b362f09a02b729fa1c9.tar.gz",
                    "82c62146083fd558735a3171cf97cfc47903ca7d368482e87f94bd44883c0f00", "SPIRV-Tools-ef96ed763b43b59b33b31b362f09a02b729fa1c9"),
    "spirv-headers": ("https://github.com/KhronosGroup/SPIRV-Headers/archive/04fd3caa1e8267e4d95c806cad901181728e1006.tar.gz",
                      "392f4801409aad9c4f1b77745f179952fd6264e4c8bd0fc1bc45dfa6807bf6d0", "SPIRV-Headers-04fd3caa1e8267e4d95c806cad901181728e1006"),
    "vulkan-headers": ("https://github.com/KhronosGroup/Vulkan-Headers/archive/vulkan-sdk-1.4.357.0.tar.gz",
                       "e87dce08116151f6b6d7de6b6faf41498e87e6cf848ff16fa3bd5402190ad4a3", "Vulkan-Headers-vulkan-sdk-1.4.357.0"),
    "vulkan-loader": ("https://github.com/KhronosGroup/Vulkan-Loader/archive/vulkan-sdk-1.4.357.0.tar.gz",
                      "54f2537df22313768da0317dda2abdaaab7711b4081c48c869a79db343d0ae70", "Vulkan-Loader-vulkan-sdk-1.4.357.0"),
    "lcms2": ("https://downloads.sourceforge.net/project/lcms/lcms/2.19.1/lcms2-2.19.1.tar.gz",
              "bfc54f7bab59fbc921012014a8032e4cba4abd46db47d46b76416a8c0b2815c8", "lcms2-2.19.1"),
}
VERSIONS = {
    "libplacebo": "7.349.0",
    "shaderc": "2026.4",
    "vulkan_loader": "1.4.357.0",
    "lcms2": "2.19.1",
}
MIN_FREE_BYTES = 1024**3
MIN_RESUME_FREE_BYTES = 512 * 1024**2
# The first source build used 535 MiB: 408 MiB of shared pinned sources,
# 127 MiB of arm64 dependencies. A verified resume does not extract sources
# again. Allow 160 MiB for each dependency build, 32 MiB per libplacebo build,
# 64 MiB for merge/output, and retain 128 MiB of free space between stages.
DEPENDENCY_STAGE_BYTES = 160 * 1024**2
LIBPLACEBO_STAGE_BYTES = 32 * 1024**2
MERGE_STAGE_BYTES = 64 * 1024**2
SPACE_RESERVE_BYTES = 128 * 1024**2
MAX_JOBS = 4
MAX_DEPLOYMENT_TARGET = (12, 0)


class BuildError(RuntimeError):
    pass


def run(argv: Sequence[str], *, cwd: Path | None = None, env: dict[str, str] | None = None,
        log: Path | None = None) -> str:
    """Run a checked command, teeing full output to a durable step log."""
    shown = " ".join(str(x) for x in argv)
    print(f"+ {shown}", flush=True)
    if log is None:
        result = subprocess.run(argv, cwd=cwd, env=env, text=True,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        output = result.stdout
    else:
        log.parent.mkdir(parents=True, exist_ok=True)
        with log.open("a", encoding="utf-8") as stream:
            stream.write(f"\n$ {shown}\n")
            stream.flush()
            result = subprocess.run(argv, cwd=cwd, env=env, text=True,
                                    stdout=stream, stderr=subprocess.STDOUT)
        output = log.read_text(encoding="utf-8", errors="replace")
    if result.returncode:
        tail = "\n".join(output.splitlines()[-30:])
        raise BuildError(f"command failed ({result.returncode}): {shown}\n{tail}")
    return output


def require_tool(name: str) -> str:
    path = shutil.which(name)
    if not path:
        raise BuildError(f"required tool not found on PATH: {name}")
    return path


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def verify_source_tree(archive: Path, destination: Path, root_name: str,
                       allowed_extra_roots: tuple[str, ...] = ()) -> None:
    """Verify cached extraction contents against the authenticated archive."""
    expected_paths: set[str] = set()
    with tarfile.open(archive, "r:gz") as bundle:
        for member in bundle.getmembers():
            relative = Path(member.name).relative_to(root_name)
            target = destination / relative
            resolved = target.resolve()
            if resolved != destination.resolve() and destination.resolve() not in resolved.parents:
                raise BuildError(f"unsafe cached source path: {target}")
            expected_paths.add(relative.as_posix())
            if member.isfile():
                if target.is_symlink() or not target.is_file():
                    raise BuildError(f"cached source file missing or replaced: {target}")
                stream = bundle.extractfile(member)
                assert stream is not None
                digest = hashlib.sha256()
                for block in iter(lambda: stream.read(1024 * 1024), b""):
                    digest.update(block)
                if digest.hexdigest() != sha256(target):
                    raise BuildError(f"cached source content differs from pinned archive: {target}")
            elif member.issym():
                if not target.is_symlink() or os.readlink(target) != member.linkname:
                    raise BuildError(f"cached source symlink differs from pinned archive: {target}")
            elif member.isdir():
                if target.is_symlink() or not target.is_dir():
                    raise BuildError(f"cached source directory missing or replaced: {target}")
            else:
                raise BuildError(f"unsupported pinned source archive entry: {member.name}")
    for target in destination.rglob("*"):
        relative = target.relative_to(destination).as_posix()
        if relative in expected_paths or any(
                relative == root or relative.startswith(root + "/") for root in allowed_extra_roots):
            continue
        # Source generators from the first build left Python bytecode here.
        # main redirects Python's cache prefix outside every source tree, so
        # these generated files cannot become compiler/generator inputs.
        if target.parent.name == "__pycache__" and target.suffix == ".pyc" and not target.is_symlink():
            continue
        # Empty directories cannot introduce compiler inputs; extra files can.
        if target.is_symlink() or target.is_file():
            raise BuildError(f"unexpected cached source input: {target}")


def source_extra_roots(name: str) -> tuple[str, ...]:
    return ("third_party/glslang", "third_party/spirv-tools", "third_party/spirv-headers") if name == "shaderc" else ()


def source_tree(name: str, work: Path) -> tuple[Path, str]:
    url, expected, root_name = SOURCE_ARCHIVES[name]
    archive = work / "sources" / f"{name}.tar.gz"
    archive.parent.mkdir(parents=True, exist_ok=True)
    if archive.exists() and sha256(archive) != expected:
        raise BuildError(f"cached source checksum mismatch: {archive}")
    if not archive.exists():
        temp = archive.with_suffix(archive.suffix + ".partial")
        try:
            request = urllib.request.Request(url, headers={"User-Agent": "PiliPlusX-build/1"})
            with urllib.request.urlopen(request, timeout=60) as response, temp.open("wb") as out:
                shutil.copyfileobj(response, out)
            actual = sha256(temp)
            if actual != expected:
                raise BuildError(f"source checksum mismatch for {url}: {actual}")
            temp.replace(archive)
        finally:
            temp.unlink(missing_ok=True)
    destination = work / "sources" / root_name
    if not destination.exists():
        with tarfile.open(archive, "r:gz") as bundle:
            base = (work / "sources").resolve()
            for member in bundle.getmembers():
                target = (base / member.name).resolve()
                if target != base and base not in target.parents:
                    raise BuildError(f"unsafe path in pinned source archive {archive}: {member.name}")
            bundle.extractall(base, filter="data")
    verify_source_tree(archive, destination, root_name, source_extra_roots(name))
    return destination, expected


def verify_arch(path: Path, arch: str) -> None:
    output = run(["/usr/bin/lipo", "-archs", str(path)])
    if arch not in output.split():
        raise BuildError(f"{path} does not contain {arch}: {output.strip()}")


def verify_minimum_os(path: Path, arch: str) -> str:
    output = run(["otool", "-arch", arch, "-l", str(path)])
    values = re.findall(r"\bminos\s+(\d+(?:\.\d+)?)", output)
    if not values:
        raise BuildError(f"{path}/{arch} has no LC_BUILD_VERSION minimum OS")
    parsed = [tuple(int(part) for part in value.split(".")) for value in values]
    if any(value > MAX_DEPLOYMENT_TARGET for value in parsed):
        raise BuildError(f"{path}/{arch} requires macOS {max(values, key=lambda v: tuple(map(int, v.split('.'))))}; app target is 12.0")
    return ",".join(values)


def verified_resume(work: Path) -> bool:
    """Allow the smaller budget only for the observed completed dependency cache."""
    for name, (_, expected, root_name) in SOURCE_ARCHIVES.items():
        archive = work / "sources" / f"{name}.tar.gz"
        if not archive.is_file() or not (work / "sources" / root_name).is_dir():
            return False
        if sha256(archive) != expected:
            raise BuildError(f"cached source checksum mismatch: {archive}")
        verify_source_tree(archive, work / "sources" / root_name, root_name,
                           source_extra_roots(name))
    shaderc = work / "sources" / SOURCE_ARCHIVES["shaderc"][2]
    for name in ("glslang", "spirv-tools", "spirv-headers"):
        destination = shaderc / "third_party" / name
        if not destination.is_dir():
            return False
        verify_source_tree(work / "sources" / f"{name}.tar.gz", destination,
                           SOURCE_ARCHIVES[name][2])
    lp = work / "sources" / "libplacebo"
    if not (lp / ".git").is_dir():
        return False
    if run(["git", "-C", str(lp), "rev-parse", "HEAD"]).strip() != LIBPLACEBO_COMMIT:
        return False
    require_clean_git_source(lp)
    prefix = work / "arm64"
    for name in ("libshaderc_shared.1.dylib", "libvulkan.1.dylib", "liblcms2.2.dylib"):
        library = prefix / "lib" / name
        if not library.is_file():
            return False
        verify_arch(library, "arm64")
        verify_minimum_os(library, "arm64")
    for name in ("shaderc", "vulkan-loader", "vulkan-headers"):
        cache = work / f"build-{name}-arm64" / "CMakeCache.txt"
        if not cache.is_file():
            return False
        text = cache.read_text(encoding="utf-8")
        for key, value in (("CMAKE_OSX_ARCHITECTURES", "arm64"),
                           ("CMAKE_OSX_DEPLOYMENT_TARGET", "12.0"),
                           ("CMAKE_INSTALL_PREFIX", str(prefix))):
            if not re.search(rf"^{key}:[^=]+={re.escape(value)}$", text, re.MULTILINE):
                return False
    return True


def require_clean_git_source(repo: Path) -> None:
    dirty = run(["git", "-C", str(repo), "status", "--porcelain", "--untracked-files=no"]).strip()
    if dirty:
        raise BuildError(f"tracked source differs from pinned Git tree: {repo}\n{dirty}")
    # Check both ordinary untracked files and files hidden by .gitignore.
    # Git excludes its own metadata and tracked submodule entries here; each
    # required submodule is checked independently by the same helper.
    for extra_flags in ([], ["--ignored"]):
        extras = run(["git", "-C", str(repo), "ls-files", "--others",
                      "--exclude-standard", "-z", *extra_flags])
        for relative in filter(None, extras.split("\0")):
            target = repo / relative
            if (target.parent.name == "__pycache__" and target.suffix == ".pyc"
                    and target.is_file() and not target.is_symlink()):
                # main isolates Python caches, so these known generated files
                # cannot be loaded by any source generator during the build.
                continue
            raise BuildError(f"unexpected untracked or ignored Git source input: {target}")


def require_stage_space(work: Path, stage: str, budget: int) -> None:
    free = shutil.disk_usage(work).free
    required = SPACE_RESERVE_BYTES + budget
    if free < required:
        raise BuildError(f"{stage} needs {required // 1024**2} MiB free "
                         f"(stage budget + reserve); found {free // 1024**2} MiB")


def git_source_record(repo: Path, commit: str) -> dict[str, str]:
    tree = run(["git", "-C", str(repo), "rev-parse", f"{commit}^{{tree}}"] ).strip()
    archive = subprocess.run(["git", "-C", str(repo), "archive", "--format=tar", commit],
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True).stdout
    return {"commit": commit, "tree": tree,
            "git_archive_sha256": hashlib.sha256(archive).hexdigest()}


def configure_libplacebo(source: Path, build: Path, prefix: Path, arch: str,
                         pkgconfig: str, python: str, jobs: int, logs: Path) -> Path:
    native_file = build.parent / f"meson-native-{arch}.ini"
    cross_file = build.parent / f"meson-cross-{arch}.ini"
    native_file.write_text(f"[binaries]\npython = '{python}'\n", encoding="utf-8")
    cross_file.write_text(
        "[binaries]\n"
        f"python = '{python}'\n"
        f"c = ['clang', '-arch', '{arch}']\n"
        f"cpp = ['clang++', '-arch', '{arch}']\n"
        "ar = 'ar'\nstrip = 'strip'\npkg-config = 'pkg-config'\n"
        "[host_machine]\nsystem = 'darwin'\n"
        f"cpu_family = '{'aarch64' if arch == 'arm64' else 'x86_64'}'\n"
        f"cpu = '{'aarch64' if arch == 'arm64' else 'x86_64'}'\n"
        "endian = 'little'\n[properties]\nneeds_exe_wrapper = true\n"
        "[built-in options]\nc_args = ['-mmacosx-version-min=12.0']\n"
        "cpp_args = ['-mmacosx-version-min=12.0']\n"
        f"c_link_args = ['-arch', '{arch}', '-mmacosx-version-min=12.0']\n"
        f"cpp_link_args = ['-arch', '{arch}', '-mmacosx-version-min=12.0']\n",
        encoding="utf-8")
    env = os.environ.copy()
    env["PKG_CONFIG_PATH"] = pkgconfig
    env["PKG_CONFIG_LIBDIR"] = pkgconfig
    setup = ["meson", "setup", str(build), str(source), "--buildtype=release",
             f"--prefix={prefix}", "--native-file", str(native_file),
             "--cross-file", str(cross_file), "-Ddemos=false", "-Dtests=false",
             "-Dvulkan=enabled", "-Dvk-proc-addr=enabled", "-Dopengl=enabled",
             "-Dgl-proc-addr=enabled", "-Dshaderc=enabled", "-Dglslang=disabled",
             "-Dlcms=enabled", "-Ddovi=enabled", "-Dlibdovi=disabled",
             "-Dxxhash=disabled", "-Dunwind=disabled",
             f"-Dvulkan-registry={prefix / 'share/vulkan/registry/vk.xml'}"]
    if (build / "meson-private" / "coredata.dat").exists():
        setup.insert(2, "--reconfigure")
    run(setup, env=env, log=logs / f"libplacebo-{arch}-setup.log")
    run(["ninja", "-C", str(build), f"-j{jobs}"], env=env,
        log=logs / f"libplacebo-{arch}-build.log")
    run(["meson", "install", "-C", str(build)], env=env,
        log=logs / f"libplacebo-{arch}-install.log")
    library = prefix / "lib" / "libplacebo.349.dylib"
    if not library.exists():
        # Meson may emit an unversioned linker name with the versioned dylib id.
        candidates = list((prefix / "lib").glob("libplacebo*.dylib"))
        if len(candidates) != 1:
            raise BuildError(f"cannot identify installed libplacebo dylib: {candidates}")
        library = candidates[0]
    return library


def cmake_build(source: Path, build: Path, prefix: Path, arch: str, jobs: int,
                logs: Path, extra: Sequence[str] = ()) -> None:
    run(["cmake", "-S", str(source), "-B", str(build), "-G", "Ninja",
         "-DCMAKE_BUILD_TYPE=Release", f"-DCMAKE_INSTALL_PREFIX={prefix}",
         f"-DCMAKE_OSX_ARCHITECTURES={arch}", "-DCMAKE_OSX_DEPLOYMENT_TARGET=12.0",
         "-DBUILD_TESTS=OFF", *extra],
        log=logs / f"{build.name}-configure.log")
    run(["cmake", "--build", str(build), "--target", "install", "--parallel", str(jobs)],
        log=logs / f"{build.name}-build.log")


def build_runtime_dependencies(work: Path, prefix: Path, arch: str, python: str,
                               jobs: int, logs: Path) -> dict[str, Path]:
    headers, _ = source_tree("vulkan-headers", work)
    cmake_build(headers, work / f"build-vulkan-headers-{arch}", prefix, arch, jobs,
                logs, ("-DVULKAN_HEADERS_ENABLE_INSTALL=ON", "-DVULKAN_HEADERS_ENABLE_TESTS=OFF"))
    loader, _ = source_tree("vulkan-loader", work)
    cmake_build(loader, work / f"build-vulkan-loader-{arch}", prefix, arch, jobs,
                logs, (f"-DCMAKE_PREFIX_PATH={prefix}",
                       "-DAPPLE_STATIC_LOADER=OFF", "-DLOADER_CODEGEN=OFF"))
    lcms, _ = source_tree("lcms2", work)
    lcms_build = work / f"build-lcms2-{arch}"
    lcms_build.mkdir(parents=True, exist_ok=True)
    env = os.environ.copy()
    env.update({"CC": f"clang -arch {arch}", "CXX": f"clang++ -arch {arch}",
                "CFLAGS": "-mmacosx-version-min=12.0",
                "CXXFLAGS": "-mmacosx-version-min=12.0",
                "LDFLAGS": f"-arch {arch} -mmacosx-version-min=12.0"})
    configure = lcms / "configure"
    host = f"{arch}-apple-darwin"
    run([str(configure), f"--host={host}", f"--prefix={prefix}",
         "--disable-static", "--enable-shared", "--without-jpeg", "--without-tiff"],
        cwd=lcms_build, env=env, log=logs / f"lcms2-{arch}-build.log")
    run(["make", f"-j{jobs}"], cwd=lcms_build, env=env,
        log=logs / f"lcms2-{arch}-build.log")
    run(["make", "install"], cwd=lcms_build, env=env,
        log=logs / f"lcms2-{arch}-build.log")

    shaderc, _ = source_tree("shaderc", work)
    for name in ("glslang", "spirv-tools", "spirv-headers"):
        source, _ = source_tree(name, work)
        dest = shaderc / "third_party" / name
        if not dest.exists() or not any(dest.iterdir()):
            shutil.copytree(source, dest, dirs_exist_ok=True)
        verify_source_tree(work / "sources" / f"{name}.tar.gz", dest,
                           SOURCE_ARCHIVES[name][2])
    shaderc_build = work / f"build-shaderc-{arch}"
    run(["cmake", "-S", str(shaderc), "-B", str(shaderc_build), "-G", "Ninja",
         "-DCMAKE_BUILD_TYPE=Release", f"-DCMAKE_INSTALL_PREFIX={prefix}",
        f"-DCMAKE_OSX_ARCHITECTURES={arch}", "-DCMAKE_OSX_DEPLOYMENT_TARGET=12.0",
         "-DSHADERC_SKIP_TESTS=ON",
         "-DSHADERC_SKIP_EXAMPLES=ON", "-DSHADERC_SKIP_EXECUTABLES=ON",
         "-DSHADERC_SKIP_INSTALL=OFF", "-DSHADERC_ENABLE_COPYRIGHT_CHECK=OFF",
         "-DCMAKE_INSTALL_NAME_DIR=@rpath"], log=logs / f"build-shaderc-{arch}-configure.log")
    run(["cmake", "--build", str(shaderc_build), "--target", "shaderc_shared",
         "--parallel", str(jobs)], log=logs / f"build-shaderc-{arch}-build.log")
    shader_lib = shaderc_build / "libshaderc" / "libshaderc_shared.1.dylib"
    shutil.copy2(shader_lib, prefix / "lib" / shader_lib.name)
    shader_link = prefix / "lib" / "libshaderc_shared.dylib"
    if shader_link.exists() and not shader_link.is_symlink():
        raise BuildError(f"refusing to replace unexpected shaderc linker path: {shader_link}")
    shader_link.unlink(missing_ok=True)
    shader_link.symlink_to(shader_lib.name)
    shutil.copytree(shaderc / "libshaderc" / "include" / "shaderc",
                    prefix / "include" / "shaderc", dirs_exist_ok=True)
    pcdir = prefix / "lib" / "pkgconfig"
    pcdir.mkdir(parents=True, exist_ok=True)
    (pcdir / "shaderc.pc").write_text(
        f"prefix={prefix}\nexec_prefix=${{prefix}}\nlibdir=${{prefix}}/lib\n"
        f"includedir=${{prefix}}/include\n\nName: shaderc\n"
        "Description: Tools and libraries for Vulkan shader compilation\n"
        "Version: 2026.4.1\nURL: https://github.com/google/shaderc\n\n"
        "Libs: -L${libdir} -lshaderc_shared\nCflags: -I${includedir}\n",
        encoding="utf-8")
    (work / "source-archive-hashes.json").write_text(json.dumps({
        name: SOURCE_ARCHIVES[name][1] for name in SOURCE_ARCHIVES
    }, indent=2) + "\n", encoding="utf-8")
    return {
        "libshaderc_shared.1.dylib": prefix / "lib/libshaderc_shared.1.dylib",
        "libvulkan.1.dylib": prefix / "lib/libvulkan.1.dylib",
        "liblcms2.2.dylib": prefix / "lib/liblcms2.2.dylib",
    }


def merge_and_rewrite(work: Path, output: Path, arm_prefix: Path, x86_prefix: Path,
                      logs: Path) -> dict[str, dict[str, object]]:
    output.mkdir(parents=True, exist_ok=True)
    records: dict[str, dict[str, object]] = {}
    for name in ("libplacebo.dylib", "libshaderc_shared.1.dylib",
                 "libvulkan.1.dylib", "liblcms2.2.dylib"):
        arm = arm_prefix / "lib" / name
        x86 = x86_prefix / "lib" / name
        if not arm.is_file() or not x86.is_file():
            raise BuildError(f"missing architecture slice for {name}: arm={arm.exists()} x86={x86.exists()}")
        verify_arch(arm, "arm64")
        verify_arch(x86, "x86_64")
        arm_minos = verify_minimum_os(arm, "arm64")
        x86_minos = verify_minimum_os(x86, "x86_64")
        final = output / name
        thin_dir = work / "merge" / name
        thin_dir.mkdir(parents=True, exist_ok=True)
        slices = []
        source_hashes = {}
        for arch, source in (("arm64", arm), ("x86_64", x86)):
            source_hashes[arch] = sha256(source)
            thin = thin_dir / f"{arch}.dylib"
            source_arches = run(["lipo", "-archs", str(source)]).split()
            if source_arches == [arch]:
                shutil.copy2(source, thin)
            else:
                run(["lipo", str(source), "-thin", arch, "-output", str(thin)])
            install_name = f"@rpath/{name}"
            run(["install_name_tool", "-id", install_name, str(thin)])
            deps = run(["otool", "-L", str(thin)])
            for line in deps.splitlines()[1:]:
                dependency = line.strip().split(" (compatibility", 1)[0]
                if dependency.startswith(("/System/Library/", "/usr/lib/")):
                    continue
                if dependency.startswith("@"):
                    continue
                dep_name = Path(dependency).name
                if dep_name not in {"libplacebo.dylib", "libshaderc_shared.1.dylib",
                                    "libvulkan.1.dylib", "liblcms2.2.dylib"}:
                    raise BuildError(f"unexpected non-system import in {name}/{arch}: {dependency}")
                run(["install_name_tool", "-change", dependency, f"@rpath/{dep_name}", str(thin)])
            run(["codesign", "--force", "--sign", "-", str(thin)],
                log=logs / f"codesign-{name}-{arch}.log")
            slices.append(thin)
        run(["lipo", "-create", *map(str, slices), "-output", str(final)])
        verify_arch(final, "arm64")
        verify_arch(final, "x86_64")
        verify_minimum_os(final, "arm64")
        verify_minimum_os(final, "x86_64")
        run(["codesign", "--force", "--sign", "-", str(final)],
            log=logs / f"codesign-{name}-universal.log")
        records[name] = {"sha256": sha256(final), "source_slices_sha256": source_hashes,
                         "minimum_os": {"arm64": arm_minos, "x86_64": x86_minos},
                         "architectures": ["arm64", "x86_64"]}
    return records


def main() -> int:
    if sys.version_info[:2] != (3, 11):
        raise BuildError("use Python 3.11; newer Python XML handling broke the pinned 7.349.0 generator")
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output_dir", type=Path, help="new/empty destination for four universal dylibs")
    parser.add_argument("--work-dir", type=Path, required=True,
                        help="persistent source/build directory; reruns resume from this directory")
    parser.add_argument("--jobs", type=int, default=MAX_JOBS, help="bounded parallel jobs (1..4)")
    args = parser.parse_args()
    if not 1 <= args.jobs <= MAX_JOBS:
        raise BuildError(f"--jobs must be between 1 and {MAX_JOBS}")
    if platform.system() != "Darwin" or platform.machine() != "arm64":
        raise BuildError("this reproducible cross-build recipe requires an Apple Silicon macOS host")
    output = args.output_dir.expanduser().resolve()
    work = args.work_dir.expanduser().resolve()
    allowed_outputs = {"libplacebo.dylib", "libshaderc_shared.1.dylib",
                       "libvulkan.1.dylib", "liblcms2.2.dylib", "manifest.json"}
    if output.exists() and any(item.name not in allowed_outputs for item in output.iterdir()):
        raise BuildError(f"refusing to overwrite nonempty output directory: {output}")
    if output == work or output in work.parents or work in output.parents:
        raise BuildError("OUTPUT_DIR and --work-dir must be separate, non-overlapping directories")
    if output.exists() and any(item.is_symlink() or not item.is_file() for item in output.iterdir()):
        raise BuildError(f"refusing symlink or directory in output directory: {output}")
    probe = work.parent
    while not probe.exists() and probe != probe.parent:
        probe = probe.parent
    free = shutil.disk_usage(probe).free
    resumed = work.is_dir() and verified_resume(work)
    minimum_free = MIN_RESUME_FREE_BYTES if resumed else MIN_FREE_BYTES
    if free < minimum_free:
        raise BuildError(f"need at least {minimum_free // 1024**2} MiB free before "
                         f"{'verified resume' if resumed else 'fresh build'}; "
                         f"found {free // 1024**2} MiB")
    for tool in ("git", "cmake", "ninja", "meson", "pkg-config", "codesign",
                 "lipo", "otool", "install_name_tool", "clang", "clang++", "make"):
        require_tool(tool)
    python = require_tool("python3.11")
    logs = work / "logs"
    sources = work / "sources"
    logs.mkdir(parents=True, exist_ok=True)
    sources.mkdir(parents=True, exist_ok=True)
    os.environ["PYTHONPYCACHEPREFIX"] = str(work / "python-cache")
    (logs / "space-plan.json").write_text(json.dumps({
        "verified_resume": resumed, "initial_free_bytes": free,
        "minimum_free_bytes": minimum_free, "reserve_bytes": SPACE_RESERVE_BYTES,
        "dependency_stage_bytes": DEPENDENCY_STAGE_BYTES,
        "libplacebo_stage_bytes": LIBPLACEBO_STAGE_BYTES,
        "merge_stage_bytes": MERGE_STAGE_BYTES,
    }, indent=2) + "\n", encoding="utf-8")

    # Fetch only the exact reviewed libplacebo commit. Git verifies every object
    # against its content-addressed object ID; submodule gitlinks pin dependencies.
    lp = sources / "libplacebo"
    if not lp.exists():
        run(["git", "clone", "--no-checkout", "https://github.com/haasn/libplacebo.git", str(lp)],
            log=logs / "libplacebo-fetch.log")
    else:
        require_clean_git_source(lp)
    run(["git", "-C", str(lp), "fetch", "--depth=1", "origin", LIBPLACEBO_COMMIT],
        log=logs / "libplacebo-fetch.log")
    commit = run(["git", "-C", str(lp), "rev-parse", "FETCH_HEAD"]).strip()
    if commit != LIBPLACEBO_COMMIT:
        raise BuildError(f"libplacebo commit mismatch: {commit}")
    run(["git", "-C", str(lp), "checkout", "--detach", LIBPLACEBO_COMMIT],
        log=logs / "libplacebo-fetch.log")
    require_clean_git_source(lp)
    needed_submodules = ("3rdparty/glad", "3rdparty/jinja", "3rdparty/markupsafe",
                         "3rdparty/fast_float", "3rdparty/Vulkan-Headers")
    run(["git", "-C", str(lp), "submodule", "update", "--init", *needed_submodules],
        log=logs / "libplacebo-submodules.log")
    submodules = []
    for relative in needed_submodules:
        expected = run(["git", "-C", str(lp), "rev-parse", f"HEAD:{relative}"]).strip()
        actual = run(["git", "-C", str(lp / relative), "rev-parse", "HEAD"]).strip()
        if expected != actual:
            raise BuildError(f"libplacebo submodule {relative} pin mismatch: {actual}")
        require_clean_git_source(lp / relative)
        submodules.append(f"{actual} {relative}")

    arm_prefix, x86_prefix = work / "arm64", work / "x86_64"
    arm_pkg, x86_pkg = str(arm_prefix / "lib/pkgconfig"), str(x86_prefix / "lib/pkgconfig")
    for arch, prefix in (("arm64", arm_prefix), ("x86_64", x86_prefix)):
        require_stage_space(work, f"{arch} dependencies", DEPENDENCY_STAGE_BYTES)
        runtime_libraries = build_runtime_dependencies(work, prefix, arch, python,
                                                       args.jobs, logs)
        for name, path in runtime_libraries.items():
            if not path.is_file():
                raise BuildError(f"expected {arch} runtime artifact missing: {name}: {path}")
    require_stage_space(work, "arm64 libplacebo", LIBPLACEBO_STAGE_BYTES)
    arm_lp = configure_libplacebo(lp, work / "build-libplacebo-arm64", arm_prefix,
                                  "arm64", arm_pkg, python, args.jobs, logs)
    require_stage_space(work, "x86_64 libplacebo", LIBPLACEBO_STAGE_BYTES)
    x86_lp = configure_libplacebo(lp, work / "build-libplacebo-x86_64", x86_prefix,
                                  "x86_64", x86_pkg, python, args.jobs, logs)
    # Meson writes the versioned soname; keep a stable canonical input filename.
    for path in (arm_lp, x86_lp):
        expected = path.parent / "libplacebo.dylib"
        if path != expected and not expected.exists():
            shutil.copy2(path, expected)
    require_stage_space(work, "universal merge", MERGE_STAGE_BYTES)
    output.mkdir(parents=True, exist_ok=True)
    records = merge_and_rewrite(work, output, arm_prefix, x86_prefix, logs)
    manifest = {
        "schema": 1,
        "versions": VERSIONS,
        "sources": {
            "libplacebo": {"url": "https://github.com/haasn/libplacebo.git",
                           **git_source_record(lp, LIBPLACEBO_COMMIT),
                           "git_submodules": submodules},
            "source_archives_sha256": json.loads((work / "source-archive-hashes.json").read_text()),
        },
        "libraries": records,
    }
    (output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    for library in records:
        run(["codesign", "--verify", "--strict", str(output / library)],
            log=logs / "codesign-verify.log")
    print(f"Universal runtime complete: {output}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except BuildError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        raise SystemExit(2)

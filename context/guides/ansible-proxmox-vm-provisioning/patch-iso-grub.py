#!/usr/bin/env python
"""
Patch a bootable ISO by mapping all files from ./iso back into the ISO
at the same relative paths, then writing a new ISO.

Examples:
  python patch-iso-grub.py \
    --input debian.iso \
    --output debian-patched.iso

  python patch-iso-grub.py \
    --input debian.iso \
    --output debian-patched.iso \
    --source ./iso

Requirements:
  - xorriso
  - Python 3.9+
"""

from __future__ import annotations

import argparse
import shutil
import subprocess
import sys
from pathlib import Path


class IsoPatchError(Exception):
    pass


IGNORE_NAMES = {".exported_paths"}


def run(cmd: list[str], check: bool = True) -> subprocess.CompletedProcess:
    proc = subprocess.run(cmd, text=True, capture_output=True)
    if check and proc.returncode != 0:
        raise IsoPatchError(
            f"Command failed with exit code {proc.returncode}\n"
            f"CMD: {' '.join(cmd)}\n"
            f"STDOUT:\n{proc.stdout}\n"
            f"STDERR:\n{proc.stderr}"
        )
    return proc


def require_binary(name: str) -> None:
    if shutil.which(name) is None:
        raise IsoPatchError(f"Required binary not found in PATH: {name}")


def validate_paths(input_iso: Path, source_dir: Path, output_iso: Path) -> None:
    if not input_iso.is_file():
        raise IsoPatchError(f"Input ISO not found: {input_iso}")
    if not source_dir.is_dir():
        raise IsoPatchError(f"Source directory not found: {source_dir}")
    if output_iso.exists():
        raise IsoPatchError(f"Output ISO already exists: {output_iso}")


def collect_files(source_dir: Path) -> list[tuple[Path, str]]:
    files: list[tuple[Path, str]] = []

    for path in sorted(source_dir.rglob("*")):
        if not path.is_file():
            continue
        if path.name in IGNORE_NAMES:
            continue

        rel = path.relative_to(source_dir).as_posix()
        iso_path = "/" + rel
        files.append((path, iso_path))

    return files


def iso_path_exists(input_iso: Path, iso_path: str) -> bool:
    proc = run(
        [
            "xorriso",
            "-indev", str(input_iso),
            "-find", iso_path,
            "--",
            "-end",
        ],
        check=False,
    )
    found = [line.strip() for line in proc.stdout.splitlines() if line.strip().startswith("/")]
    return iso_path in found


def patch_iso(
    input_iso: Path,
    output_iso: Path,
    mappings: list[tuple[Path, str]],
) -> None:
    cmd = [
        "xorriso",
        "-indev", str(input_iso),
        "-outdev", str(output_iso),
        "-boot_image", "any", "replay",
    ]

    for local_file, iso_path in mappings:
        cmd.extend(["-map", str(local_file), iso_path])

    cmd.extend(["-commit", "-end"])
    run(cmd)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--source", type=Path, default=Path("./iso"))
    parser.add_argument("--allow-new", action="store_true")
    return parser.parse_args()


def main() -> int:
    args = parse_args()

    require_binary("xorriso")
    validate_paths(args.input, args.source, args.output)

    mappings = collect_files(args.source)
    if not mappings:
        raise IsoPatchError(f"No files found under source directory: {args.source}")

    print("Planned mappings:")
    for local_file, iso_path in mappings:
        print(f"  {local_file} -> {iso_path}")

    if not args.allow_new:
        missing = [iso_path for _, iso_path in mappings if not iso_path_exists(args.input, iso_path)]
        if missing:
            raise IsoPatchError(
                "These files do not already exist in the ISO:\n"
                + "\n".join(f"  {p}" for p in missing)
                + "\nUse --allow-new if you intentionally want to add them."
            )

    patch_iso(args.input, args.output, mappings)
    print(f"\nCreated patched ISO: {args.output}")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except IsoPatchError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        sys.exit(1)
    except KeyboardInterrupt:
        print("Interrupted.", file=sys.stderr)
        sys.exit(130)
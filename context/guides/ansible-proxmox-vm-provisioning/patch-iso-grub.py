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


def debug_print(enabled: bool, msg: str) -> None:
    if enabled:
        print(f"[debug] {msg}", file=sys.stderr)


def run_combined(cmd: list[str], debug: bool = False, check: bool = True) -> str:
    debug_print(debug, f"running command: {' '.join(cmd)}")

    proc = subprocess.run(
        cmd,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        encoding="utf-8",
        errors="replace",
    )

    output = proc.stdout or ""

    debug_print(debug, f"return code: {proc.returncode}")
    debug_print(debug, f"captured output length: {len(output)}")

    if debug and output:
        preview_lines = output.splitlines()[:60]
        debug_print(debug, "output preview (first 60 lines):")
        for line in preview_lines:
            print(f"[debug]   {line}", file=sys.stderr)

    if check and proc.returncode != 0:
        raise IsoPatchError(
            f"Command failed with exit code {proc.returncode}\n"
            f"CMD: {' '.join(cmd)}\n"
            f"OUTPUT:\n{output}"
        )

    return output


def require_binary(name: str, debug: bool = False) -> None:
    path = shutil.which(name)
    debug_print(debug, f"which({name!r}) -> {path}")
    if path is None:
        raise IsoPatchError(f"Required binary not found in PATH: {name}")


def normalize_xorriso_path(line: str) -> str | None:
    stripped = line.strip()
    if not stripped:
        return None

    # xorriso commonly prints paths like '/boot/grub/grub.cfg'
    if stripped.startswith("'") and stripped.endswith("'") and len(stripped) >= 3:
        stripped = stripped[1:-1]

    if stripped.startswith("/"):
        return stripped

    return None


def validate_paths(
    input_iso: Path,
    source_dir: Path,
    output_iso: Path,
    debug: bool = False,
) -> None:
    debug_print(debug, f"input iso: {input_iso}")
    debug_print(debug, f"source dir: {source_dir}")
    debug_print(debug, f"output iso: {output_iso}")

    if not input_iso.is_file():
        raise IsoPatchError(f"Input ISO not found: {input_iso}")

    if not source_dir.is_dir():
        raise IsoPatchError(f"Source directory not found: {source_dir}")

    if output_iso.exists():
        raise IsoPatchError(f"Output ISO already exists: {output_iso}")


def collect_files(source_dir: Path, debug: bool = False) -> list[tuple[Path, str]]:
    mappings: list[tuple[Path, str]] = []

    for path in sorted(source_dir.rglob("*")):
        if not path.is_file():
            continue
        if path.name in IGNORE_NAMES:
            continue

        rel = path.relative_to(source_dir).as_posix()
        iso_path = "/" + rel
        mappings.append((path, iso_path))

    debug_print(debug, f"collected replacement file count: {len(mappings)}")
    if debug:
        for local_file, iso_path in mappings:
            print(f"[debug] mapping: {local_file} -> {iso_path}", file=sys.stderr)

    return mappings


def iso_path_exists(input_iso: Path, iso_path: str, debug: bool = False) -> bool:
    output = run_combined(
        [
            "xorriso",
            "-indev", str(input_iso),
            "-find", iso_path,
            "--",
            "-end",
        ],
        debug=debug,
        check=False,
    )

    found = []
    for line in output.splitlines():
        path = normalize_xorriso_path(line)
        if path is not None:
            found.append(path)

    exists = iso_path in found
    debug_print(debug, f"exists in ISO? {iso_path} -> {exists}")
    return exists


def patch_iso(
    input_iso: Path,
    output_iso: Path,
    mappings: list[tuple[Path, str]],
    debug: bool = False,
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
    run_combined(cmd, debug=debug, check=True)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Patch an ISO using files found under ./iso."
    )
    parser.add_argument(
        "--input",
        required=True,
        type=Path,
        help="Source ISO path",
    )
    parser.add_argument(
        "--output",
        required=True,
        type=Path,
        help="Patched ISO path to create",
    )
    parser.add_argument(
        "--source",
        type=Path,
        default=Path("./iso"),
        help="Replacement source directory (default: ./iso)",
    )
    parser.add_argument(
        "--allow-new",
        action="store_true",
        help="Allow adding files that do not already exist in the ISO",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Show planned mappings and checks, but do not write a new ISO",
    )
    parser.add_argument(
        "--debug",
        action="store_true",
        help="Enable verbose debug logging",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()

    debug_print(args.debug, f"python executable: {sys.executable}")
    debug_print(args.debug, f"python version: {sys.version}")

    require_binary("xorriso", debug=args.debug)
    validate_paths(args.input, args.source, args.output, debug=args.debug)

    mappings = collect_files(args.source, debug=args.debug)
    if not mappings:
        raise IsoPatchError(f"No files found under source directory: {args.source}")

    print("Planned mappings:")
    for local_file, iso_path in mappings:
        print(f"  {local_file} -> {iso_path}")

    if not args.allow_new:
        missing = [
            iso_path
            for _, iso_path in mappings
            if not iso_path_exists(args.input, iso_path, debug=args.debug)
        ]
        if missing:
            raise IsoPatchError(
                "These files do not already exist in the ISO:\n"
                + "\n".join(f"  {p}" for p in missing)
                + "\nUse --allow-new if you intentionally want to add them."
            )

    if args.dry_run:
        print("\nDry run only. No ISO was written.")
        return 0

    patch_iso(args.input, args.output, mappings, debug=args.debug)
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
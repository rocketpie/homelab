#!/usr/bin/env python
"""
Export all GRUB-related config files from a bootable ISO into ./iso,
preserving their relative paths.

Examples:
  python export-iso-grub.py --input debian.iso
  python export-iso-grub.py --input debian.iso --dest ./iso

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


class IsoExportError(Exception):
    pass


TARGET_NAMES = {
    "grub.cfg",
    "loopback.cfg",
    "isolinux.cfg",
    "txt.cfg",
}

TARGET_PATH_PARTS = (
    "/boot/grub/",
    "/efi/boot/",
    "/isolinux/",
    "/boot/isolinux/",
)


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
        preview_lines = output.splitlines()[:40]
        debug_print(debug, "output preview (first 40 lines):")
        for line in preview_lines:
            print(f"[debug]   {line}", file=sys.stderr)

    if check and proc.returncode != 0:
        raise IsoExportError(
            f"Command failed with exit code {proc.returncode}\n"
            f"CMD: {' '.join(cmd)}\n"
            f"OUTPUT:\n{output}"
        )

    return output


def require_binary(name: str, debug: bool = False) -> None:
    path = shutil.which(name)
    debug_print(debug, f"which({name!r}) -> {path}")
    if path is None:
        raise IsoExportError(f"Required binary not found in PATH: {name}")


def normalize_xorriso_path(line: str) -> str | None:
    stripped = line.strip()
    if not stripped:
        return None

    # xorriso often prints ISO paths as quoted strings, e.g. '/boot/grub/grub.cfg'
    if stripped.startswith("'") and stripped.endswith("'") and len(stripped) >= 3:
        stripped = stripped[1:-1]

    if stripped.startswith("/"):
        return stripped

    return None


def list_iso_files(input_iso: Path, debug: bool = False) -> list[str]:
    output = run_combined(
        [
            "xorriso",
            "-indev", str(input_iso),
            "-find", "/",
            "-type", "f",
            "--",
            "-end",
        ],
        debug=debug,
    )

    files = []
    for idx, line in enumerate(output.splitlines(), start=1):
        stripped = line.strip()
        if debug and idx <= 80:
            debug_print(debug, f"line {idx}: {stripped!r}")

        path = normalize_xorriso_path(line)
        if path is not None:
            files.append(path)

    files = sorted(set(files))
    debug_print(debug, f"parsed file paths: {len(files)}")

    if debug and files:
        debug_print(debug, "parsed file path preview:")
        for path in files[:30]:
            print(f"[debug]   {path}", file=sys.stderr)

    return files


def is_candidate(path: str) -> bool:
    p = path.lower()
    name = Path(p).name

    # exact known config filenames
    if name in {"grub.cfg", "loopback.cfg", "isolinux.cfg", "txt.cfg"}:
        return True

    # optional: other plain-text boot config files
    if name.endswith(".cfg"):
        if "/boot/grub/" in p:
            return True
        if "/efi/boot/" in p:
            return True
        if "/isolinux/" in p:
            return True
        if "/boot/isolinux/" in p:
            return True

    return False


def export_file(input_iso: Path, iso_path: str, dest_root: Path, debug: bool = False) -> Path:
    relative = iso_path.lstrip("/")
    output_path = dest_root / relative
    output_path.parent.mkdir(parents=True, exist_ok=True)

    debug_print(debug, f"exporting {iso_path} -> {output_path}")

    run_combined(
        [
            "xorriso",
            "-osirrox", "on",
            "-indev", str(input_iso),
            "-extract", iso_path, str(output_path),
            "-end",
        ],
        debug=debug,
    )

    return output_path


def write_manifest(dest_root: Path, iso_paths: list[str], debug: bool = False) -> None:
    manifest = dest_root / ".exported_paths"
    manifest.write_text("".join(f"{p}\n" for p in iso_paths), encoding="utf-8")
    debug_print(debug, f"wrote manifest: {manifest}")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", required=True, type=Path)
    parser.add_argument("--dest", type=Path, default=Path("./iso"))
    parser.add_argument("--force", action="store_true")
    parser.add_argument("--debug-list", action="store_true")
    parser.add_argument("--debug", action="store_true")
    return parser.parse_args()


def main() -> int:
    args = parse_args()

    debug_print(args.debug, f"python executable: {sys.executable}")
    debug_print(args.debug, f"python version: {sys.version}")
    debug_print(args.debug, f"input iso: {args.input}")
    debug_print(args.debug, f"dest dir: {args.dest}")

    require_binary("xorriso", debug=args.debug)

    if not args.input.is_file():
        raise IsoExportError(f"Input ISO not found: {args.input}")

    if args.dest.exists():
        debug_print(args.debug, f"destination exists: {args.dest}")
        if args.dest.is_dir():
            existing = list(args.dest.iterdir())
            debug_print(args.debug, f"destination entry count: {len(existing)}")
            if existing and not args.force:
                raise IsoExportError(
                    f"Destination directory is not empty: {args.dest}\n"
                    "Use --force if that is intentional."
                )

    args.dest.mkdir(parents=True, exist_ok=True)

    all_files = list_iso_files(args.input, debug=args.debug)

    if args.debug_list:
        debug_print(args.debug, f"printing {len(all_files)} parsed ISO file paths")
        for path in all_files:
            print(path)
        return 0

    candidates = sorted({path for path in all_files if is_candidate(path)})

    debug_print(args.debug, f"final candidate count: {len(candidates)}")
    if args.debug:
        for path in candidates:
            print(f"[debug] candidate: {path}", file=sys.stderr)

    if not candidates:
        raise IsoExportError(
            "No GRUB/boot config files found in the ISO.\n"
            "Run with --debug-list --debug and inspect the parsed file list."
        )

    print("Exporting files:")
    for iso_path in candidates:
        output_path = export_file(args.input, iso_path, args.dest, debug=args.debug)
        print(f"  {iso_path} -> {output_path}")

    write_manifest(args.dest, candidates, debug=args.debug)
    print(f"\nExport complete. Files written under: {args.dest}")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except IsoExportError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        sys.exit(1)
    except KeyboardInterrupt:
        print("Interrupted.", file=sys.stderr)
        sys.exit(130)
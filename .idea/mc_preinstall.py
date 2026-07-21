"""
Minecraft pre-installer — downloads all game files for a specific version
so the official launcher skips its own download step.

Usage:
    python mc_preinstall.py [--version 26.1.2] [--output ~/.minecraft] [--platform windows-x64]

Uses only Mojang's public APIs. No login required.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import sys
import time
import urllib.request
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path

MANIFEST_URL = "https://launchermeta.mojang.com/mc/game/version_manifest_v2.json"
JAVA_RUNTIME_URL = "https://launchermeta.mojang.com/v1/products/java-runtime/2ec0cc96c44e5a76b9c8b7c39df7210883d12871/all.json"

# Map platform arg → (Mojang platform key, OS name for library rules)
PLATFORMS = {
    "windows-x64": ("windows-x64", "windows"),
    "windows-x86": ("windows-x86", "windows"),
    "windows-arm64": ("windows-arm64", "windows"),
    "linux": ("linux", "linux"),
    "mac-os": ("mac-os", "osx"),
    "mac-os-arm64": ("mac-os-arm64", "osx"),
}


class Stats:
    def __init__(self):
        self.downloaded = 0
        self.skipped = 0
        self.failed = 0
        self.bytes_downloaded = 0

    def report(self, label: str = ""):
        print(
            f"  {label} downloaded={self.downloaded}  skipped={self.skipped}  "
            f"failed={self.failed}  size={self.bytes_downloaded / 1024 / 1024:.1f}MB"
        )


def sha1_of(path: Path) -> str:
    h = hashlib.sha1()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 16), b""):
            h.update(chunk)
    return h.hexdigest()


def download_file(url: str, dest: Path, expected_sha1: str | None = None, expected_size: int | None = None) -> bool:
    """Download a file if it doesn't already exist (or SHA1 mismatch). Returns True on success."""
    if dest.exists():
        if expected_sha1 and sha1_of(dest) == expected_sha1:
            return False  # already valid
        if not expected_sha1 and expected_size and dest.stat().st_size == expected_size:
            return False

    dest.parent.mkdir(parents=True, exist_ok=True)
    part = dest.with_suffix(dest.suffix + ".part")
    try:
        urllib.request.urlretrieve(url, str(part))
        if expected_sha1:
            actual = sha1_of(part)
            if actual != expected_sha1:
                part.unlink(missing_ok=True)
                raise ValueError(f"SHA1 mismatch for {dest.name}: expected {expected_sha1}, got {actual}")
        part.rename(dest)
        return True
    except Exception:
        part.unlink(missing_ok=True)
        raise


def fetch_json(url: str) -> dict:
    with urllib.request.urlopen(url) as resp:
        return json.loads(resp.read())


def lib_allowed(lib: dict, os_name: str) -> bool:
    """Evaluate library rules to decide whether this lib is needed on the target OS."""
    rules = lib.get("rules")
    if not rules:
        return True

    result = False
    for rule in rules:
        action_allow = rule["action"] == "allow"
        os_cond = rule.get("os", {})
        if not os_cond:
            result = action_allow
        elif os_cond.get("name") == os_name:
            result = action_allow
    return result


def download_batch(tasks: list[tuple[str, Path, str | None, int | None]], stats: Stats, workers: int = 16, label: str = ""):
    """Download a batch of (url, dest, sha1, size) tuples with a thread pool."""
    if not tasks:
        return

    total = len(tasks)
    done = 0
    t0 = time.time()

    def _do(item):
        url, dest, sha1, size = item
        try:
            was_new = download_file(url, dest, sha1, size)
            return was_new, size or 0
        except Exception as e:
            print(f"    FAIL: {dest.name}: {e}", file=sys.stderr)
            return None, 0

    with ThreadPoolExecutor(max_workers=workers) as pool:
        futures = {pool.submit(_do, t): t for t in tasks}
        for fut in as_completed(futures):
            done += 1
            result, sz = fut.result()
            if result is None:
                stats.failed += 1
            elif result:
                stats.downloaded += 1
                stats.bytes_downloaded += sz
            else:
                stats.skipped += 1

            if done % 500 == 0 or done == total:
                elapsed = time.time() - t0
                speed = stats.bytes_downloaded / 1024 / 1024 / elapsed if elapsed > 0 else 0
                print(f"    [{label}] {done}/{total}  ({speed:.1f} MB/s)")


def install_version(version_id: str, mc_dir: Path, platform: str, workers: int):
    os_platform, os_name = PLATFORMS[platform]

    print(f"Target: version={version_id}  dir={mc_dir}  platform={platform}")

    # --- Version manifest ---
    print("\n[1/5] Fetching version manifest...")
    manifest = fetch_json(MANIFEST_URL)
    ver_entry = next((v for v in manifest["versions"] if v["id"] == version_id), None)
    if not ver_entry:
        available = [v["id"] for v in manifest["versions"] if v["type"] == "release"][:15]
        print(f"ERROR: version '{version_id}' not found. Recent releases: {available}", file=sys.stderr)
        sys.exit(1)

    ver_json = fetch_json(ver_entry["url"])

    # Save version JSON
    ver_dir = mc_dir / "versions" / version_id
    ver_dir.mkdir(parents=True, exist_ok=True)
    ver_json_path = ver_dir / f"{version_id}.json"
    ver_json_path.write_text(json.dumps(ver_json, indent=2))
    print(f"  Saved {ver_json_path}")

    # --- Client JAR ---
    print("\n[2/5] Downloading client JAR...")
    client = ver_json["downloads"]["client"]
    client_path = ver_dir / f"{version_id}.jar"
    stats_client = Stats()
    download_batch(
        [(client["url"], client_path, client["sha1"], client["size"])],
        stats_client, label="client",
    )
    stats_client.report("client")

    # --- Libraries ---
    print(f"\n[3/5] Downloading libraries (filtered for {os_name})...")
    lib_tasks = []
    for lib in ver_json["libraries"]:
        if not lib_allowed(lib, os_name):
            continue
        artifact = lib.get("downloads", {}).get("artifact")
        if artifact:
            dest = mc_dir / "libraries" / artifact["path"]
            lib_tasks.append((artifact["url"], dest, artifact["sha1"], artifact["size"]))

    stats_libs = Stats()
    download_batch(lib_tasks, stats_libs, workers=workers, label="libraries")
    stats_libs.report("libraries")

    # --- Assets ---
    print("\n[4/5] Downloading assets...")
    asset_index_info = ver_json["assetIndex"]
    asset_index = fetch_json(asset_index_info["url"])

    # Save asset index
    idx_dir = mc_dir / "assets" / "indexes"
    idx_dir.mkdir(parents=True, exist_ok=True)
    idx_path = idx_dir / f"{asset_index_info['id']}.json"
    idx_path.write_text(json.dumps(asset_index, indent=2))
    print(f"  Saved {idx_path}")
    print(f"  {len(asset_index['objects'])} asset objects to process...")

    asset_tasks = []
    for obj_name, obj in asset_index["objects"].items():
        h = obj["hash"]
        dest = mc_dir / "assets" / "objects" / h[:2] / h
        url = f"https://resources.download.minecraft.net/{h[:2]}/{h}"
        asset_tasks.append((url, dest, h, obj["size"]))

    stats_assets = Stats()
    download_batch(asset_tasks, stats_assets, workers=workers, label="assets")
    stats_assets.report("assets")

    # --- Java Runtime ---
    print(f"\n[5/5] Downloading Java runtime (java-runtime-epsilon, {os_platform})...")
    rt_manifest = fetch_json(JAVA_RUNTIME_URL)
    rt_platform = rt_manifest.get(os_platform, {})
    java_comp = ver_json.get("javaVersion", {}).get("component", "java-runtime-gamma")
    rt_entries = rt_platform.get(java_comp, [])
    if not rt_entries:
        print(f"  WARNING: no {java_comp} runtime for {os_platform}, skipping Java runtime")
    else:
        rt_entry = rt_entries[0]
        print(f"  Java version: {rt_entry['version']['name']}")
        rt_files = fetch_json(rt_entry["manifest"]["url"])["files"]

        rt_base = mc_dir / "runtime" / java_comp / os_platform / java_comp
        rt_tasks = []
        for rel_path, info in rt_files.items():
            if info["type"] != "file":
                continue
            raw = info.get("downloads", {}).get("raw", {})
            if not raw:
                continue
            dest = rt_base / rel_path
            rt_tasks.append((raw["url"], dest, raw["sha1"], raw["size"]))

            # Some files also have an lzma-compressed version — we only need raw
            if info.get("executable", False):
                dest.parent.mkdir(parents=True, exist_ok=True)

        stats_rt = Stats()
        download_batch(rt_tasks, stats_rt, workers=workers, label="runtime")
        stats_rt.report("runtime")

    # --- Summary ---
    total_dl = stats_client.bytes_downloaded + stats_libs.bytes_downloaded + stats_assets.bytes_downloaded
    total_skip = stats_client.skipped + stats_libs.skipped + stats_assets.skipped
    total_fail = stats_client.failed + stats_libs.failed + stats_assets.failed
    print(f"\n{'='*60}")
    print(f"  DONE — Minecraft {version_id} pre-installed to {mc_dir}")
    print(f"  Downloaded: {total_dl / 1024 / 1024:.1f} MB")
    print(f"  Skipped (already existed): {total_skip}")
    print(f"  Failed: {total_fail}")
    print(f"{'='*60}")

    if total_fail:
        print("\n  WARNING: some files failed. Re-run the script to retry.", file=sys.stderr)
        sys.exit(1)


def main():
    parser = argparse.ArgumentParser(description="Pre-install Minecraft game files")
    parser.add_argument("--version", default="26.1.2", help="Minecraft version to install (default: 26.1.2)")
    parser.add_argument("--output", default=None, help="Target .minecraft directory (default: platform-dependent)")
    parser.add_argument("--platform", default="windows-x64", choices=list(PLATFORMS.keys()),
                        help="Target platform (default: windows-x64)")
    parser.add_argument("--workers", type=int, default=16, help="Concurrent download threads (default: 16)")
    args = parser.parse_args()

    if args.output:
        mc_dir = Path(args.output)
    elif sys.platform == "win32":
        mc_dir = Path(os.environ["APPDATA"]) / ".minecraft"
    elif sys.platform == "darwin":
        mc_dir = Path.home() / "Library" / "Application Support" / "minecraft"
    else:
        mc_dir = Path.home() / ".minecraft"

    install_version(args.version, mc_dir, args.platform, args.workers)


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Download files from one Hugging Face model repo at a pinned commit.

    python3 -I hf_fetch.py <repo> <commit> <dest_dir> [path_prefix ...]

Only files whose path starts with one of the prefixes are fetched (all files
when none is given). Every LFS file is checked against the SHA-256 that the
Hub lists for it; a mismatch deletes the file and exits non-zero. Files that
already exist with the right size are skipped. Standard library only.
"""
import hashlib
import json
import os
import sys
import urllib.request


def main() -> int:
    repo, commit, dest = sys.argv[1], sys.argv[2], sys.argv[3]
    prefixes = sys.argv[4:]
    tree_url = f"https://huggingface.co/api/models/{repo}/tree/{commit}?recursive=true"
    tree = json.load(urllib.request.urlopen(tree_url))
    files = [f for f in tree if f.get("type") == "file"]
    if prefixes:
        files = [f for f in files if any(f["path"].startswith(p) for p in prefixes)]
    total = 0
    for f in files:
        path = f["path"]
        lfs = f.get("lfs") or {}
        size = lfs.get("size", f.get("size", 0))
        want = lfs.get("oid")
        out = os.path.join(dest, path)
        os.makedirs(os.path.dirname(out), exist_ok=True)
        total += size
        if os.path.exists(out) and os.path.getsize(out) == size:
            print(f"skip {size:>14,}  {path}")
            continue
        url = f"https://huggingface.co/{repo}/resolve/{commit}/{path}"
        h = hashlib.sha256()
        with urllib.request.urlopen(url) as r, open(out + ".part", "wb") as w:
            while chunk := r.read(1 << 20):
                h.update(chunk)
                w.write(chunk)
        if want and h.hexdigest() != want:
            os.remove(out + ".part")
            print(f"SHA-256 MISMATCH {path}: {h.hexdigest()} != {want}", file=sys.stderr)
            return 1
        os.replace(out + ".part", out)
        print(f"got  {size:>14,}  {path}  {h.hexdigest()}")
    print(f"total {total:,} bytes in {len(files)} files from {repo}@{commit}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

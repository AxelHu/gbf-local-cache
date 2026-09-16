from __future__ import annotations

import argparse
import json
from pathlib import Path

from gbf_cache.core import CacheMeta, CacheStore, synthesized_headers, static_host_family


def main() -> None:
    parser = argparse.ArgumentParser(
        description=(
            "Migrate an existing primary cache into host-family scoped paths and "
            "the content-addressed hardlink pool. Legacy ACGPower roots are never touched."
        )
    )
    parser.add_argument("--root", required=True, type=Path)
    parser.add_argument("--apply", action="store_true", help="apply changes; default is dry-run")
    args = parser.parse_args()

    root = args.root.expanduser().resolve()
    store = CacheStore(root)
    migrated = relinked = skipped = bad = 0
    bytes_processed = 0

    meta_files = [p for p in root.rglob("*.ext") if ".objects" not in p.parts]
    for meta_path in meta_files:
        body_path = Path(str(meta_path)[:-4])
        if not body_path.is_file():
            skipped += 1
            continue
        try:
            data = json.loads(meta_path.read_text(encoding="utf-8-sig"))
            meta = CacheMeta.from_dict(data)
        except (OSError, ValueError, UnicodeError):
            bad += 1
            continue
        if not meta.url or not meta.md5 or not static_host_family(meta.host or ""):
            skipped += 1
            continue
        entry = store._load(body_path, "primary")
        if entry is None or not store.verify(entry):
            bad += 1
            continue

        target = store.primary_path(meta.url)
        if target is None:
            skipped += 1
            continue
        bytes_processed += entry.size
        if not args.apply:
            if target != body_path:
                migrated += 1
            else:
                relinked += 1
            continue

        raw = body_path.read_bytes()
        headers = synthesized_headers(meta, meta.host or "", None)
        new_entry = store.store(meta.url, raw, headers, now=meta.at or None)
        # Preserve any safe headers that were present in the existing metadata.
        new_entry.meta.headers.update(meta.headers)
        new_entry.meta.etag = meta.etag
        new_entry.meta.last_modified = meta.last_modified
        new_entry.meta.cache_control = meta.cache_control
        new_entry.meta.content_encoding = meta.content_encoding
        new_entry.meta.content_type = meta.content_type
        new_entry.meta.md5 = meta.md5
        new_entry.meta.at = meta.at
        new_entry.meta_path.write_text(
            json.dumps(new_entry.meta.to_dict(), ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8",
        )
        if not store.verify(new_entry):
            raise RuntimeError(f"migrated entry failed verification: {new_entry.body_path}")

        if target != body_path:
            body_path.unlink(missing_ok=True)
            meta_path.unlink(missing_ok=True)
            migrated += 1
        else:
            relinked += 1

    mode = "applied" if args.apply else "dry-run"
    print(
        f"{mode}: migrated={migrated} relinked={relinked} skipped={skipped} "
        f"bad={bad} bytes={bytes_processed}"
    )


if __name__ == "__main__":
    main()

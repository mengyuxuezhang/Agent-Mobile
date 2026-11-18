"""Extract the reviewable Android source baseline from an upstream GitHub ZIP."""

import argparse
from pathlib import Path, PurePosixPath
import shutil
import stat
from zipfile import ZipFile


EXCLUDED = (
    "site/", "market/", "services/", "infra/", ".github/",
    "app/ios/", "app/ohos/", "app/assets/brand/", "app/assets/pets/",
    "app/assets/star/", "app/assets/whale/", "app/tool/pet_src/",
    "app/tool/whale_src/", "docs/assets/",
    "app/android/app/src/main/res/drawable-nodpi/companion_widget_",
)
MEDIA = {".png", ".jpg", ".jpeg", ".webp", ".gif", ".zip"}


def include(path: str) -> bool:
    if path.startswith(EXCLUDED) or path.endswith("/brand_glyph.g.dart"):
        return False
    if "/res/" in path and ("/mipmap-" in path or "/ic_launcher" in path):
        return False
    return not (path.startswith("app/test/") and PurePosixPath(path).suffix.lower() in MEDIA)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("archive", type=Path)
    parser.add_argument("destination", type=Path)
    args = parser.parse_args()
    root = args.destination.resolve()
    root.mkdir()
    with ZipFile(args.archive) as source:
        for entry in source.infolist():
            _, _, path = entry.filename.partition("/")
            mode = entry.external_attr >> 16
            if entry.is_dir() or stat.S_ISLNK(mode) or not include(path):
                continue
            target = (root / path).resolve()
            if not target.is_relative_to(root):
                raise ValueError(f"ZIP entry leaves destination: {path}")
            target.parent.mkdir(parents=True, exist_ok=True)
            with source.open(entry) as data, target.open("xb") as output:
                shutil.copyfileobj(data, output)
            if mode & 0o111:
                target.chmod(0o755)


if __name__ == "__main__":
    main()

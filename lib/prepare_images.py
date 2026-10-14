"""Copy, orient and resize dataset images.

Called by New-LoraDataset.ps1 with a JSON job on stdin and a JSON result on
stdout, so the wizard stays in PowerShell while the imaging runs where image
libraries actually are.

This replaces System.Drawing, which is Windows-only in .NET 6+ and neither
applies nor preserves EXIF orientation. Pillow does both, which is why eight
of the twenty-four images in the sample set used to come out sideways.

Input (stdin):
    {"jobs": [{"source": "...", "destination": "...", "long_edge": 1024}, ...],
     "jpeg_quality": 95}

Output (stdout):
    {"results": [{"source": "...", "status": "resized|rotated|copied|failed",
                  "width": 1024, "height": 768, "error": null}, ...]}
"""

import json
import shutil
import sys
from pathlib import Path

from PIL import Image, ImageOps

# Formats written as JPEG have no alpha channel to preserve.
JPEG_SUFFIXES = {".jpg", ".jpeg"}


def _save(image: Image.Image, destination: Path, quality: int) -> None:
    suffix = destination.suffix.lower()
    if suffix in JPEG_SUFFIXES:
        if image.mode not in ("RGB", "L"):
            image = image.convert("RGB")
        image.save(destination, "JPEG", quality=quality, optimize=True)
    elif suffix == ".png":
        image.save(destination, "PNG", optimize=True)
    elif suffix == ".webp":
        image.save(destination, "WEBP", quality=quality)
    else:
        image.save(destination)


def prepare(source: str, destination: str, long_edge: int, quality: int) -> dict:
    src, dst = Path(source), Path(destination)
    result = {"source": source, "status": "failed", "width": 0, "height": 0, "error": None}

    try:
        with Image.open(src) as opened:
            # Bake the EXIF rotation into the pixels. Trainers read images with
            # Pillow, which does not apply the tag on load, so a rotated photo
            # copied verbatim would be trained on sideways.
            oriented = ImageOps.exif_transpose(opened)
            rotated = oriented.size != opened.size or oriented is not opened

            long_now = max(oriented.size)
            needs_resize = long_edge > 0 and long_now > long_edge
            needs_convert = src.suffix.lower() != dst.suffix.lower()

            if not (needs_resize or needs_convert or rotated):
                shutil.copy2(src, dst)
                result.update(status="copied", width=oriented.width, height=oriented.height)
                return result

            if needs_resize:
                scale = long_edge / long_now
                size = (max(1, round(oriented.width * scale)), max(1, round(oriented.height * scale)))
                oriented = oriented.resize(size, Image.LANCZOS)
                status = "resized"
            else:
                status = "rotated" if rotated else "copied"

            _save(oriented, dst, quality)
            result.update(status=status, width=oriented.width, height=oriented.height)
            return result

    except Exception as exc:  # noqa: BLE001 - reported per image, never fatal
        # One unreadable file must not discard a whole batch.
        try:
            shutil.copy2(src, dst)
            result.update(status="copied", error=f"{type(exc).__name__}: {exc}")
        except Exception as copy_exc:  # noqa: BLE001
            result["error"] = f"{type(copy_exc).__name__}: {copy_exc}"
        return result


def probe(path: str) -> dict:
    """Report the size a viewer would show, i.e. after EXIF rotation."""
    try:
        with Image.open(path) as opened:
            oriented = ImageOps.exif_transpose(opened)
            return {"source": path, "width": oriented.width, "height": oriented.height, "error": None}
    except Exception as exc:  # noqa: BLE001
        return {"source": path, "width": 0, "height": 0, "error": str(exc)}


def main() -> int:
    request = json.load(sys.stdin)

    if request.get("probe"):
        json.dump({"results": [probe(p) for p in request["probe"]]}, sys.stdout)
        return 0

    quality = int(request.get("jpeg_quality", 95))
    results = [
        prepare(job["source"], job["destination"], int(job.get("long_edge", 0)), quality)
        for job in request.get("jobs", [])
    ]
    json.dump({"results": results}, sys.stdout)
    return 0


if __name__ == "__main__":
    sys.exit(main())

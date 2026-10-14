"""Caption images in this process, with no captioning service involved.

Used by the 'local' provider. Downloads a quantised vision model once and runs
it through llama-cpp-python, which ships prebuilt wheels, so nothing needs a
compiler, a container, or a separately installed service.

Protocol: a JSON request on stdin, a JSON response on stdout, so PowerShell
drives it the same way it drives prepare_images.py.

    {"action": "models"}
        -> {"models": [{"key", "label", "size_gb", "note"}, ...]}

    {"action": "ensure", "model": "qwen2.5-vl-3b"}
        -> {"ok": true, "model_path": "...", "mmproj_path": "..."}

    {"action": "caption", "model": "...", "prompt": "...",
     "images": ["/path/a.jpg", ...], "max_tokens": 160, "temperature": 0.2}
        -> {"results": [{"image", "caption", "error"}, ...]}

The model stays loaded for the whole batch, so a run pays the load cost once.
"""

import base64
import contextlib
import json
import os
import sys

# Quantised builds chosen for a usable quality-to-download ratio. mmproj is the
# vision projector and is required alongside the language weights.
MODELS = {
    "smolvlm-500m": {
        "label": "SmolVLM 500M",
        "repo": "ggml-org/SmolVLM-500M-Instruct-GGUF",
        "model": "SmolVLM-500M-Instruct-Q8_0.gguf",
        "mmproj": "mmproj-SmolVLM-500M-Instruct-Q8_0.gguf",
        "size_gb": 0.55,
        "note": "Smallest and fastest. Short, plain captions.",
    },
    "qwen2.5-vl-3b": {
        "label": "Qwen2.5-VL 3B",
        "repo": "ggml-org/Qwen2.5-VL-3B-Instruct-GGUF",
        "model": "Qwen2.5-VL-3B-Instruct-Q4_K_M.gguf",
        "mmproj": "mmproj-Qwen2.5-VL-3B-Instruct-Q8_0.gguf",
        "size_gb": 2.77,
        "note": "Good balance of quality and size (recommended).",
    },
    "qwen2.5-vl-7b": {
        "label": "Qwen2.5-VL 7B",
        "repo": "ggml-org/Qwen2.5-VL-7B-Instruct-GGUF",
        "model": "Qwen2.5-VL-7B-Instruct-Q4_K_M.gguf",
        "mmproj": "mmproj-Qwen2.5-VL-7B-Instruct-Q8_0.gguf",
        "size_gb": 5.54,
        "note": "Best captions. Slow without a GPU.",
    },
}

DEFAULT_MODEL = "qwen2.5-vl-3b"

# Longest edge sent to the model. A vision encoder tiles the image into a fixed
# grid, so a 3000px photo costs several times what a 1024px one does and tells
# it nothing extra about pose, clothing or setting. Captioning full-resolution
# photos was the single biggest cost in a local run.
CAPTION_MAX_EDGE = 1024


def _encode_for_vision(path, max_edge):
    """Return a data URI holding the image, downscaled for the encoder."""
    import io

    from PIL import Image, ImageOps

    with Image.open(path) as opened:
        # The same EXIF rotation the dataset images get, so the model is not
        # captioning a sideways photo.
        image = ImageOps.exif_transpose(opened)
        if max_edge > 0 and max(image.size) > max_edge:
            scale = max_edge / max(image.size)
            image = image.resize(
                (max(1, round(image.width * scale)), max(1, round(image.height * scale))),
                Image.LANCZOS,
            )
        if image.mode not in ("RGB", "L"):
            image = image.convert("RGB")

        buffer = io.BytesIO()
        image.save(buffer, "JPEG", quality=90)

    return "data:image/jpeg;base64," + base64.b64encode(buffer.getvalue()).decode()


@contextlib.contextmanager
def _quiet_native():
    """Silence llama.cpp's own logging for the duration of a block.

    verbose=False only quiets the Python wrapper. The native library writes
    directly to file descriptor 2, including the entire prompt on every call,
    which buried the tool's own output. Redirecting the descriptor is the only
    thing that stops it, so it is swapped out and restored around the noisy
    calls while this script's progress lines still reach the real stderr.
    """
    saved = os.dup(2)
    devnull = os.open(os.devnull, os.O_WRONLY)
    try:
        sys.stderr.flush()
        os.dup2(devnull, 2)
        yield
    finally:
        os.dup2(saved, 2)
        os.close(devnull)
        os.close(saved)


def _fail(message):
    json.dump({"ok": False, "error": message}, sys.stdout)
    return 1


def ensure(key, cache_dir=None):
    """Download the weights if they are not cached, and report their paths."""
    from huggingface_hub import hf_hub_download

    spec = MODELS[key]
    kwargs = {"cache_dir": cache_dir} if cache_dir else {}
    return {
        "ok": True,
        "model_path": hf_hub_download(spec["repo"], spec["model"], **kwargs),
        "mmproj_path": hf_hub_download(spec["repo"], spec["mmproj"], **kwargs),
    }


def _load(key, cache_dir, n_gpu_layers):
    from llama_cpp import Llama
    from llama_cpp.llama_chat_format import MTMDChatHandler

    paths = ensure(key, cache_dir)
    with _quiet_native():
        handler = MTMDChatHandler(clip_model_path=paths["mmproj_path"], verbose=False)
        llm = Llama(
            model_path=paths["model_path"],
            chat_handler=handler,
            n_ctx=4096,
            # -1 offloads every layer to the GPU when the build supports one; a
            # CPU build ignores it, so the same value is safe either way.
            n_gpu_layers=n_gpu_layers,
            verbose=False,
        )
    return llm


def caption(request):
    key = request.get("model", DEFAULT_MODEL)
    if key not in MODELS:
        return _fail(f"Unknown model '{key}'. Choices: {', '.join(MODELS)}")

    prompt = request["prompt"]
    images = request.get("images", [])
    max_tokens = int(request.get("max_tokens", 160))
    temperature = float(request.get("temperature", 0.2))

    llm = _load(key, request.get("cache_dir"), int(request.get("n_gpu_layers", -1)))

    max_edge = int(request.get("max_edge", CAPTION_MAX_EDGE))

    results = []
    for path in images:
        entry = {"image": path, "caption": "", "error": None}
        try:
            uri = _encode_for_vision(path, max_edge)

            with _quiet_native():
                out = llm.create_chat_completion(
                    messages=[{
                        "role": "user",
                        "content": [
                            {"type": "image_url", "image_url": {"url": uri}},
                            {"type": "text", "text": prompt},
                        ],
                    }],
                    max_tokens=max_tokens,
                    temperature=temperature,
                )
            entry["caption"] = out["choices"][0]["message"]["content"].strip()
        except Exception as exc:  # noqa: BLE001 - reported per image, never fatal
            # One unreadable image must not discard the captions already earned.
            entry["error"] = f"{type(exc).__name__}: {exc}"

        results.append(entry)
        # Progress goes to stderr so stdout stays a single JSON document.
        print(f"captioned {len(results)}/{len(images)}", file=sys.stderr, flush=True)

    json.dump({"ok": True, "results": results}, sys.stdout)
    return 0


def main():
    request = json.load(sys.stdin)
    action = request.get("action", "caption")

    if action == "models":
        listing = [
            {"key": k, "label": v["label"], "size_gb": v["size_gb"], "note": v["note"]}
            for k, v in MODELS.items()
        ]
        json.dump({"ok": True, "models": listing, "default": DEFAULT_MODEL}, sys.stdout)
        return 0

    if action == "ensure":
        key = request.get("model", DEFAULT_MODEL)
        if key not in MODELS:
            return _fail(f"Unknown model '{key}'. Choices: {', '.join(MODELS)}")
        json.dump(ensure(key, request.get("cache_dir")), sys.stdout)
        return 0

    if action == "caption":
        return caption(request)

    return _fail(f"Unknown action '{action}'")


if __name__ == "__main__":
    sys.exit(main())

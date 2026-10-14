# Architecture

## Goals

- A repeatable local pipeline from raw photos to a training-ready dataset.
- No dependence on any single captioning model.
- Everything local: no images or captions leave the machine.
- Containerised where a container earns its keep.

## Components

### `lib/Captioners.psm1`

The core module, and the only place caption text is produced or transformed.
`Get-ImageCaption` is the single entry point; everything else is a helper it
composes. Keeping this logic in a module rather than in the CLI script is what
makes it unit-testable without a GPU, a network call or a container.

Provider dispatch:

```
Get-ImageCaption -Provider ollama    -> Build-CaptionPrompt -> Invoke-OllamaCaption
                                                            -> Remove-CaptionPreamble

Get-ImageCaption -Provider florence  -> Invoke-FlorenceCaption
                                     -> Remove-CaptionPreamble
                                     -> Set-CaptionSubject
                                     -> Limit-CaptionContent
```

The asymmetry is the point. An instructed model receives the rules up front and
needs almost no cleanup. Florence-2 cannot be instructed, so the same rules have
to be reapplied afterwards by hand - which is both lossier and where the
pipeline's bugs historically lived.

Both paths finish by normalising the trigger word to one spelling and guaranteeing
it appears at least once.

### Captioning providers

| Provider | Transport | Runs in |
|---|---|---|
| `ollama` | `POST /api/generate`, image as base64 | Ollama (host or container), port 11434 |
| `florence` | `POST /caption`, multipart upload | `docker/` FastAPI container, port 8080 |

Adding a provider means adding an `Invoke-<Name>Caption` function and a branch in
`Get-ImageCaption`; nothing else in the pipeline changes.

Reasoning models are called with `think` disabled. Left on, the chain of thought
is prepended to the caption; `Remove-CaptionPreamble` strips a surviving
`<think>` block as a backstop.

### `caption.ps1`

A thin CLI over the module: resolve and sort the images, check the chosen provider
is reachable, loop, validate, write. It holds no caption logic.

Per-image failures are caught and recorded rather than thrown, so one unreadable
file cannot discard the captions already produced in a long run.

### Review UI

`review_ui.py` is a small Gradio app that steps through the dataset, showing each
image with its caption in an editable box. Every navigation action saves, so there
is no unsaved state to lose.

`run-review-ui.ps1` runs it on the host by default, in a virtual environment it
creates once under `.venv_review`, and runs the export step when the UI exits.
Nothing here needs a container: the app reads and writes local files and serves
a local port.

`-Docker` runs the same script in a container instead, for machines with no
Python. That path mounts the dataset at `/data`, so the UI resolves images by
filename against the mount point rather than by the Windows paths stored in
`captions.json`.

The container sees Linux paths while `captions.json` stores Windows paths, so
images are resolved by filename against the mount point. This keeps the JSON
portable: the stored path is never rewritten.

### Orchestration

`New-LoraDataset.ps1` is the guided front door: it collects concept details, copies and
optionally resizes source images into the `<rate>_<concept>` layout kohya_ss
expects, then calls caption -> review -> export. It stops at the point training
would begin.

## Data flow

1. Images are copied (optionally resized) into the dataset folder.
2. `caption.ps1` captions every image and writes `captions.json` / `captions.csv`.
3. Validation flags empty, over/under-length and near-duplicate captions.
4. The review UI is used to correct anything wrong; each edit saves immediately.
5. `export-captions.ps1` writes one `<image>.txt` per image.
6. kohya_ss trains from the folder.

## Testing

`tests/Captioners.Tests.ps1` covers the module. The provider functions are mocked,
so the suite needs no GPU, model or network and runs in about a second on both
Windows and Linux.

Cases marked `REGRESSION` encode defects that were shipping, and use real recorded
model output rather than invented strings.

## Ports

| Service | Port |
|---|---|
| Ollama | 11434 |
| Florence-2 API | 8080 (`FLORENCE_PORT`) |
| Review UI | 7861 (`-Port`) |

## Configuration

`docker/.env` (see `.env.example`) holds model cache locations and the Florence
port. The caches are large and shared between projects, so they live outside the
repo; the compose file otherwise uses paths relative to itself so the repo can be
cloned anywhere.

## See also

- [../README.md](../README.md) - what the tool does, and setup
- [WORKFLOW.md](WORKFLOW.md) - the end-to-end flow
- [DECISIONS.md](DECISIONS.md) - every wizard question and what it changes

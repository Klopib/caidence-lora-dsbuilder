# LoRA Dataset Builder

Local, GPU-accelerated tooling that turns a folder of raw photos into a captioned,
reviewed, training-ready LoRA dataset on Windows.

Captioning runs behind a pluggable provider interface, so the pipeline is not tied
to one vision model. Everything runs locally: no images or captions leave the machine.

```
source images (read-only)
      |  copy
      v
 dataset folder  ->  caption  ->  review & edit  ->  export  ->  kohya_ss
                        |              |                |
                 captions.json   captions.csv      <image>.txt
```

Source images are never written to. They are copied into a dataset folder and
captioned there, so a run can always be repeated from the untouched originals.

## Why the provider interface

The original pipeline was built around Florence-2, which cannot take instructions.
To get training-shaped captions out of it, the code post-processed its prose with
regular expressions: substituting the subject noun, stripping background clauses,
flattening to tags. That layer was the single largest source of bugs in the repo
(see [Known issues fixed](#known-issues-fixed)).

An instruction-following vision model makes that layer unnecessary. The captioning
rules travel in the prompt, and the model returns text already in the right shape:

| | Florence-2 | Instructed VLM (Ollama) |
|---|---|---|
| Takes instructions | No | Yes |
| Caption rules enforced by | regex post-processing | the prompt |
| Skips fixed identity traits | No | Yes |
| Typical speed (RTX 4090) | ~3-6 s/image | ~1-3 s/image |
| Needs a bespoke container | Yes (CUDA + pinned transformers) | No |

Florence-2 is kept as a second provider: it is fully offline, has no model-pull
step once cached, and is a useful fallback when Ollama is not running.

## Requirements

- Windows 10/11, PowerShell 7+ (`pwsh`)
- Docker Desktop (Linux containers)
- NVIDIA GPU recommended
- A captioning backend — either of:
  - **Ollama** (default) with any vision-capable model installed
  - **Florence-2**, which needs nothing extra: `caption.ps1` starts the container

## Choosing a captioning backend

Two providers ship with the tool. Neither is required in advance — pick whichever
suits what you already have.

### Ollama (default)

Any model that reports Ollama's `vision` capability works. You do **not** need a
specific one. If you already have a vision model, the tool finds and uses it:

```powershell
./caption.ps1 -ImageDir .\photos\mikey -Concept mikey
#   No -Model given; looking for an installed vision model ...
#   Using model minicpm-v:latest.
```

To see which of your models can caption images:

```powershell
ollama list
# then, for any model:
(Invoke-RestMethod -Method Post -Uri http://localhost:11434/api/show `
    -Body '{"model":"<name>"}').capabilities
# a model usable here reports: vision
```

Pin a specific model when you want one:

```powershell
./caption.ps1 -ImageDir .\photos\mikey -Concept mikey -Model llava:13b
```

Naming a text-only model is refused up front, with your vision-capable models
listed, rather than silently captioning nothing.

If you have no vision model yet, any of these work — `qwen3.5` is what the
project was developed against:

```powershell
ollama pull qwen3.5            # ~6GB, strong detail, follows instructions well
ollama pull llava              # ~5GB, widely available
ollama pull moondream          # ~1.7GB, smallest, fastest
```

Auto-selection order is `qwen3.5`, `qwen3-vl`, `qwen2.5vl`, `llama3.2-vision`,
`minicpm-v`, `moondream`, `llava`, then any other vision model installed.
Override it with `$env:LORA_CAPTION_MODELS` (comma-separated).

### Florence-2

A self-contained container, useful when you would rather not run Ollama or need
a fully offline fallback:

```powershell
./caption.ps1 -ImageDir .\photos\mikey -Concept mikey -Provider florence
```

Florence-2 cannot take instructions, so its captions are normalised afterwards
by rule rather than shaped by a prompt. Expect lower quality: it describes fixed
identity traits regardless, and hallucinates detail more readily. See
[Why the provider interface](#why-the-provider-interface).

## Quickstart

Caption a folder of photos. This builds `./datasets/mikey` and leaves the source
folder untouched:

```powershell
./caption.ps1 -ImageDir .\photos\mikey -Concept mikey
```

Review and edit the captions in a browser, then export to `.txt`:

```powershell
./run-review-ui.ps1 -DatasetDir .\datasets\mikey -Concept mikey
```

Or run the whole guided flow, which also builds the `<rate>_<concept>` folder
structure kohya_ss expects:

```powershell
./New-LoraDataset.ps1
```

### Outputs

Written into the dataset folder, never into the source folder:

| File | Purpose |
|---|---|
| staged images | Copies of the source photos, the training set itself |
| `captions.json` | Full records: image path, raw model output, final caption |
| `captions.csv` | Same data, spreadsheet-friendly |
| `<image>.txt` | One caption per image, the format kohya_ss reads |
| `caption_issues.csv` | Only written when validation flags something |

## Captioning options

```powershell
# Tag-style captions for booru-trained base models (Pony, Illustrious)
./caption.ps1 -ImageDir .\data -Concept mikey -Tagify

# A non-character concept: describe the object instead of suppressing identity
./caption.ps1 -ImageDir .\data -Concept caftan -ConceptType clothing

# Offline fallback
./caption.ps1 -ImageDir .\data -Concept mikey -Provider florence

# Pin a specific model instead of auto-selecting one
./caption.ps1 -ImageDir .\data -Concept mikey -Model llava:13b

# Extra guidance, appended to the prompt
./caption.ps1 -ImageDir .\data -Concept mikey -Instruction "note the lighting direction"
```

### How captions are shaped

For `-ConceptType character`, the prompt tells the model to **leave out fixed
identity traits** - hair, beard, face shape, eye colour, age - and to describe only
what varies between shots: pose, expression, clothing, framing, lighting, background.

This is deliberate. The trigger word should absorb the subject's unchanging
appearance. Captioning "short dark hair" in every image teaches the model that the
hair is a variable worth re-specifying at generation time, which dilutes likeness.

The trigger word is also normalised to one spelling. `Mikey` and `mikey` are
different tokens, so a dataset split between them trains the concept onto both.

## Validation

After captioning, the set is checked for:

- empty captions
- captions that are too short or too long - measured in words for prose and in
  tags for `-Tagify`, since a 30-word prose caption legitimately has few commas
- near-duplicate captions (Jaccard similarity > 0.85), which signal that the model
  is emitting boilerplate rather than describing each image

Anything flagged lands in `caption_issues.csv`. A clean run writes no such file.

## Repository layout

```
lib/Captioners.psm1      Caption providers and post-processing (the core module)
tests/                   Pester tests, including regressions for fixed bugs
caption.ps1              Batch captioning CLI
review_ui.py             Gradio review UI
run-review-ui.ps1        Runs the review UI in Docker, then exports .txt files
export-captions.ps1      captions.json -> per-image .txt
New-LoraDataset.ps1             Guided end-to-end dataset preparation
start/stop/rebuild/logs  Florence-2 container lifecycle
docker/                  Florence-2 API image and compose file
docs/                    Architecture and workflow notes
```

## Development

```powershell
# Tests
Invoke-Pester ./tests

# Lint
Invoke-ScriptAnalyzer -Path . -Recurse -Settings ./PSScriptAnalyzerSettings.psd1
```

CI runs both on every push, plus `ruff` over the Python files and a build of the
review-UI image.

## Known issues fixed

These were live defects in the captioning path, each now covered by a regression
test in `tests/Captioners.Tests.ps1`:

- **Captions silently truncated.** Background filtering split captions on commas.
  Prose captions often contain one comma, so a single background word deleted
  everything after it - a five-sentence caption became `mikey has short`. The
  default instruction triggered this on every run.
- **Mangled grammar from pronoun substitution.** Every pronoun was rewritten to the
  trigger word, producing `mikey appears to be in mikey's late 30s` and
  `The mikey is wearing`. The subject is now named once and pronouns are left alone.
- **Inconsistent trigger capitalisation** split the concept across two tokens.
- **False validation flags.** Prose captions were measured in commas, flagging most
  of a healthy dataset.
- **`[regex]::Replace` with a count argument.** There is no such overload; the
  fourth argument is read as `RegexOptions`, so "replace the first match" silently
  replaced every match.
- **Dead code** in the Florence API (a duplicated unreachable `return`).
- **Hardcoded absolute paths and `pause`** in the container scripts, which broke
  both portability and unattended use.

## Troubleshooting

**`Cannot reach Ollama`** - start it with `docker start ollama`, or run Ollama for
Windows. Confirm with `curl http://localhost:11434/api/tags`.

**`Model 'x' is not installed in Ollama`** - `ollama pull <model>`. The error lists
what you do have.

**`Model 'x' cannot accept images`** - that model is text-only. The error lists your
vision-capable models; pass one with `-Model`, or omit `-Model` to auto-select.

**`No vision-capable model is installed`** - pull one (`ollama pull qwen3.5`,
`llava` or `moondream`), or use `-Provider florence`, which needs no model pull.

**Ollama is running but reports no models** - a host install and a container install
keep separate model stores. Check which one owns port 11434.

**Florence API not responding** - `./start.ps1 -Wait` blocks until the model has
loaded; first run downloads ~1.5GB of weights. Then `./logs.ps1`.

**Port already in use** - pass a different `-Port` to `run-review-ui.ps1`.

**Images not loading in the review UI** - the container mounts the dataset at
`/data` and resolves images by filename, so `captions.json` must sit in the same
folder as the images.

## License

MIT - see [LICENSE](LICENSE).

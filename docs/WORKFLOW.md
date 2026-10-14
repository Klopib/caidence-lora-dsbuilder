# Workflow

The end-to-end flow for building a LoRA dataset.

## 0) Pick a trigger word

A short, distinctive token that is not an ordinary English word, e.g. `mikey`.
It is used verbatim in every caption and is what you prompt with later.

## 1) Make sure a captioning provider is up

Default provider (Ollama). Any model reporting the `vision` capability works;
the tool auto-selects one, so this is only needed if you have none:

```powershell
docker start ollama          # or run Ollama for Windows
curl http://localhost:11434/api/tags

# Only if you have no vision model yet:
ollama pull qwen3.5          # or llava, moondream, minicpm-v ...
```

Fallback provider (Florence-2) - `caption.ps1` starts it automatically, or:

```powershell
./start.ps1 -Wait            # blocks until the model has loaded
```

## 2) Caption the folder

```powershell
./caption.ps1 -ImageDir .\photos\mikey -Concept mikey
```

Useful switches:

| Switch | Effect |
|---|---|
| `-Tagify` | Comma-separated tags instead of prose |
| `-ConceptType` | `character` (default), `clothing`, `style`, `object` |
| `-Provider florence` | Use the offline fallback, no model pull needed |
| `-Model` | Pin a specific Ollama model instead of auto-selecting |
| `-Instruction "..."` | Extra guidance appended to the prompt |
| `-Overwrite` | Re-caption even if `captions.json` exists |
| `-OutputDir` | Where the dataset is built (default `./datasets/<concept>`) |
| `-InPlace` | Caption an existing dataset folder directly, with no copy |

Choose the caption style to match the base model you will train on: tags for
booru-style models (Pony, Illustrious), prose for newer ones (Flux, SDXL).

## 3) Read `caption_issues.csv`

If it exists, the run flagged something. A clean run does not create the file.

| Flag | Usually means |
|---|---|
| `Empty caption` | The model returned nothing; re-run that image |
| `Word count` / `Tag count` | Caption is unusually short or long |
| `Too similar to ...` | Boilerplate rather than per-image description |

Near-duplicates matter most. If many captions are near-identical, the model is
describing its own template instead of the photo, and the dataset will teach the
template.

## 4) Review and edit

```powershell
./run-review-ui.ps1 -DatasetDir .\datasets\mikey -Concept mikey
```

Step through with `<<  <  >  >>`. Every navigation saves. Fix anything the model
got wrong - especially hallucinated detail, which is the failure mode that most
degrades a dataset.

Click **End Task** when finished. The UI shuts down and captions are exported to
`.txt` automatically.

## 5) Export (if needed)

Only required if you skipped the review UI:

```powershell
./export-captions.ps1 -CaptionsJson .\datasets\mikey\captions.json -Overwrite
```

## 6) Train

Point kohya_ss at the dataset folder. Each image now has a matching `.txt`.

## Guided alternative

`New-LoraDataset.ps1` runs all of the above interactively and also builds the
`<rate>_<concept>` folder structure kohya_ss expects:

```powershell
./New-LoraDataset.ps1
```

It prompts for concept name, type, source images and training rate, offers to
resize oversized images, then runs caption -> review -> export.

## Notes

- The source folder is read-only. Images are copied into the dataset folder and
  captioned there, so the dataset folder is self-contained and the originals can
  be re-run at any time.
- Override the dataset location with `-OutputDir`, or set `$env:LORA_DATASET_ROOT`
  to change the default root (otherwise `./datasets`).
- `captions.json` keeps both the raw model output and the final caption, so you
  can always see what the model said before post-processing.
- `run-review-ui.ps1` can reserve its port in a shared registry; set
  `$env:LORA_PORT_REGISTRY` to opt in. It is skipped by default.

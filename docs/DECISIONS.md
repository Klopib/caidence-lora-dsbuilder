# Decision guide

Every question `New-LoraDataset.ps1` asks, what it changes, and how to answer it.

Defaults are shown in brackets, exactly as the wizard shows them: `[Y]/n` means
Enter accepts yes. Nothing is written to disk until
[Proceed with dataset preparation](#proceed-with-dataset-preparation), so you can
cancel at any earlier point and lose nothing.

## The tree

```
1  Concept name                       free text
2  Concept type                       1 character | 2 clothing | 3 style | 4 object | 5 explain
3  Source image folder                path, or H for guidance
   |
   +- fewer than 15 images found      Continue anyway? [N]
   +- more than 100 images found      Continue with all? [Y]
4  Resize images?                     [N]
   +- if yes: target long edge        1 512px | 2 1024px | 3 custom
5  Training rate per image            number, or I for an explanation
6  Captioning backend
   |
   +- Ollama found ------------------ Use Ollama for captioning? [Y]
   |    +- if yes, 2+ vision models   1 auto | 2..n a specific model
   |    +- if no  -------------------\
   +- Ollama not found --------------> 1 set one up here
                                       2 Florence-2
                                       3 different Ollama address
                                       4 retry
                                       5 cancel
7  Change caption style or guidance?  [N]
   +- if yes: style                   1 prose | 2 tags
   +- if yes: extra guidance          free text, blank for none
8  Proceed with dataset preparation?  [Y]
   +- dataset already exists          Keep the existing one (timestamped)? [Y]
9  Review UI                          edit captions, then End Task
10 Open dataset folder in Explorer?   [Y]
```

---

## 1. Concept name

**What it is.** The thing you are teaching the model, and the **trigger word**
you will put in prompts later. Train `mikey`, then prompt
`mikey, standing in a kitchen, soft window light`.

**How to choose.** Short, distinctive, and not a word the base model already has
strong ideas about. `mikey` and `rf1` are good; `red fox` is bad, because the
model will pull in everything it knows about foxes and the colour red. Use
underscores instead of spaces.

The spelling must be identical in every caption; the tool enforces that for you,
including capitalisation. See
[choosing a trigger word](https://offlinecreator.com/guide/lora-trigger-word-guide).

## 2. Concept type

**What it changes.** Two things: the suggested training rate, and how captions
are written.

| Choice | Suggested rate | Captioning behaviour |
|---|---|---|
| 1 Character/Person | 12 | Fixed identity traits are **left out** of captions |
| 2 Clothing/Fashion | 6 | The garment is described in detail |
| 3 Art Style | 10 | Content is described; style is carried by the trigger |
| 4 Object/Item | 7 | The object is described in detail |

**Why character is different.** For a person, the captioner is told *not* to
mention hair, beard, face shape or age. Those never change between photos, so
they belong to the trigger word. Captioning them teaches the model they are
variable details worth re-specifying, which dilutes the likeness.

Option 5 prints a longer explanation and returns to this question.

## 3. Source image folder

**What it is.** A folder of photos. Mixed filenames, sizes and orientations are
fine. Subfolders are included.

**This folder is only read from.** Images are copied into a new dataset folder
and captioned there, so you can re-run as often as you like from the same
originals. Type `H` for guidance on picking good images.

### Fewer than 15 images — `Continue anyway? [N]`

A small set limits how well the concept generalises; the model tends to
reproduce the exact poses and lighting it saw. 20+ is a reasonable floor,
25–40 diverse shots is a good target. Answer `y` to proceed regardless.

Note this one defaults to **no**, so an unattended run with `-Yes` stops here
rather than quietly building a weak dataset.

### More than 100 images — `Continue with all? [Y]`

More is not automatically better. A large set of near-identical photos mostly
adds training time, and inflates whatever bias the set already has. Answer `n`
to go and curate first.

## 4. Resize images

**`Resize images? [N]`** then, if yes, a target for the **longest edge**:

| Choice | Long edge | When |
|---|---|---|
| 1 | 512px | SD 1.5-era base models; smallest and fastest |
| 2 | 1024px | SDXL, Flux and most current models |
| 3 | custom | Anything else |

Only images **larger** than the target are touched; smaller ones are copied
unchanged, so this never upscales. Aspect ratio is preserved.

**How to choose.** Match your base model's native resolution. Training on images
far larger wastes time and VRAM, since the trainer downscales them anyway.

## 5. Training rate per image

**What it is.** How many times each image is shown per epoch, which the folder
name encodes (`12_mikey` means 12 repeats). Total steps per epoch is
`images x rate`, and the wizard shows that figure as you choose.

**How to choose.** Start with the suggestion for your concept type. Raise it for
a small set, lower it for a large one — the aim is a sensible total step count,
not a particular repeat number. A 24-image set at rate 5 gives 120 steps per
epoch; the same set at 12 gives 288.

Type `I` for a longer explanation and return to the question.

## 6. Captioning backend

The wizard checks what is available before asking anything, so this step depends
on what it finds.

### Ollama found — `Use Ollama for captioning? [Y]`

It lists the vision-capable models you have. Say yes unless you specifically
want a different backend.

**Which model?** Asked only when you have two or more. `1 Auto-select` is
recommended and prefers known-good models. Only models that actually report the
`vision` capability are offered — a text-only model would silently ignore your
images and caption from the prompt alone.

### Ollama not found, or declined

| Option | What happens | When to pick it |
|---|---|---|
| 1 Set one up here | Downloads a vision model and runs it in Docker | You have no Ollama. Needs only Docker |
| 2 Florence-2 | Starts the bundled container, offers to launch it | You want no model download, and accept lower quality |
| 3 Different Ollama address | Prompts for a host/port | Ollama runs on another port or machine |
| 4 Retry | Re-checks | You just started Ollama in another window |
| 5 Cancel | Exits, nothing written | — |

**Option 1 model sizes:** `qwen3.5:4b` ~3.5GB (default), `qwen3.5:2b` ~2.9GB,
`qwen3.5:9b` ~7GB, `qwen2.5vl:3b` ~3.2GB, `moondream` ~1.7GB. Downloaded once
into a Docker volume. An Ollama you already run is never modified.

**Why this is checked up front.** Nothing downstream works without a captioner,
and images are copied before captioning starts. Confirming the connection here
means a dead backend costs you nothing.

## 7. Caption style and guidance

**`Change caption style or guidance? [N]`** — the defaults suit most runs.

### Style

| Choice | Output | For |
|---|---|---|
| 1 Prose clauses | `mikey in a blue t-shirt, seated, soft window light` | Flux, SDXL, Qwen Image |
| 2 Comma tags | `mikey, blue t-shirt, seated, soft lighting` | Booru-trained models: Pony, Illustrious |

**Match your base model.** A model trained on tags responds to tags; one trained
on natural language responds to sentences.

### Extra guidance

Free text appended to the captioner's instructions, for anything the defaults do
not cover — `note the lighting direction`, `mention the camera angle`. Leave
blank for none. Ignored by Florence-2, which cannot take instructions.

## Proceed with dataset preparation?

**`[Y]`** — the summary above it lists everything that will happen and where the
output goes. **This is the first point at which anything is written.** Answering
`n` exits having created nothing.

### Dataset already exists — `Keep the existing one (timestamped)? [Y]`

The target folder is already there from an earlier run.

- **Yes** renames the old folder with its creation timestamp, e.g.
  `12_mikey_2026-03-04_11-20-05`, and builds fresh. Nothing is lost.
- **No** deletes it and starts over.

Default is yes. Captions you spent time correcting are expensive to recreate.

## 9. Review UI

Not a prompt but a decision point: the wizard opens a browser UI at
`http://127.0.0.1:7861` and **waits**.

Step through with `<<  <  >  >>` and correct anything wrong. Every navigation
action saves, so there is no unsaved state. Click **End Task** when done; the UI
shuts down and the pipeline exports the `.txt` files.

**What to look for.** Hallucinated detail above all — a confidently wrong
caption teaches the model something false. Also watch for the same phrasing
repeating across images, which trains the phrasing rather than the subject.
`caption_issues.csv` flags near-duplicates and other problems if any were found.

Skipping review is possible but rarely wise; it is the step that takes a dataset
from automatic to good.

## 10. Open dataset folder in Explorer?

**`[Y]`** — cosmetic. The path is printed either way.

---

## Running without prompts

`-Yes` accepts every default and runs unattended, for scripting or repeat runs:

```powershell
./New-LoraDataset.ps1 -Yes -ConceptName mikey -ConceptType character `
    -SourceImagesPath .\photos\mikey -TrainingRate 10
```

The values with no default must be supplied as parameters. Two behaviours to
know:

- The **fewer than 15 images** guard defaults to *no*, so a small set stops the
  run. That is deliberate: an unattended run should not quietly build a dataset
  you were warned about.
- A missing captioning backend is an error rather than a prompt, since there is
  nothing to fall back to.

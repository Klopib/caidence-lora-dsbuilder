import io
import os

import torch
from fastapi import FastAPI, File, Form, HTTPException, UploadFile
from PIL import Image
from transformers import AutoModelForCausalLM, AutoProcessor

MODEL_ID = os.getenv("FLORENCE_MODEL_ID", "microsoft/Florence-2-base")
DEFAULT_TASK = "<CAPTION>"
DEVICE = "cuda" if torch.cuda.is_available() else "cpu"
DTYPE = torch.float16 if DEVICE == "cuda" else torch.float32

app = FastAPI(title="Florence-2 API", version="1.0.0")

processor = AutoProcessor.from_pretrained(MODEL_ID, trust_remote_code=True)
model = AutoModelForCausalLM.from_pretrained(
    MODEL_ID,
    torch_dtype=DTYPE,
    trust_remote_code=True,
).to(DEVICE)
model.eval()

@app.get("/health")
def health() -> dict:
    return {"status": "ok", "model_id": MODEL_ID, "device": DEVICE}


@app.post("/caption")
async def caption(file: UploadFile = File(...), task: str = Form(DEFAULT_TASK)) -> dict:
    try:
        payload = await file.read()
        image = Image.open(io.BytesIO(payload)).convert("RGB")
    except Exception as ex:
        raise HTTPException(status_code=400, detail=f"Invalid image: {ex}")

    inputs = processor(text=task, images=image, return_tensors="pt")
    # Keep tensor dtypes aligned with the loaded model (fp16 on CUDA, fp32 on CPU).
    cast_inputs = {}
    for key, value in inputs.items():
        if torch.is_floating_point(value):
            cast_inputs[key] = value.to(device=DEVICE, dtype=DTYPE)
        else:
            cast_inputs[key] = value.to(device=DEVICE)
    inputs = cast_inputs

    generated_ids = model.generate(
        input_ids=inputs["input_ids"],
        pixel_values=inputs["pixel_values"],
        max_new_tokens=256,
        do_sample=False,
        num_beams=3,
    )

    generated_text = processor.batch_decode(generated_ids, skip_special_tokens=False)[0]
    parsed = processor.post_process_generation(generated_text, task=task, image_size=image.size)

    return {
        "model_id": MODEL_ID,
        "task": task,
        "result": parsed,
    }

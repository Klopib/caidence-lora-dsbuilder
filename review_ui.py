import argparse
import csv
import json
import os
import time
import threading

import inspect

import gradio as gr

DATA = []
JSON_PATH = ""
CSV_PATH = ""
DATA_DIR = ""

# Display height of the review image, in pixels.
IMAGE_HEIGHT = 480


def schedule_exit(delay=0.5):
    def _exit_later():
        time.sleep(delay)
        os._exit(0)

    t = threading.Thread(target=_exit_later, daemon=True)
    t.start()


def load_captions(json_path: str):
    with open(json_path, "r", encoding="utf-8") as f:
        data = json.load(f)
    # Ensure keys exist
    for item in data:
        item.setdefault("raw_caption", "")
        item.setdefault("final_caption", item.get("raw_caption", ""))
    return data


def save_files(data, json_path, csv_path):
    with open(json_path, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
    with open(csv_path, "w", encoding="utf-8", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=["image", "raw_caption", "final_caption"])
        writer.writeheader()
        for row in data:
            writer.writerow(
                {
                    "image": row.get("image", ""),
                    "raw_caption": row.get("raw_caption", ""),
                    "final_caption": row.get("final_caption", ""),
                }
            )


def clamp_index(idx, length):
    if length == 0:
        return 0
    return max(0, min(idx, length - 1))


def get_record(idx):
    if not DATA:
        return None, 0
    idx = clamp_index(idx, len(DATA))
    return DATA[idx], idx


def progress_text(idx):
    n = len(DATA)
    if n == 0:
        return "No records"
    return f"**{idx + 1} / {n}**"


def display_path(path_value: str):
    if not path_value:
        return path_value
    if os.path.isabs(path_value) and os.path.exists(path_value):
        return path_value
    # Windows path inside container -> map to mounted /data by filename
    filename = os.path.basename(path_value.replace("\\", "/"))
    candidate = os.path.join(DATA_DIR, filename)
    return candidate


def nav(direction, caption_text, idx):
    if not DATA:
        return (
            None,
            "",
            "No records",
            "Nothing to save",
            idx,
            gr.update(interactive=False),
            gr.update(interactive=False),
            gr.update(interactive=False),
            gr.update(interactive=False),
            gr.update(interactive=False),
        )

    # Save current caption
    rec, idx = get_record(idx)
    rec["final_caption"] = caption_text.strip()
    save_files(DATA, JSON_PATH, CSV_PATH)

    if direction == "next":
        idx = clamp_index(idx + 1, len(DATA))
    elif direction == "prev":
        idx = clamp_index(idx - 1, len(DATA))
    elif direction == "first":
        idx = 0
    elif direction == "last":
        idx = len(DATA) - 1
    elif direction == "end":
        status = "Session ended. Close this tab if you're done."
        btn_off = gr.update(interactive=False)
        rec, idx = get_record(idx)
        schedule_exit()
        return (
            display_path(rec.get("image", None)),
            rec.get("final_caption", ""),
            progress_text(idx),
            status,
            idx,
            btn_off,
            btn_off,
            btn_off,
            btn_off,
            btn_off,
        )

    rec, idx = get_record(idx)
    img_path = display_path(rec.get("image", ""))
    cap = rec.get("final_caption", "")
    status = f"Saved {time.strftime('%H:%M:%S')}"
    btn_on = gr.update(interactive=True)
    return (
        img_path,
        cap,
        progress_text(idx),
        status,
        idx,
        btn_on,
        btn_on,
        btn_on,
        btn_on,
        gr.update(interactive=True),
    )



def nav_first(caption_text, idx):
    return nav("first", caption_text, idx)


def nav_prev(caption_text, idx):
    return nav("prev", caption_text, idx)


def nav_next(caption_text, idx):
    return nav("next", caption_text, idx)


def nav_last(caption_text, idx):
    return nav("last", caption_text, idx)


def nav_end(caption_text, idx):
    return nav("end", caption_text, idx)


def load_first(idx):
    if not DATA:
        off = gr.update(interactive=False)
        return None, "", "No records", "Nothing to review", idx, off, off, off, off, off
    rec, idx = get_record(idx)
    on = gr.update(interactive=True)
    return (
        display_path(rec.get("image", "")),
        rec.get("final_caption", ""),
        progress_text(idx),
        "",
        idx,
        on,
        on,
        on,
        on,
        on,
    )



def main():
    parser = argparse.ArgumentParser(description="Simple caption reviewer")
    parser.add_argument("--captions", required=True, help="Path to captions.json")
    parser.add_argument("--csv", required=True, help="Path to captions.csv")
    parser.add_argument("--concept", required=False, default="", help="Concept name (display only)")
    parser.add_argument("--port", type=int, default=7860, help="Port for Gradio UI")
    # 0.0.0.0 is needed inside a container; 127.0.0.1 keeps a host run local.
    parser.add_argument("--host", default="127.0.0.1", help="Address to bind")
    args = parser.parse_args()

    global DATA, JSON_PATH, CSV_PATH, DATA_DIR
    DATA = load_captions(args.captions)
    JSON_PATH = args.captions
    CSV_PATH = args.csv
    DATA_DIR = os.path.dirname(args.captions)

    title = "Caption Review"
    if args.concept:
        title += f" – {args.concept}"

    # Gradio's height= sizes the component, not the <img> inside it, so a photo
    # larger than the container renders cropped rather than scaled. Constrain
    # the image itself and use contain so the whole frame stays visible --
    # a reviewer cannot judge a caption against a cropped image.
    # max-width matters as much as max-height: a 16:9 photo bounded only by
    # height would render ~854px wide and overflow the container sideways.
    css = """
    #review-image { height: %(h)dpx; }
    #review-image img {
        max-height: %(h)dpx;
        max-width: 100%%;
        width: auto;
        height: auto;
        margin: 0 auto;
        object-fit: contain;
    }
    """ % {"h": IMAGE_HEIGHT}

    # Gradio 6 moved css from the Blocks constructor to launch(). Detect which
    # one this version accepts so the UI runs unchanged on either.
    css_on_launch = "css" in inspect.signature(gr.Blocks.launch).parameters
    blocks_kwargs = {"title": title}
    if not css_on_launch:
        blocks_kwargs["css"] = css

    with gr.Blocks(**blocks_kwargs) as demo:
        gr.Markdown(f"### {title}")
        image = gr.Image(
            type="filepath",
            label="Image",
            height=IMAGE_HEIGHT,
            elem_id="review-image",
        )
        caption = gr.Textbox(label="Caption", lines=4)
        progress = gr.Markdown()
        status = gr.Markdown()

        state_holder = gr.State(0)

        with gr.Row():
            first_btn = gr.Button("<<", min_width=60)
            prev_btn = gr.Button("<", min_width=60)
            next_btn = gr.Button(">", min_width=60)
            last_btn = gr.Button(">>", min_width=60)
            end_btn = gr.Button("End Task", variant="stop")

        demo.load(
            load_first,
            inputs=state_holder,
            outputs=[image, caption, progress, status, state_holder, first_btn, prev_btn, next_btn, last_btn, end_btn],
        )

        first_btn.click(
            nav_first,
            inputs=[caption, state_holder],
            outputs=[image, caption, progress, status, state_holder, first_btn, prev_btn, next_btn, last_btn, end_btn],
        )
        prev_btn.click(
            nav_prev,
            inputs=[caption, state_holder],
            outputs=[image, caption, progress, status, state_holder, first_btn, prev_btn, next_btn, last_btn, end_btn],
        )
        next_btn.click(
            nav_next,
            inputs=[caption, state_holder],
            outputs=[image, caption, progress, status, state_holder, first_btn, prev_btn, next_btn, last_btn, end_btn],
        )
        last_btn.click(
            nav_last,
            inputs=[caption, state_holder],
            outputs=[image, caption, progress, status, state_holder, first_btn, prev_btn, next_btn, last_btn, end_btn],
        )
        end_btn.click(
            nav_end,
            inputs=[caption, state_holder],
            outputs=[image, caption, progress, status, state_holder, first_btn, prev_btn, next_btn, last_btn, end_btn],
        )
    launch_kwargs = {
        "server_name": args.host,
        "server_port": args.port,
        "share": False,
        "inbrowser": False,
        "allowed_paths": [DATA_DIR],
    }
    if css_on_launch:
        launch_kwargs["css"] = css

    demo.launch(**launch_kwargs)


if __name__ == "__main__":
    main()

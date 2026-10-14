# A published image of the tool itself, for people who would rather run a
# container than install PowerShell and Python.
#
# This is the only thing Docker is used for. Captioning talks to Ollama over
# HTTP, so Ollama is installed separately, on the host or anywhere reachable.
#
# Build:
#   docker build -t caidence-lora-dsbuilder .
#
# Run, with the source photos and an output folder mounted, and the host's
# Ollama reachable:
#   docker run --rm -it \
#     --add-host=host.docker.internal:host-gateway \
#     -p 7861:7861 \
#     -v "/path/to/photos:/photos:ro" \
#     -v "/path/to/datasets:/datasets" \
#     caidence-lora-dsbuilder \
#     pwsh ./scripts/caption.ps1 -ImageDir /photos -Concept mikey \
#       -OutputDir /datasets/mikey -OllamaEndpoint http://host.docker.internal:11434
#
# The source mount is read-only above, which matches how the tool behaves
# anyway: it only ever reads from the folder you point it at.

FROM mcr.microsoft.com/powershell:latest

# python3-venv is not needed: the image installs the packages directly, and
# the scripts skip environment creation when the imports already resolve.
RUN apt-get update \
    && apt-get install -y --no-install-recommends python3 python3-pip curl \
    && rm -rf /var/lib/apt/lists/* \
    && pip3 install --no-cache-dir --break-system-packages pillow gradio

WORKDIR /app

COPY lib/ ./lib/
COPY scripts/ ./scripts/
COPY review_ui.py New-LoraDataset.ps1 ./

# The scripts look for a virtual environment first and fall back to the
# interpreter on PATH, which is where the packages above live.
ENV LORA_PYTHON=/usr/bin/python3

# Review UI, when it is run from inside the container.
EXPOSE 7861

ENTRYPOINT ["pwsh"]
CMD ["-NoProfile", "-File", "./New-LoraDataset.ps1"]

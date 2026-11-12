# Kaku: faster-whisper on the GPU. CUDA 12.8+ is needed for the RTX 50 series (Blackwell).
FROM nvidia/cuda:12.8.1-cudnn-runtime-ubuntu24.04
RUN apt-get update && apt-get install -y --no-install-recommends python3 python3-pip ffmpeg \
    && rm -rf /var/lib/apt/lists/*
# PyAV 16 dropped an option faster-whisper 1.2.1 still passes.
RUN pip3 install --break-system-packages --no-cache-dir faster-whisper==1.2.1 "av<16" nvidia-ml-py \
    fastapi==0.128.8 "uvicorn==0.39.0" pydantic==2.13.5 pytest==8.4.2 httpx==0.28.1
# The Hugging Face cache (the model, ~3 GB) is a volume, so rebuilding doesn't download it again.
ENV HF_HOME=/models PYTHONUNBUFFERED=1
WORKDIR /app
COPY kaku ./kaku
COPY tests ./tests
EXPOSE 8000
HEALTHCHECK --interval=60s --timeout=5s CMD python3 -c "import urllib.request; urllib.request.urlopen('http://localhost:8000/health', timeout=4)"
CMD ["python3", "-m", "kaku.main"]

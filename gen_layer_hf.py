# Generation layer with Hugging Face integration
# gen_layers_hf.py
import os, yaml, random, time, json, base64
import requests
from pathlib import Path
from tqdm import tqdm
from dotenv import load_dotenv

load_dotenv()                     # membaca .env
HF_TOKEN = os.getenv("HF_TOKEN")
if not HF_TOKEN:
    raise RuntimeError("Set HF_TOKEN in .env")

# -------------------------------------------------
# USER‑CONFIGURABLE
MODEL_ID = "stabilityai/stable-diffusion-2-1"   # atau "username/your-sd-space"
API_URL = f"https://api-inference.huggingface.co/models/{MODEL_ID}"
HEADERS = {"Authorization": f"Bearer {HF_TOKEN}",
           "Content-Type": "application/json"}
OUTDIR = Path("layers")
OUTDIR.mkdir(exist_ok=True)
# -------------------------------------------------

# Load prompts
with open("prompts.yaml") as f:
    prompts = yaml.safe_load(f)

def hf_generate(prompt: str, seed: int) -> bytes:
    """
    Calls HF Inference API for Stable Diffusion.
    Returns raw PNG bytes (transparent background).
    """
    payload = {
        "inputs": prompt,
        "parameters": {
            "seed": seed,
            "width": 512,
            "height": 512,
            "num_inference_steps": 30,
            "guidance_scale": 7.5,
            "output_type": "png",          # request PNG
            "force_access_token": False,
            "negative_prompt": "low‑res, blurry"
        }
    }
    response = requests.post(API_URL, headers=HEADERS, json=payload)
    # API may return 503 if model is busy → simple retry
    retries = 0
    while response.status_code == 503 and retries < 5:
        time.sleep(2 ** retries)          # exponential back‑off
        response = requests.post(API_URL, headers=HEADERS, json=payload)
        retries += 1
    if response.status_code != 200:
        raise RuntimeError(f"HuggingFace error {response.status_code}: {response.text}")

    # HF returns binary PNG directly (no base64 wrapper)
    return response.content

# ------------------------------------------------------------------
# Generate 20 variasi per lapisan (sesuaikan angka bila diperlukan)
for layer, prompt in tqdm(prompts.items(), desc="Layers"):
    for i in range(20):
        seed = random.randint(0, 2**32 - 1)
        png_bytes = hf_generate(prompt, seed)

        # Simpan dengan format layer_seed.png
        out_path = OUTDIR / f"{layer}_{seed}.png"
        out_path.write_bytes(png_bytes)

print(f"\n✅ selesai – {len(list(OUTDIR.glob('*.png')))} file PNG di {OUTDIR}")

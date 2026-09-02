# Mix layers module
import itertools, random, json
from pathlib import Path
from PIL import Image

# Kumpulkan semua file per lapisan
layers = {}
for p in Path("layers").glob("*_*.png"):
    layer = p.stem.split('_')[0]
    layers.setdefault(layer, []).append(p)

OUT_IMG = Path("images")
OUT_IMG.mkdir(exist_ok=True)

metadata = []

# Pilih 10 000 kombinasi acak
all_combos = list(itertools.product(*layers.values()))
random.shuffle(all_combos)
selected = all_combos[:10000]

for idx, combo in enumerate(selected, start=1):
    # Mulai dengan lapisan pertama
    canvas = Image.open(combo[0]).convert("RGBA")
    for p in combo[1:]:
        canvas = Image.alpha_composite(canvas, Image.open(p).convert("RGBA"))
    filename = f"{idx:05d}.png"
    canvas.save(OUT_IMG / filename)

    # Metadata per token (hanya nama lapisan)
    attrs = [{"trait_type": "Layer", "value": Path(p).stem.split('_')[0]} for p in combo]
    metadata.append({
        "name": f"MyPFP #{idx}",
        "description": "AI‑generated generative avatar.",
        "image": f"ipfs://<IMG_CID>/{filename}",
        "attributes": attrs
    })

# Simpan metadata batch per 1 000 (10 file)
for i in range(0, len(metadata), 1000):
    batch = metadata[i:i+1000]
    Path(f"metadata_{i//1000}.json").write_text(json.dumps(batch, indent=2))

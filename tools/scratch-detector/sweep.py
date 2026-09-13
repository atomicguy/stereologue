"""Mask density at several thresholds, whole crop vs interior (6% margin
excluded), for every image given — Core ML 512 model only.
Usage: uv run sweep.py image ..."""
import sys, numpy as np, coremltools as ct
from PIL import Image
m = ct.models.MLModel("ScratchDetector512.mlpackage", compute_units=ct.ComputeUnit.CPU_AND_NE)
print(f"{'image':<24} {'thr0.4':>7} {'int0.4':>7} {'thr0.6':>7} {'int0.6':>7} {'thr0.8':>7} {'int0.8':>7}")
rows = {}
for path in sys.argv[1:]:
    name = path.split("/")[-1].rsplit(".", 1)[0]
    g = Image.open(path).convert("L").resize((512, 512), Image.BICUBIC)
    p = np.asarray(m.predict({"image": g})["probability"], dtype=np.float32) / 255
    mrg = int(512 * 0.06)
    interior = p[mrg:-mrg, mrg:-mrg]
    vals = []
    for t in (0.4, 0.6, 0.8):
        vals += [(p >= t).mean() * 100, (interior >= t).mean() * 100]
    rows[name] = vals
    print(f"{name:<24} " + " ".join(f"{v:7.3f}" for v in vals))
for cat in ("defects", "clean"):
    sel = np.array([v for k, v in rows.items() if k.startswith(cat)])
    print(f"{cat + ' mean':<24} " + " ".join(f"{v:7.3f}" for v in sel.mean(axis=0)))

"""Runs the PyTorch reference and the Core ML models on images and writes masks.

Usage: uv run evaluate.py out_dir image1.jpg [image2 ...]
Expects ScratchDetector256.mlpackage and ScratchDetector512.mlpackage in the
current directory. Writes <out_dir>/<name>_<size>_{torch,coreml}.png
(probability) and <name>_<size>_overlay.png (Core ML mask >= 0.4 painted red
on the image), and prints agreement and Core ML timing on this Mac.
"""
import os, sys, time
import numpy as np
import torch
from PIL import Image
import coremltools as ct
from bopbtl.networks import UNet

out_dir, images = sys.argv[1], sys.argv[2:]
os.makedirs(out_dir, exist_ok=True)

net = UNet(in_channels=1, out_channels=1, depth=4, conv_num=2, wf=6, padding=True,
           batch_norm=True, up_mode="upsample", with_tanh=False, sync_bn=False, antialiasing=True)
net.load_state_dict(torch.load("checkpoints/FT_Epoch_latest.pt", map_location="cpu", weights_only=False)["model_state"])
net.eval()

models = {size: {units: ct.models.MLModel(f"ScratchDetector{size}.mlpackage", compute_units=units)
                 for units in (ct.ComputeUnit.CPU_AND_NE, ct.ComputeUnit.CPU_ONLY)}
          for size in (256, 512)}

for path in images:
    name = os.path.splitext(os.path.basename(path))[0]
    rgb = Image.open(path).convert("RGB")
    gray = rgb.convert("L")
    for size in (256, 512):
        g = gray.resize((size, size), Image.BICUBIC)
        x = torch.from_numpy((np.asarray(g, dtype=np.float32) / 255 - 0.5) / 0.5)[None, None]
        with torch.no_grad():
            p_torch = torch.sigmoid(net(x))[0, 0].numpy()
        Image.fromarray((p_torch * 255).astype(np.uint8)).save(f"{out_dir}/{name}_{size}_torch.png")

        timings, p_coreml = {}, None
        for units, m in models[size].items():
            m.predict({"image": g})
            t0 = time.perf_counter()
            for _ in range(5):
                out = m.predict({"image": g})["probability"]
            timings[units.name] = (time.perf_counter() - t0) / 5
            if p_coreml is None:
                p_coreml = np.asarray(out, dtype=np.float32) / 255
        Image.fromarray((p_coreml * 255).astype(np.uint8)).save(f"{out_dir}/{name}_{size}_coreml.png")

        mask_t, mask_c = p_torch >= 0.4, p_coreml >= 0.4
        inter, union = np.logical_and(mask_t, mask_c).sum(), np.logical_or(mask_t, mask_c).sum()
        iou = inter / union if union else 1.0
        base = np.asarray(rgb.resize((size, size), Image.BICUBIC), dtype=np.float32)
        base[mask_c] = base[mask_c] * 0.3 + np.array([255, 0, 0]) * 0.7
        Image.fromarray(base.astype(np.uint8)).save(f"{out_dir}/{name}_{size}_overlay.png")
        print(f"{name} @{size}: mask {mask_c.mean()*100:.2f}% of pixels, torch/coreml IoU {iou:.3f}, "
              f"max|Δp| {np.abs(p_torch - p_coreml).max():.3f}, "
              + ", ".join(f"{k} {v*1000:.0f} ms" for k, v in timings.items()), flush=True)

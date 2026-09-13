"""Converts the Bringing Old Photos Back to Life scratch-detection U-Net to Core ML.

Input:  grayscale image. The original pipeline scales the short side to 256;
        two static models are produced (256×256 and 512×512) because flexible
        input shapes (EnumeratedShapes / RangeDim) make the Core ML CPU
        backend (BNNS graph compile) crash on macOS 26.6, and static shapes
        are what keep the model on the Neural Engine anyway.
        Normalization (x/255 - 0.5)/0.5 is folded into the input.
Output: grayscale image whose pixel value is 255 * sigmoid(logit), i.e. the
        scratch probability. The original thresholds at 0.4 (pixel >= 102).

Usage: uv run convert.py [checkpoints/FT_Epoch_latest.pt] [out_dir]
"""
import os
import sys
import torch
import torch.nn as nn
import coremltools as ct
from bopbtl.networks import UNet

ckpt_path = sys.argv[1] if len(sys.argv) > 1 else "checkpoints/FT_Epoch_latest.pt"
out_dir = sys.argv[2] if len(sys.argv) > 2 else "."

model = UNet(in_channels=1, out_channels=1, depth=4, conv_num=2, wf=6, padding=True,
             batch_norm=True, up_mode="upsample", with_tanh=False, sync_bn=False, antialiasing=True)
ckpt = torch.load(ckpt_path, map_location="cpu", weights_only=False)
model.load_state_dict(ckpt["model_state"], strict=True)
model.eval()


class Probability(nn.Module):
    """sigmoid(logits) scaled to 0…255 so Core ML can emit a grayscale image."""
    def __init__(self, net):
        super().__init__()
        self.net = net
    def forward(self, x):
        return torch.sigmoid(self.net(x)) * 255.0


wrapped = Probability(model).eval()
for size in (256, 512):
    example = torch.rand(1, 1, size, size) * 2 - 1
    with torch.no_grad():
        traced = torch.jit.trace(wrapped, example)
    mlmodel = ct.convert(
        traced,
        inputs=[ct.ImageType(name="image", shape=(1, 1, size, size), color_layout=ct.colorlayout.GRAYSCALE,
                             scale=1 / 127.5, bias=-1.0)],
        outputs=[ct.ImageType(name="probability", color_layout=ct.colorlayout.GRAYSCALE)],
        compute_precision=ct.precision.FLOAT16,
        convert_to="mlprogram",
        minimum_deployment_target=ct.target.iOS18,
    )
    mlmodel.author = "Microsoft Research (Bringing Old Photos Back to Life, CVPR 2020); converted for Stereologue"
    mlmodel.license = "MIT"
    mlmodel.short_description = (f"Scratch/dust probability mask for scanned photographs. "
                                 f"{size}x{size} grayscale in, probability*255 grayscale out.")
    path = os.path.join(out_dir, f"ScratchDetector{size}.mlpackage")
    mlmodel.save(path)
    print("saved", path)

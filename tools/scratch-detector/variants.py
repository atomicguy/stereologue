import sys, torch, torch.nn as nn, coremltools as ct
from bopbtl.networks import UNet
out = sys.argv[1]
net = UNet(in_channels=1, out_channels=1, depth=4, conv_num=2, wf=6, padding=True, batch_norm=True,
           up_mode="upsample", with_tanh=False, sync_bn=False, antialiasing=True)
net.load_state_dict(torch.load("checkpoints/FT_Epoch_latest.pt", map_location="cpu", weights_only=False)["model_state"]); net.eval()

class Trunc(nn.Module):
    """Runs the U-Net up to `stage`: 0=first, 1=+down_sample[0], 2=+down_path[0], 3=+all downs, 4=+all ups, 5=full."""
    def __init__(self, net, stage): super().__init__(); self.net, self.stage = net, stage
    def forward(self, x):
        n = self.net
        x = n.first(x)
        if self.stage == 0: return x
        if self.stage == 1: return n.down_sample[0](x)
        if self.stage == 2: return n.down_path[0](n.down_sample[0](x))
        blocks = []
        for i, db in enumerate(n.down_path):
            blocks.append(x); x = n.down_sample[i](x); x = db(x)
        if self.stage == 3: return x
        for i, up in enumerate(n.up_path): x = up(x, blocks[-i-1])
        if self.stage == 4: return x
        return torch.sigmoid(n.last(x)) * 255.0

def convert(name, module, precision=ct.precision.FLOAT16, image_out=False, size=256):
    ex = torch.rand(1, 1, size, size) * 2 - 1
    with torch.no_grad(): tr = torch.jit.trace(module.eval(), ex)
    outs = [ct.ImageType(name="probability", color_layout=ct.colorlayout.GRAYSCALE)] if image_out else None
    # A fully static shape trips a coremltools cast bug in this network; a
    # single-entry EnumeratedShapes is static for Core ML but avoids it.
    shape = ct.EnumeratedShapes(shapes=[(1, 1, size, size), (1, 1, size * 2, size * 2)], default=(1, 1, size, size))
    try:
        m = ct.convert(tr, inputs=[ct.ImageType(name="image", shape=shape, color_layout=ct.colorlayout.GRAYSCALE, scale=1/127.5, bias=-1.0)],
                       outputs=outs, compute_precision=precision, convert_to="mlprogram", minimum_deployment_target=ct.target.iOS18)
        m.save(f"{out}/{name}.mlpackage"); print("saved", name, flush=True)
    except Exception as e:
        print("FAILED", name, type(e).__name__, str(e)[:120], flush=True)

convert("full_static_fp16_img", Trunc(net, 5), image_out=True)
convert("full_static_fp32_img", Trunc(net, 5), precision=ct.precision.FLOAT32, image_out=True)
convert("full_static_fp16_arr", Trunc(net, 5))
for s in range(0, 5): convert(f"trunc{s}_fp16", Trunc(net, s))

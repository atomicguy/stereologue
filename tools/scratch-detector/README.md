# Scratch detector conversion

Converts the scratch-detection U-Net from Microsoft's *Bringing Old Photos
Back to Life* (CVPR 2020, MIT-licensed code and checkpoints) to Core ML for
Stereologue's restoration track (see `PLAN-fall-2026.md`, Phase 3.3).

Only the detector is used. The project's global-restoration and
face-enhancement stages are deliberately not ported: they generate pixels
independently per eye, which breaks stereo fusion.

## Setup

Requires [uv](https://docs.astral.sh/uv/). Python 3.12 is pinned because it is
the newest version coremltools supports; torch is pinned to the 2.7 line
because that is the newest coremltools has been tested against.

```bash
cd tools/scratch-detector
uv sync
```

## Weights

The detector checkpoint (`FT_Epoch_latest.pt`, 452 MB) lives inside the
project's 2 GB `global_checkpoints.zip` release asset. `fetch_checkpoint.py`
pulls just that one entry with HTTP range requests:

```bash
uv run fetch_checkpoint.py
```

Checkpoints and `.mlpackage` outputs are git-ignored.

## Convert

```bash
uv run convert.py
```

Produces `ScratchDetector256.mlpackage` and `ScratchDetector512.mlpackage`
(FP16, ~72 MB each). Grayscale image in, with the original `(x/255 − 0.5)/0.5`
normalization folded into the input; grayscale image out whose pixel value is
`255 × sigmoid(logit)`. The original pipeline thresholds the probability at
0.4 (pixel ≥ 102).

Why two static sizes rather than one flexible model: on macOS 26.6 a model
with `EnumeratedShapes` inputs crashes the Core ML CPU backend at graph
compile time (BNNS, `SIGBUS`), and static shapes are also what keep the
network on the Neural Engine.

Why the vendored `bopbtl/networks.py` differs from upstream: the
`sync_batchnorm` wrapper is removed (it was a no-op — the constructor rebinds
a local `self`), and `UNetUpBlock.center_crop` returns early when sizes
already match so no `size()` arithmetic lands in the trace, which coremltools
9 cannot convert for a static input.

## Evaluate

```bash
uv run evaluate.py out_dir path/to/eye-crop.jpg ...
```

Runs the PyTorch reference and both Core ML models, writes probability maps
and red overlays of the ≥ 0.4 mask, and prints torch/Core ML agreement and
timing on this Mac. Measured here (M-series, Neural Engine): ~33 ms at 256,
~130 ms at 512 per eye.

## Preprocessing contract for the app

1. Convert the eye crop to grayscale.
2. Resize to 256×256 or 512×512 (the original scales the short side to 256
   and rounds to a multiple of 16; a square resize of a roughly square eye is
   within that regime).
3. Run the model; resize the probability map back to the crop with nearest
   neighbour; threshold at 0.4.

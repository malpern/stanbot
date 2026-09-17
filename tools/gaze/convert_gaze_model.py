#!/usr/bin/env python3
"""Convert a Gaze360-trained gaze model to Core ML, check it, and time it.

    python3 tools/gaze/convert_gaze_model.py --repo PATH/gaze-estimation \\
        --weights PATH/resnet50.pt --arch resnet50 --out PATH/Gaze-resnet50.mlpackage

Source models: github.com/yakhyo/gaze-estimation (MIT), an L2CS-Net style
retraining on Gaze360. The original L2CS-Net weights are no longer downloadable
(their Google Drive link 404s; L2CS-Net issue #47). Weights are NOT committed
here; download them from that repo's "weights" release. See docs/gaze.md.

The Core ML model takes a face crop as an RGB image and returns gaze yaw and
pitch in degrees. Everything the Python pipeline did after the crop is inside
it: scale to [0, 1], ImageNet mean/std normalisation, softmax over the 90 bins,
and the expectation (bin index x 4 - 180). So Swift only has to crop the face
and hand Vision a CVPixelBuffer.

Checks: the Core ML output matches PyTorch on random inputs (max difference
reported in degrees), and prediction latency is measured for CPU only and for
all compute units (Neural Engine / GPU). The .pt files are loaded with
weights_only=True, so they cannot execute code.
"""
import argparse
import sys
import time

import numpy as np
import torch
import torch.nn as nn
import torch.nn.functional as F

BINS, BINWIDTH, ANGLE = 90, 4, 180          # Gaze360 settings in that repo's config.py
MEAN = [0.485, 0.456, 0.406]
STD = [0.229, 0.224, 0.225]


class GazeHead(nn.Module):
    """Normalised image in [0, 1] -> (yaw, pitch) in degrees."""

    def __init__(self, backbone):
        super().__init__()
        self.backbone = backbone
        self.register_buffer("mean", torch.tensor(MEAN).view(1, 3, 1, 1))
        self.register_buffer("std", torch.tensor(STD).view(1, 3, 1, 1))
        self.register_buffer("idx", torch.arange(BINS, dtype=torch.float32))

    def forward(self, image):
        yaw_logits, pitch_logits = self.backbone((image - self.mean) / self.std)
        yaw = (F.softmax(yaw_logits, dim=1) * self.idx).sum(dim=1) * BINWIDTH - ANGLE
        pitch = (F.softmax(pitch_logits, dim=1) * self.idx).sum(dim=1) * BINWIDTH - ANGLE
        return yaw, pitch


def load(repo, arch, weights):
    sys.path.insert(0, repo)
    import models   # the repo's models package; utils.helpers would pull in OpenCV
    factory = getattr(models, "mobilenet_v2" if arch == "mobilenetv2" else arch)
    kwargs = {"inference_mode": True} if arch.startswith("mobileone") else {}
    model = factory(pretrained=False, num_classes=BINS, **kwargs)
    state = torch.load(weights, map_location="cpu", weights_only=True)
    if isinstance(state, dict) and "model" in state and isinstance(state["model"], dict):
        state = state["model"]
    missing, unexpected = model.load_state_dict(state, strict=False)
    if missing or unexpected:
        raise SystemExit(f"weights do not fit {arch}: missing {missing[:5]} unexpected {unexpected[:5]}")
    return GazeHead(model).eval()


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--repo", required=True, help="checkout of yakhyo/gaze-estimation")
    parser.add_argument("--weights", required=True)
    parser.add_argument("--arch", required=True, choices=["resnet18", "resnet34", "resnet50", "mobilenetv2", "mobileone_s0"])
    parser.add_argument("--size", type=int, default=448, help="square input size; the repo resizes faces to 448")
    parser.add_argument("--out", required=True)
    parser.add_argument("--runs", type=int, default=50)
    args = parser.parse_args()

    import coremltools as ct

    model = load(args.repo, args.arch, args.weights)
    example = torch.rand(1, 3, args.size, args.size)
    with torch.no_grad():
        traced = torch.jit.trace(model, example)
    mlmodel = ct.convert(
        traced,
        inputs=[ct.ImageType(name="face", shape=example.shape, scale=1 / 255.0, color_layout=ct.colorlayout.RGB)],
        outputs=[ct.TensorType(name="yaw_degrees"), ct.TensorType(name="pitch_degrees")],
        minimum_deployment_target=ct.target.macOS14,
    )
    mlmodel.short_description = (f"Gaze yaw/pitch in degrees from an RGB face crop ({args.arch}, Gaze360, "
                                 "yakhyo/gaze-estimation, MIT). Not eye contact; see stanbot docs/gaze.md.")
    mlmodel.save(args.out)

    from PIL import Image
    rng = np.random.default_rng(0)
    worst = 0.0
    for _ in range(5):
        pixels = rng.integers(0, 256, size=(args.size, args.size, 3), dtype=np.uint8)
        with torch.no_grad():
            tensor = torch.from_numpy(pixels).permute(2, 0, 1).unsqueeze(0).float() / 255.0
            ref_yaw, ref_pitch = (v.item() for v in model(tensor))
        out = mlmodel.predict({"face": Image.fromarray(pixels)})
        worst = max(worst, abs(float(out["yaw_degrees"][0]) - ref_yaw), abs(float(out["pitch_degrees"][0]) - ref_pitch))
    print(f"{args.arch}: max |Core ML - PyTorch| over 5 random images = {worst:.3f} degrees")

    image = Image.fromarray(rng.integers(0, 256, size=(args.size, args.size, 3), dtype=np.uint8))
    for label, units in [("cpu_only", ct.ComputeUnit.CPU_ONLY), ("all", ct.ComputeUnit.ALL)]:
        timed = ct.models.MLModel(args.out, compute_units=units)
        for _ in range(5):
            timed.predict({"face": image})
        start = time.perf_counter()
        for _ in range(args.runs):
            timed.predict({"face": image})
        per = (time.perf_counter() - start) / args.runs * 1000
        print(f"{args.arch} @ {args.size}px, {label}: {per:.1f} ms per prediction ({args.runs} runs)")
    return 0 if worst < 1.0 else 1


if __name__ == "__main__":
    sys.exit(main())

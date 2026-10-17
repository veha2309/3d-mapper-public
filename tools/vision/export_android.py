"""Export pinned official ALIKED/LightGlue weights to standard ONNX CPU ops."""
import hashlib
import json
import types
from pathlib import Path

import numpy as np
import onnx
import onnxruntime as ort
import torch
from torch import nn
from torch.nn import functional as F
from lightglue import ALIKED, LightGlue
from lightglue.aliked import DeformableConv2d

SIZE, COUNT = 480, 256


def portable_deform(self, image):
    """Exact unmodulated stride-1 DCN via bilinear GridSample, no custom ops."""
    height, width = image.shape[-2:]
    offsets = self.offset_conv(image).clamp(-max(height, width) / 4, max(height, width) / 4)
    yy, xx = torch.meshgrid(torch.arange(height, dtype=image.dtype),
                            torch.arange(width, dtype=image.dtype), indexing="ij")
    result = image[:, :1] * 0
    for y in range(3):
        for x in range(3):
            i = y * 3 + x
            gy = yy + y - 1 + offsets[:, 2*i]
            gx = xx + x - 1 + offsets[:, 2*i+1]
            grid = torch.stack((2 * gx / (width - 1) - 1, 2 * gy / (height - 1) - 1), dim=-1)
            sampled = F.grid_sample(image, grid, mode="bilinear", padding_mode="zeros", align_corners=True)
            result = result + F.conv2d(sampled, self.regular_conv.weight[:, :, y:y+1, x:x+1])
    if self.regular_conv.bias is not None:
        result = result + self.regular_conv.bias[None, :, None, None]
    return result


class Extractor(nn.Module):
    def __init__(self):
        super().__init__()
        self.model = ALIKED(max_num_keypoints=COUNT, detection_threshold=-1).eval()

    def forward(self, image):
        result = self.model({"image": image})
        return result["keypoints"], result["descriptors"], result["keypoint_scores"]


class Matching(nn.Module):
    def __init__(self):
        super().__init__()
        self.model = LightGlue(features="aliked", flash=False, depth_confidence=-1, width_confidence=-1).eval()

    def forward(self, points0, descriptors0, points1, descriptors1):
        # Explicit fixed-rank reshapes avoid legacy ONNX unflatten rank inference.
        def encoding(points):
            projected = self.model.posenc.Wr((points - SIZE / 2) / (SIZE / 2))
            return (projected.cos().repeat_interleave(2, -1).unsqueeze(1),
                    projected.sin().repeat_interleave(2, -1).unsqueeze(1))
        def rotary(value, enc):
            pairs = value.reshape(1, 4, COUNT, 32, 2)
            rotated = torch.stack((-pairs[..., 1], pairs[..., 0]), dim=4).reshape(1, 4, COUNT, 64)
            return value * enc[0] + rotated * enc[1]
        def self_attention(layer, value, enc):
            qkv = layer.Wqkv(value).reshape(1, COUNT, 4, 64, 3).permute(0, 2, 1, 3, 4)
            q, k, v = rotary(qkv[..., 0], enc), rotary(qkv[..., 1], enc), qkv[..., 2]
            attention = (q @ k.transpose(2, 3) / 8).softmax(3)
            message = layer.out_proj((attention @ v).transpose(1, 2).reshape(1, COUNT, 256))
            return value + layer.ffn(torch.cat((value, message), dim=-1))
        def split(value):
            return value.reshape(1, COUNT, 4, 64).transpose(1, 2)
        a, b = self.model.input_proj(descriptors0), self.model.input_proj(descriptors1)
        enc0, enc1 = encoding(points0), encoding(points1)
        for layer in self.model.transformers:
            a = self_attention(layer.self_attn, a, enc0)
            b = self_attention(layer.self_attn, b, enc1)
            cross = layer.cross_attn
            q0, q1 = split(cross.to_qk(a)), split(cross.to_qk(b))
            v0, v1 = split(cross.to_v(a)), split(cross.to_v(b))
            sim = (q0 * cross.scale**.5) @ (q1 * cross.scale**.5).transpose(2, 3)
            m0 = (sim.softmax(3) @ v1).transpose(1, 2).reshape(1, COUNT, 256)
            m1 = (sim.transpose(2, 3).softmax(3) @ v0).transpose(1, 2).reshape(1, COUNT, 256)
            a = a + cross.ffn(torch.cat((a, cross.to_out(m0)), dim=-1))
            b = b + cross.ffn(torch.cat((b, cross.to_out(m1)), dim=-1))
        assignment = self.model.log_assignment[-1]
        aa, bb = assignment.final_proj(a) / 4, assignment.final_proj(b) / 4
        sim = aa @ bb.transpose(1, 2)
        scores = (sim.log_softmax(2) + sim.log_softmax(1) - F.softplus(-assignment.matchability(a))
                  - F.softplus(-assignment.matchability(b)).transpose(1, 2))
        return scores


def main():
    import argparse
    parser = argparse.ArgumentParser()
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    torch.set_num_threads(4)
    torch.manual_seed(7)
    extractor = Extractor().eval()
    probe = torch.rand(1, 1, SIZE, SIZE)
    # Verify replacement dense features before exporting; no model retraining.
    with torch.inference_mode():
        original = extractor.model.extract_dense_map(probe.repeat(1, 3, 1, 1))
        for module in extractor.modules():
            if isinstance(module, DeformableConv2d):
                assert not module.mask
                module.forward = types.MethodType(portable_deform, module)
        portable = extractor.model.extract_dense_map(probe.repeat(1, 3, 1, 1))
        for a, b in zip(original, portable):
            torch.testing.assert_close(a, b, atol=1e-4, rtol=1e-3)
        expected = extractor(probe)
    extract_file = args.output / "aliked.onnx"
    torch.onnx.export(extractor, (probe,), str(extract_file), opset_version=17,
                      input_names=["image"], output_names=["points", "descriptors", "scores"], dynamo=False)
    matcher = Matching().eval()
    sample = tuple(value.clone() for value in (expected[0], expected[1], expected[0], expected[1]))
    with torch.inference_mode():
        size = torch.tensor([[SIZE, SIZE]], dtype=torch.float32)
        upstream = matcher.model({"image0": {"keypoints": sample[0], "descriptors": sample[1], "image_size": size},
                                  "image1": {"keypoints": sample[2], "descriptors": sample[3], "image_size": size}})
        portable_scores = matcher(*sample)
        prior_scores = portable_scores.clone()
        best, indices = portable_scores.max(2)
        reverse = portable_scores.argmax(1)
        mutual = torch.arange(COUNT)[None] == reverse.gather(1, indices)
        confidence = torch.where(mutual, best.exp(), 0.)
        torch.testing.assert_close(torch.where(mutual & (confidence > .1), indices, -1), upstream["matches0"])
        torch.testing.assert_close(confidence, upstream["matching_scores0"], atol=1e-4, rtol=1e-3)
    match_file = args.output / "lightglue.onnx"
    torch.onnx.export(matcher, sample, str(match_file), opset_version=17,
                      input_names=["points0", "descriptors0", "points1", "descriptors1"],
                      output_names=["log_assignment"], dynamo=False, do_constant_folding=False)
    options = ort.SessionOptions()
    options.intra_op_num_threads = 4
    for filename in (extract_file, match_file):
        onnx.checker.check_model(str(filename))
        model = onnx.load(str(filename))
        assert all(node.domain in ("", "ai.onnx") for node in model.graph.node)
    session = ort.InferenceSession(str(extract_file), options, providers=["CPUExecutionProvider"])
    actual = session.run(None, {"image": probe.numpy()})
    for a, b in zip(expected, actual):
        np.testing.assert_allclose(a.numpy(), b, atol=5e-3, rtol=2e-3)
    matching = ort.InferenceSession(str(match_file), options, providers=["CPUExecutionProvider"])
    inputs = {name: value.numpy() for name, value in zip(["points0", "descriptors0", "points1", "descriptors1"], sample)}
    actual_scores = matching.run(None, inputs)[0]
    np.testing.assert_allclose(actual_scores, prior_scores.numpy(), atol=1e-3, rtol=1e-3)
    assert np.count_nonzero(actual_scores.argmax(2) == np.arange(COUNT)[None]) >= 200
    # A different query exercises cross-image matching, not just identity pairs.
    moved = torch.roll(probe, shifts=(5, 9), dims=(2, 3))
    with torch.inference_mode():
        moved_features = extractor(moved)
        varied = (expected[0], expected[1], moved_features[0], moved_features[1])
        expected_scores = matcher(*varied).numpy()
        upstream_varied = matcher.model({"image0": {"keypoints": varied[0], "descriptors": varied[1], "image_size": size},
                                       "image1": {"keypoints": varied[2], "descriptors": varied[3], "image_size": size}})
    ort_features = session.run(None, {"image": moved.numpy()})
    for a, b in zip(moved_features, ort_features):
        np.testing.assert_allclose(a.numpy(), b, atol=5e-3, rtol=2e-3)
    varied_inputs = {name: value.numpy() for name, value in zip(inputs, varied)}
    varied_scores = matching.run(None, varied_inputs)[0]
    np.testing.assert_allclose(varied_scores, expected_scores, atol=1e-3, rtol=1e-3)
    indices = varied_scores.argmax(2)
    reverse = varied_scores.argmax(1)
    mutual = np.arange(COUNT)[None] == np.take_along_axis(reverse, indices, axis=1)
    confidence = np.where(mutual, np.exp(varied_scores.max(2)), 0.)
    np.testing.assert_array_equal(np.where(mutual & (confidence > .1), indices, -1), upstream_varied["matches0"].numpy())
    metadata = {"version": 1, "source": "https://github.com/cvg/LightGlue",
                "revision": "eb42fee2d71449efb0aa5c10549752b5d75384d8", "image_size": SIZE,
                "keypoints": COUNT, "descriptor_size": 128, "opset": 17,
                "extractor": "aliked-n16", "matcher": "aliked-lightglue",
                "files": {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in (extract_file, match_file)},
                "matcher_output": "log_assignment", "runtime": "onnxruntime-android:1.20.0",
                "validation": "DCN, extraction, identity and translated-query matching parity passed"}
    (args.output / "models.json").write_text(json.dumps(metadata, indent=2), encoding="utf-8")
    print(json.dumps(metadata, indent=2))


if __name__ == "__main__":
    main()

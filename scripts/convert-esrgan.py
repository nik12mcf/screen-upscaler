# Converts Real-ESRGAN to Core ML tile models (Models/*.mlpackage).
#
#   curl -LO https://github.com/xinntao/Real-ESRGAN/releases/download/v0.2.5.0/realesr-general-x4v3.pth
#   curl -LO https://github.com/xinntao/Real-ESRGAN/releases/download/v0.1.0/RealESRGAN_x4plus.pth
#   uv venv --python 3.12 .venv && uv pip install --python .venv/bin/python "torch==2.7.0" coremltools
#   .venv/bin/python scripts/convert-esrgan.py . Models
#
# Weights are loaded with weights_only=True, so the .pth files can't run code.
# Real-ESRGAN is BSD-3-Clause (c) 2021 Xintao Wang - see Models/REAL-ESRGAN-LICENSE.
import sys, torch, torch.nn as nn, torch.nn.functional as F
import coremltools as ct
wdir, outdir = sys.argv[1], sys.argv[2]   # folder with both .pth files, output folder

class SRVGGNetCompact(nn.Module):
    def __init__(self, num_feat=64, num_conv=32, upscale=4):
        super().__init__()
        self.upscale = upscale
        body = [nn.Conv2d(3, num_feat, 3, 1, 1), nn.PReLU(num_parameters=num_feat)]
        for _ in range(num_conv):
            body += [nn.Conv2d(num_feat, num_feat, 3, 1, 1), nn.PReLU(num_parameters=num_feat)]
        body += [nn.Conv2d(num_feat, 3 * upscale * upscale, 3, 1, 1)]
        self.body = nn.ModuleList(body)
        self.upsampler = nn.PixelShuffle(upscale)
    def forward(self, x):
        out = x
        for layer in self.body: out = layer(out)
        return self.upsampler(out) + F.interpolate(x, scale_factor=self.upscale, mode="nearest")

class ResidualDenseBlock(nn.Module):
    def __init__(self, nf=64, gc=32):
        super().__init__()
        self.conv1 = nn.Conv2d(nf, gc, 3, 1, 1)
        self.conv2 = nn.Conv2d(nf + gc, gc, 3, 1, 1)
        self.conv3 = nn.Conv2d(nf + 2 * gc, gc, 3, 1, 1)
        self.conv4 = nn.Conv2d(nf + 3 * gc, gc, 3, 1, 1)
        self.conv5 = nn.Conv2d(nf + 4 * gc, nf, 3, 1, 1)
        self.lrelu = nn.LeakyReLU(0.2)
    def forward(self, x):
        x1 = self.lrelu(self.conv1(x))
        x2 = self.lrelu(self.conv2(torch.cat((x, x1), 1)))
        x3 = self.lrelu(self.conv3(torch.cat((x, x1, x2), 1)))
        x4 = self.lrelu(self.conv4(torch.cat((x, x1, x2, x3), 1)))
        x5 = self.conv5(torch.cat((x, x1, x2, x3, x4), 1))
        return x5 * 0.2 + x

class RRDB(nn.Module):
    def __init__(self, nf, gc=32):
        super().__init__()
        self.rdb1, self.rdb2, self.rdb3 = ResidualDenseBlock(nf, gc), ResidualDenseBlock(nf, gc), ResidualDenseBlock(nf, gc)
    def forward(self, x):
        return self.rdb3(self.rdb2(self.rdb1(x))) * 0.2 + x

class RRDBNet(nn.Module):
    """RealESRGAN_x4plus: 23 RRDB blocks (basicsr RRDBNet)."""
    def __init__(self, nf=64, nb=23, gc=32):
        super().__init__()
        self.conv_first = nn.Conv2d(3, nf, 3, 1, 1)
        self.body = nn.Sequential(*[RRDB(nf, gc) for _ in range(nb)])
        self.conv_body = nn.Conv2d(nf, nf, 3, 1, 1)
        self.conv_up1 = nn.Conv2d(nf, nf, 3, 1, 1)
        self.conv_up2 = nn.Conv2d(nf, nf, 3, 1, 1)
        self.conv_hr = nn.Conv2d(nf, nf, 3, 1, 1)
        self.conv_last = nn.Conv2d(nf, 3, 3, 1, 1)
        self.lrelu = nn.LeakyReLU(0.2)
    def forward(self, x):
        feat = self.conv_first(x)
        feat = feat + self.conv_body(self.body(feat))
        feat = self.lrelu(self.conv_up1(F.interpolate(feat, scale_factor=2, mode="nearest")))
        feat = self.lrelu(self.conv_up2(F.interpolate(feat, scale_factor=2, mode="nearest")))
        return self.conv_last(self.lrelu(self.conv_hr(feat)))

class ImageIO(nn.Module):
    def __init__(self, net): super().__init__(); self.net = net
    def forward(self, x): return torch.clamp(self.net(x), 0.0, 1.0) * 255.0

def load(net, path):
    sd = torch.load(path, map_location="cpu", weights_only=True)
    print(path.split("/")[-1], "keys:", list(sd.keys()))
    net.load_state_dict(sd.get("params_ema") or sd.get("params") or sd, strict=True)
    return ImageIO(net).eval()

def convert(model, name, tile):
    # Fixed tile shapes: needed for the Neural Engine and for Core ML to write
    # into caller-supplied buffers. The app tiles frames to fit.
    traced = torch.jit.trace(model, torch.rand(1, 3, tile, tile))
    ml = ct.convert(traced,
        inputs=[ct.ImageType(name="input", shape=(1, 3, tile, tile), scale=1/255.0, color_layout=ct.colorlayout.RGB)],
        outputs=[ct.ImageType(name="output", color_layout=ct.colorlayout.RGB)],
        compute_precision=ct.precision.FLOAT16, minimum_deployment_target=ct.target.macOS14)
    ml.short_description = f"Real-ESRGAN {name} (BSD-3-Clause, xinntao/Real-ESRGAN): 4x super-resolution, {tile}px tiles"
    ml.save(f"{outdir}/{name}.mlpackage"); print("saved", name)

plus = load(RRDBNet(), f"{wdir}/RealESRGAN_x4plus.pth")
compact = load(SRVGGNetCompact(), f"{wdir}/realesr-general-x4v3.pth")
convert(compact, "RealESRGAN-compact-512", 512)
convert(plus, "RealESRGAN-x4plus-256", 256)

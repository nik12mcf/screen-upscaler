# Screen Upscaler

Record any region of your Mac's screen, then enhance the recording to 1080p,
1440p or 4K at any frame rate. Enhancement uses AI super-resolution:
Real-ESRGAN and Apple's VideoToolbox models run locally on the Neural Engine
and GPU, or FlashVSR runs in the cloud. A live preview window shows a region
upscaled in real time.

```
record region ──► HEVC .mov ──► decode ──► enhance each frame ──► re-time to FPS ──► HEVC .mov
(ScreenCaptureKit)  (~/Movies)              (engine of choice)    (hold frames)      (1080p–4K)
```

## Requirements

- macOS 14+ on Apple silicon. Built and tested on macOS 26.1 with an M4 Pro.
- **macOS 26** for the Apple engines (VideoToolbox super-resolution). The
  Real-ESRGAN engines work on macOS 14+.
- Swift 6.2 toolchain. Command Line Tools is enough; **full Xcode is not
  needed**.

## Build and run

```bash
make cert         # one-time: stable signing identity (asks for your password)
make run          # build, bundle as .app, launch
make bundle       # build the .app without launching
make clean
```

On first launch, grant Screen Recording when prompted, then relaunch: macOS
only applies a new grant to a freshly started process.

**Why `make cert` matters.** macOS ties Screen Recording permission to an
app's code signature. Without a certificate the build is *ad-hoc* signed, so
macOS identifies it by a hash that changes on every recompile, and the grant
silently stops applying. `make cert` creates a self-signed certificate that
gives the app a stable identity, so the grant survives rebuilds.

If permission gets into a confused state, run `make reset-permission` and then
`make run`. **Always launch with `make run` or `open`**, never the binary
directly; otherwise macOS attributes the capture to your terminal.

## Using it

The app opens as a floating bar along the bottom of the screen:

```
[Live Preview] [Open Video…] | FPS [120] Resolution [4K] Engine [Real-ESRGAN Quality] | [● Record]  status
```

1. Set the **FPS** (1–240), **Resolution** (1080p / 1440p / 4K) and **Engine**.
   The bar remembers them.
2. Click **● Record** and drag over the region to capture.
3. Stop with the **■ Stop** button, the red **●** in the menu bar, or
   **⌃⌥⌘S** from any app.
4. The app then asks **"Process this recording?"**. The prompt shows the
   output size and an estimated time, or the price for Cloud.
5. A progress bar shows percentage, frames/s and time left, with a
   **Cancel** button.
6. Files go to `~/Movies/Screen Upscaler/`. **Open Video…** enhances any
   existing video file the same way.

### Engines

Speeds below are for 4K output on an M4 Pro.

| Engine | Runs on | Speed at 4K | Character |
|---|---|---|---|
| **Real-ESRGAN Quality** | this Mac | ~0.6 frames/s | Most detail; invents fine texture |
| **Real-ESRGAN Fast** | this Mac | ~6 frames/s | Crisp edges, slightly "painted" |
| **Apple Best** | this Mac (macOS 26) | ~5 frames/s | Clean and faithful, but soft |
| **Apple Fast** | this Mac (macOS 26) | ~23 frames/s | Low-latency SR + MetalFX |
| **Cloud (FlashVSR)** | fal.ai | queue-dependent | Diffusion-based, top quality; paid |

The Real-ESRGAN engines suit low-res, blurry or compressed sources. On content
that is already sharp, every engine looks similar.

**Frame rate costs nothing extra.** Each *distinct* source frame is enhanced
once. The output is then filled out to the requested FPS by holding frames, so
a 30 fps video exported at 120 fps takes the same time as at 30. Recording
captures at the display's refresh rate (120 Hz on ProMotion). An FPS above that
is reached by repeating frames, not by interpolating new ones.

**Region size.** For 4K output the engines work from a 960×540 input. A region
of about 480×270 points on a Retina screen is exactly that, so nothing gets
downscaled first.

### Cloud (FlashVSR)

[FlashVSR](https://github.com/OpenImagingLab/FlashVSR) needs an NVIDIA GPU
(CUDA plus a CUDA-only sparse-attention kernel), so it can't run on a Mac. The
Cloud engine uses fal.ai's hosted version
(`fal-ai/flashvsr/upscale/video`).

- **API key:** choose the Cloud engine, or use the app menu → **Set fal.ai API
  Key…**, and paste a key from fal.ai/dashboard/keys. It is stored in the
  Keychain, and `$FAL_KEY` also works.
- **Cost:** $0.0005 per output megapixel per frame, which is about **$7.50 per
  minute of 30 fps 4K**. The prompt shows the estimate before anything is
  uploaded. Only distinct frames are sent, capped at the output FPS, and the
  rest of the frame rate is filled in locally.
- **Privacy:** recordings are uploaded to a third party. They are deleted from
  fal storage after processing, but don't use Cloud for anything sensitive.
- **Pipeline:** shrink to the model's input size → upload → FlashVSR 4x →
  download → trim to the exact size and re-time locally.

### Live preview

**Live Preview** opens a window that shows a selected region upscaled in real
time, at up to the display refresh rate. Modes:

- **Real-ESRGAN:** Fast model, 4x, about 25 fps.
- **AI Enhance:** VideoToolbox low-latency SR, under 1 ms per frame.
- **MetalFX** and **Bilinear**, as baselines.

`⌘R` re-selects the region.

## Layout

```
Sources/ScreenUpscaler/
├── main.swift                       app bootstrap, menu, permission check
├── Capture/
│   ├── RegionSelector.swift         drag-to-select overlay, coordinate conversion
│   ├── ScreenCapture.swift          live SCStream wrapper
│   └── ScreenRecordingPermission.swift
├── Record/
│   ├── ScreenRecorder.swift         region -> HEVC .mov via AVAssetWriter
│   └── GlobalHotKey.swift           ⌃⌥⌘S via Carbon (no Accessibility permission)
├── Process/
│   ├── VideoEnhancer.swift          decode -> enhance -> re-time -> encode; all engines
│   └── FalClient.swift              fal.ai storage + queue REST client, Keychain key
├── Upscale/
│   ├── RealESRGAN.swift             tiled Core ML inference on Neural Engine + GPU
│   ├── AIEnhanceUpscaler.swift      VideoToolbox low-latency SR in a Metal command buffer
│   └── Upscaler.swift               Upscaler protocol, MetalFX, bilinear, live modes
├── Render/
│   └── PreviewRenderer.swift        live preview GPU pipeline
└── UI/
    ├── ControlBar.swift             bottom bar, record/stop, process prompt, progress
    └── PreviewWindow.swift          live preview window

Models/                              Real-ESRGAN Core ML models + licence
scripts/
├── convert-esrgan.py                rebuild Models/ from the official weights
└── make-signing-cert.sh             one-time self-signed code-signing identity
```

## Design notes

**Real-ESRGAN runs as fixed-size tiles.** The models are exported at a fixed
size: 512 px tiles for Fast, 256 px for Quality. Fixed shapes are what let
Core ML use the Neural Engine and write straight into our buffers. Frames are
cut into tiles that overlap by 16 px. The overlap is discarded on output, so
no seams show. A Neural Engine instance and a GPU instance of the model pull
tiles from a shared counter and run side by side.

**Apple's low-latency SR only accepts YUV.** `AIEnhanceUpscaler` converts BGRA
to 4:2:0 in a compute shader, runs the model inside the same Metal command
buffer, and converts back. The model is 2x only, so MetalFX covers 3x and 4x.

**Variable-rate recordings come out constant-rate.** ScreenCaptureKit only
emits frames when the screen changes, so recordings are variable frame rate.
`VideoEnhancer` holds each enhanced frame until the next one arrives and writes
it at every output tick.

**Long jobs run on a dedicated thread**, not a Swift `Task`. The loop blocks on
the encoder and the model for hours, which would starve the cooperative pool.

**Capture runs at native pixel density.** Regions are measured in points but
captured at `points × backingScaleFactor`.

**Coordinate conversion lives in one place.** AppKit uses bottom-left global
coordinates, while `SCStreamConfiguration.sourceRect` wants top-left
coordinates local to one display. `RegionSelector.finish` does the flip.

## Rebuilding the models

```bash
curl -LO https://github.com/xinntao/Real-ESRGAN/releases/download/v0.2.5.0/realesr-general-x4v3.pth
curl -LO https://github.com/xinntao/Real-ESRGAN/releases/download/v0.1.0/RealESRGAN_x4plus.pth
uv venv --python 3.12 .venv && uv pip install --python .venv/bin/python "torch==2.7.0" coremltools
.venv/bin/python scripts/convert-esrgan.py . Models
```

Weights load with `weights_only=True`, so the `.pth` files can't execute code.
torch 2.7 is the latest version coremltools is tested against.

## Known limitations

- **No frame interpolation.** An output FPS above the recording's rate repeats
  frames. VideoToolbox has a frame-interpolation processor that could fill the
  gap.
- **Real-ESRGAN works frame by frame**, so fine invented texture can shimmer
  slightly between frames. Apple Best and FlashVSR use previous frames and
  don't.
- **Real-ESRGAN Quality wastes work on edge tiles** at 960×540. Tile sizes
  matched to common inputs would make it roughly 20–30% faster.
- **No audio.** Recordings capture video only.
- **One display per region.** A selection can't span displays.

## Licences

Real-ESRGAN models: BSD-3-Clause, © 2021 Xintao Wang. See
`Models/REAL-ESRGAN-LICENSE`.

# Screen Upscaler

Select a region of your screen, capture it, and see it upscaled in realtime.

Everything stays on the GPU: ScreenCaptureKit hands frames straight to Metal as
IOSurface-backed textures, MetalFX scales them, and the result is drawn to the
preview window. No CPU round-trip, which is what makes 60 fps achievable.

```
ScreenCaptureKit ──► CVPixelBuffer ──► MTLTexture ──► MetalFX ──► MTKView
    (region)          (zero-copy)        (blit)       (spatial)    (preview)
```

## Requirements

- macOS 14+ (built and tested on macOS 26.1)
- Apple silicon (MetalFX spatial scaling)
- Swift 6.2 toolchain — Command Line Tools is enough, **full Xcode is not needed**

## Build and run

```bash
make run          # build, bundle as .app, launch
make bundle       # build the .app without launching
make build        # plain `swift build`, no bundle
make clean
```

The app must run from the generated `.app` bundle. macOS keys Screen Recording
permission to a bundle identifier, so a bare SwiftPM binary will never be
granted access — `make` handles the bundling for you.

### First launch — do this once

```bash
make cert      # one-time: creates a stable signing identity (asks for your password)
make run
```

Grant Screen Recording when prompted, then launch again — macOS only applies a
new grant to a freshly started process.

**Why `make cert` matters.** macOS ties Screen Recording permission to an app's
code signature. Without a certificate the build is *ad-hoc* signed, which means
macOS identifies it by a hash of the binary — and that hash changes every time
you recompile. The app stays checked in System Settings while the permission
silently stops applying, so you get "permission denied" on an app you can see
is allowed. `make cert` creates a self-signed certificate that gives the app a
stable identity, and the grant then survives rebuilds.

If permission ever gets into a confused state:

```bash
make reset-permission   # forget the grant for this bundle id
make run                # prompts cleanly again
```

**Always launch with `make run` or `open`, never the binary directly.** Running
`dist/ScreenUpscaler.app/Contents/MacOS/ScreenUpscaler` from a shell makes macOS
attribute the capture request to your terminal rather than to the app, and the
grant won't match.

## Using it

1. Launch — region selection starts immediately.
2. Drag a rectangle over the area you want. `esc` cancels.
3. The preview window shows that region upscaled, live.
4. `⌘R` re-selects a region; the popup switches between 2x / 3x / 4x.

The status line reports input size, output size, active upscaler, and measured
fps.

## Layout

```
Sources/ScreenUpscaler/
├── main.swift                    NSApplication bootstrap + menu
├── Capture/
│   ├── RegionSelector.swift      drag-to-select overlay, coordinate conversion
│   ├── ScreenCapture.swift       SCStream wrapper, emits CVPixelBuffers
│   └── ScreenRecordingPermission.swift   TCC preflight + the stale-grant case
├── Upscale/
│   └── Upscaler.swift            Upscaler protocol, MetalFX + bilinear baseline
├── Render/
│   └── PreviewRenderer.swift     texture cache, GPU pipeline, fps accounting
└── UI/
    └── PreviewWindow.swift       preview window, toolbar, capture lifecycle

scripts/
└── make-signing-cert.sh          one-time self-signed code-signing identity
```

## Design notes

**Coordinate conversion is the sharp edge.** AppKit gives bottom-left-origin
global coordinates; `SCStreamConfiguration.sourceRect` wants top-left-origin
coordinates local to one display. The flip lives in `RegionSelector.finish`
so the rest of the code never has to think about it.

**Capture runs at native pixel density.** The region is measured in points but
captured at `points × backingScaleFactor`. Capturing at point resolution on a
Retina display would discard the detail the upscaler exists to use.

**Frames are blitted into a private texture before upscaling.** Textures vended
by `CVMetalTextureCache` don't advertise the usage flags MetalFX requires. The
blit is one cheap on-GPU copy that avoids a class of intermittent failures.

**Rendering is driven by capture, not a display link.** `MTKView.isPaused` is
`true` and `draw()` is called when a frame arrives, so a static screen costs
nothing. ScreenCaptureKit also emits `.idle` frames when nothing changed; those
are dropped in `ScreenCapture`.

**Windows opt out of `isReleasedWhenClosed`.** Programmatic `NSWindow`s release
themselves on close. The selection overlays are also held in an array, so
leaving the default on double-releases them and segfaults inside the next
CoreAnimation commit. Related: the app does *not* quit when the last window
closes, because the preview window is deliberately hidden while the overlay is
up — it quits when the preview window itself closes.

**The upscaler is behind a protocol.** `MetalFXUpscaler` is the default and
`BilinearUpscaler` is a deliberate baseline — switch between them to see what
MetalFX is actually buying you on your content.

## Known limitations

- **Spatial, not temporal.** `MTLFXSpatialScaler` works from a single frame.
  `MTLFXTemporalScaler` is sharper but needs motion vectors and a depth buffer,
  which screen capture doesn't provide. Spatial is the correct choice here.
- **Scale factor changes restart the stream.** Cheap, but it blinks.
- **No multi-display region spanning.** A selection must sit on one display.
- **Ad-hoc signing without `make cert`.** Permission is lost on every rebuild.
  See "First launch" above.
- **Swift 5 language mode.** `Package.swift` pins `.v5` so the capture callback
  can hand frames across threads without actor ceremony. Moving to `.v6` means
  making the frame handoff properly `Sendable` — a good first refactor.

## Where to take it next

- **Core ML upscaler.** Conform a Real-ESRGAN or BSRGAN model to `Upscaler` and
  A/B it against MetalFX. Quality goes up, framerate goes down; the protocol
  exists so you can measure the trade rather than guess it.
- **Record to file.** Add an `AVAssetWriter` stage after the upscale.
- **Sharpening pass.** A light unsharp mask after MetalFX often reads better on
  text than the scaler alone.
- **Pin to a window** instead of a fixed rect, via `SCContentFilter(desktopIndependentWindow:)`.

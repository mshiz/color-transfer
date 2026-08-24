# Research notes — Lightroom export

Working notes on the "Export Lightroom Profile" feature: why the original
export was broken, what we replaced it with, what we tried that didn't work,
and what's still open. Keep this updated as we learn more — it's meant to
save re-deriving this each time.

## Background

Bruna's contact reported (audio feedback, 2026-08-23): the app's color match
looks right in-browser, but the exported Lightroom preset never reproduces
it on the RAW file — colors come out "zoado" (messed up), even though the
in-app export to JPEG matches perfectly.

## Root cause of the original bug

The app's core effect is a Lab-space mean/std statistical match between the
reference and target photos (computed in `runTransfer()`, `index.html`).
The old `exportXMP()` never had access to those statistics — it only read
the secondary creative sliders (warmth/contrast/saturation/etc., which
default to 0) and mapped them through made-up scale factors onto Lightroom's
Basic-panel sliders. Even at 100% intensity with default sliders, the old
export was close to a no-op in Lightroom, while the in-app result had fully
repainted the colors.

## Fix: export a real color-mapping LUT as a Lightroom Profile

Basic-panel sliders can't represent an arbitrary Lab-space transform — a
completely different approach was needed.

**Key insight:** the app's whole effect (Lab statistical match + the
creative sliders, minus grain) is a *pointwise* function of each pixel's own
RGB value — no dependency on neighboring pixels or image-wide context beyond
the two scalar stat blocks (`rSt`/`tSt`) already computed per photo pair.
That means it can be captured almost exactly as a 3D color lookup table
(LUT) and shipped as a Lightroom Classic camera **Profile** (Develop →
Profile Browser → + → Import Profiles), rather than as a Develop *preset*.

Implementation lives in `index.html`, functions: `transformPixelForLUT`,
`buildTransferLUTSamples`, `buildLookTableBlockData`, `zlibDeflate`,
`encodeZlibBase85`, `md5Hex`, `exportXMP` (now `async`, despite the name —
kept it to avoid touching the `onclick="exportXMP()"` wiring).

### Format details

Adobe's "Enhanced Profile" XMP format embeds a 3D LUT (max 32×32×32) inside
a `crs:PresetType="Look"` profile via:
- `crs:RGBTable="<MD5 hash>"` + `crs:Table_<MD5 hash>="<encoded blob>"`
- The blob: a binary block (16-byte header, one uint16×3 triplet per LUT
  grid point stored as a delta from the identity ramp, 12+16-byte trailer)
  → zlib-deflated → prefixed with a 4-byte uncompressed-size header →
  encoded with a custom base85 variant (alphabet:
  `0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ.-:+=^!/*?`'|()[]{}@%$#`).
- This format isn't officially documented by Adobe. We ported it from the
  open-source [CUBE-to-XMP](https://github.com/13489079165/CUBE-to-XMP)
  tool's `build_xmp`/`encode_zlib_base85` functions (`cube_to_xmp.py`).

### Verification done (no Lightroom install available locally)

- MD5 (hand-rolled, since Web Crypto doesn't do MD5): passes RFC 1321 test
  vectors + a 1280-byte binary buffer, cross-checked against Python `hashlib`.
- `encodeZlibBase85`: byte-for-byte identical output to the Python reference
  across 8 test cases (empty, 1–5 bytes covering all tail-encoding phases,
  and two multi-hundred-byte buffers).
- `buildLookTableBlockData`: bit-identical to the Python reference's block
  construction (one harmless ±1-in-65535 rounding-tie difference from
  `Math.round` vs. Python's banker's rounding on an artificial exact-`.5`
  test value — invisible in real image data).
- Full app run in headless Chromium (Playwright): loads two test images,
  transfer preview renders correctly (visually confirmed via screenshot),
  export completes with no console/page errors, output XML is well-formed
  with matching `RGBTable`/`Table_` hashes.
- **Not verified:** the actual byte-ordering convention Adobe's real
  Lightroom parser expects for the LUT block (there's no public spec; the
  reference tool's own round-trip decoder doesn't even agree with its own
  encoder, so this was reverse-engineered from the encode direction only).
  Real-world testing (below) suggests it's basically correct — the profile
  *does* load and apply, output is "close but not identical," not scrambled.

## Regression: don't add `crs:CameraProfile` inside a `Look` profile

Tried adding `crs:CameraProfile="Camera Standard"` as an attribute inside
our exported `Look`-type profile, hoping to pin the base rendering Lightroom
composites the LUT over. **This broke the file — it stopped showing up in
Lightroom's Profile Browser list at all.** Reverted immediately
(`git`-less project, so just re-edited back).

Best guess: `crs:CameraProfile` is meant for Develop *presets* that
reference a profile by name (a preset says "use this profile"), not for
declaring a base *inside* the profile's own definition — a profile *is*
itself the full color transform, it doesn't have an internal reference to
another one. Adding it likely fails Lightroom's profile-file validation.

**Lesson:** don't guess at undocumented XMP attributes and ship them
without a way to test against real Lightroom first. Any future format
tweak needs the user to test-import before we trust it. This lesson
directly shaped the grain fix below — same category of problem, safer fix.

## Finding: `crs:GrainAmount` inside a `Look` profile is a silent no-op

User confirmed (2026-08-24): grain set via the sliders never renders when
the exported profile is applied in Lightroom, even at the max slider value
(40 → `GrainAmount=100`) — not a UI-display-only quirk (Adobe's docs say
Enhanced Profile settings are "applied as a delta... but do not show in the
UI," so we first suspected it *was* rendering but just not visible in the
Effects panel numbers; user checked the actual pixels at 100% zoom and
confirmed there's truly no grain texture).

Unlike the `crs:CameraProfile` regression above, this doesn't break the
profile — the RGBTable/LUT still works fine, Grain is just silently
ignored. Root cause unconfirmed (no official spec for what Enhanced
Profiles do/don't support), but empirically: Grain doesn't apply as a
profile delta, no matter how it's phrased in the attributes we tried.

**Fix shipped:** stopped putting Grain in the `Look` profile at all (dead
weight). Instead, `exportXMP()` now optionally emits a *second* file when
grain > 0: a standard Develop **Preset** (`crs:PresetType="Normal"` — the
well-established, long-documented kind, unlike Enhanced Profiles) named
`<slug>-grain-preset.xmp`, containing only `crs:GrainAmount`/`GrainSize`/
`GrainFrequency` plus `crs:CameraProfile="<profile name>"` so applying the
preset also selects the color profile — one click gets both. This is a
different, well-established pattern (real preset packs use a Profile +
Preset combo like this) and a lower-risk one: it's a separate file, so if
it doesn't work, the already-confirmed-working profile is untouched.

**Verified against real Lightroom (2026-08-24):** both files import and the
grain preset does render grain and select the profile correctly. Intensity
didn't fully match the app preview at max slider — `GrainAmount` was
already at Lightroom's ceiling (100) at the app's max, so we scaled
`GrainSize` up too (flat 25 → up to 60, `index.html` commit `069c826`),
which helped but didn't fully close the gap.

**Decision: deprioritized, not pursuing further.** User's call — the tool
is about color transfer, grain matching is a secondary nice-to-have, and
exact parity was never fully achievable anyway: the app's grain is uniform
per-pixel noise on a small in-browser canvas, Lightroom's Grain effect is a
resolution/print-size-calibrated procedural texture — different algorithms
on different-sized images, so intensity was always going to be an
approximation, not a fixable bug. Leave `GrainAmount`/`GrainSize` as-is
unless this comes back up.

## Why the result is "close but not identical" (confirmed, not a bug)

User confirmed (2026-08-23): even the *unedited* RAW preview in Lightroom
looks different from what the app previews for the same file, before any
of our processing. This confirms the real structural cause:

1. The app only ever reads a RAW file's **embedded JPEG preview**
   (`extractEmbeddedJpeg()` in `index.html`) — already fully processed by
   the camera's own JPEG engine (picture style, tone curve, white balance).
   There's no RAW demosaic engine in the app (would need something like a
   WASM build of LibRaw), so there's no alternate/more-accurate pixel data
   available to read instead.
2. Lightroom renders RAW files from sensor data with its own color science
   (Adobe Standard by default) — a different starting image entirely.
3. Even a perfect LUT can't fully bridge this: the app's actual match
   algorithm is *adaptive* (it computes the target photo's own Lab mean/std
   at runtime and normalizes relative to that — see `runTransfer()`), but a
   Lightroom profile can only be a *static* pointwise LUT. The LUT was
   calibrated against the JPEG preview's specific pixel statistics; fed a
   differently-distributed RAW rendering, it necessarily drifts. This is an
   architectural ceiling, not something fixable by processing the RAW file
   differently on read.

## Lightroom-side workaround: Raw Defaults → "Camera Settings"

Adobe's own documented mechanism for closing this exact gap. Lightroom
Classic → **Preferences → Presets tab → Raw Defaults → Global** dropdown:
switch from **"Adobe Default"** to **"Camera Settings."** Unlike Adobe
Default (generic Adobe Standard rendering), Camera Settings tries to detect
the in-camera picture style actually used (Canon Picture Style, Fujifilm
Film Simulation, Nikon Picture Control, Sony Creative Style, etc.) and
applies the matching profile + some Basic/Detail-panel values, tracking the
embedded JPEG rendering much more closely than a generic guess.

- Scope: applies going forward, at import time. An already-imported photo
  needs **Photo → Develop Settings → Reset to Default** to pick it up (only
  safe if there are no edits worth keeping on it yet).
- Per-camera instead of global: check **"Override global setting for
  specific cameras"** in the same panel, pick the camera (Marcio/Bruna's
  test camera: **Fujifilm X-T5**), set its Default to **Camera Settings**,
  click **Create Default**.
- **Confirmed misconception, worth remembering:** switching the photo's
  *Profile* (in the Profile Browser) to Adobe Standard or Camera Standard
  and then switching to our custom profile afterward does **not** help —
  profile selection isn't additive/layered, only the last-selected profile
  is used. The Raw Defaults mechanism works through a different channel
  (Basic-panel values that persist independently of Profile selection), not
  through profile pre-selection.
- Not yet confirmed whether this closes the gap enough in practice — pending
  the user's test.

## Open ideas / not yet pursued

- **DNG Profile Editor + ColorChecker calibration** (gold-standard, heavy
  lift): shoot a ColorChecker chart in both RAW and JPEG, use Adobe's free
  DNG Profile Editor to build a custom camera calibration profile that maps
  Lightroom's RAW rendering to match the camera's JPEG engine exactly, per
  camera body. Would fix the baseline-mismatch root cause properly, but is
  a manual one-time-per-camera process, not something the app can automate.
- **In-app note when a RAW is loaded**, e.g. "Preview shown is your
  camera's embedded JPEG — Lightroom's own RAW render will look a bit
  different before edits, see RESEARCH.md" — proposed, not yet added.

## Lightroom Classic plugin (native, no browser)

New effort, separate from the web app: a real Lightroom Classic plugin
(`lightroom-plugin/ColorTransfer.lrplugin/`) so the tool runs inside
Lightroom directly — no browser, no manual file import. Full plan at
the time this was scoped: `/Users/marcioribeiro/.claude/plans/adaptive-tinkering-wigderson.md`.
macOS only for v1.

**Approach:** rather than porting the exact reverse-engineered LUT/XMP
format from the web export (fragile, and Lua has no zlib), the plugin
computes the same Lab color match and creative-slider adjustments, then
represents them as Lightroom's own documented develop settings — three
per-channel `ToneCurvePV2012<Red/Green/Blue>` curves (sampled from the
transform, holding the other two channels at mid-gray) plus native Grain
settings — applied via `LrApplication.addDevelopPresetForPlugin` +
`photo:applyDevelopPreset`. No manual import step at all. Trade-off:
close but not pixel-identical to the web LUT (three independent 1D
curves can't reproduce cross-channel effects a full 3D LUT can), for
reliability and zero friction.

### What's built and verified so far

- `lab.lua` — direct port of `rgbToLab`/`labToRgb`/`computeStats` plus
  the full per-pixel transform (`colorMatchPixel`, `applyCreativeAdjustments`,
  `transformPixel` = both combined, mirroring `transformPixelForLUT` in
  `index.html:715-731` exactly, minus grain). **Verified**: every
  function's output is byte-identical to the real JS implementation,
  cross-checked via a JavaScriptCore (`osascript -l JavaScript`) run of
  the actual extracted JS functions against the same test inputs — 10
  Lab round-trip cases, 25 color-match-only cases, 15 full-transform
  cases (including fade's clamp edges) all match exactly. Repeatable via
  `lua verify_lab.lua`.
- `imageio.lua` — pixel access via shelling out to `sips -s format bmp`
  (found empirically: `sips` does NOT support PPM despite that being the
  original plan — checked `sips --formats` directly rather than assuming)
  and parsing the resulting uncompressed 24bpp BMP in pure Lua. **Verified**:
  `parseBMP` decoded a real sips-generated BMP correctly — dimensions and
  corner pixel values cross-checked two ways (manual `xxd` hex decode of
  the header, and an independent Python/Pillow read of the same file),
  all three agree exactly. Repeatable via `lua verify_imageio.lua <bmp>`.
  The Lightroom-dependent half (`convertToBMP`/`loadPixelsFromFile`, using
  `LrTasks`/`LrPathUtils`) can't be tested outside the plugin runtime.
- `curvefit.lua` — samples `lab.transformPixel` at 17 points per channel
  to build the `ToneCurvePV2012` point arrays. No JS equivalent exists to
  cross-check against (new logic, not a port) — verified structurally
  instead: correct point count, strictly increasing input values, output
  clamped to [0,255], and confirmed intensity=0 + no creative adjustment
  produces the exact identity curve. Repeatable via `lua verify_curvefit.lua`.

### Open risk: develop-settings table field names (blocking `developsettings.lua`)

The Lua table shape `addDevelopPresetForPlugin`/`getDevelopSettings` use
is only partially confirmed. `Contrast2012`, `Highlights2012`,
`Shadows2012`, `Whites2012`, `Blacks2012`, `Vibrance`, `Saturation`,
`GrainAmount`, `GrainSize`, `GrainFrequency` look solid — they match the
already-proven XMP attribute names. The tone-curve fields are genuinely
uncertain: some sources mention a newer `ExtendedToneCurvePV2012<Channel>`
alongside/replacing `ToneCurvePV2012<Channel>`, possibly needing a
companion `EnableToneCurve` flag — and Adobe's own community threads
describe this area as *"documentation is incomplete... refer to
community resources or reverse-engineering."* Same category of risk that
broke the profile import twice on the web export side (`crs:CameraProfile`
regression, silent grain no-op) — not guessing again without a
ground-truth check first (user's explicit call).

**Diagnostic built to resolve this** (`DumpDevelopSettings.lua`, wired
into `Info.lua` as a Plug-in Extras menu item): dumps
`photo:getDevelopSettings()` for the current photo to
`~/Desktop/color-transfer-develop-settings-dump.lua` via the `serialize.lua`
helper (verified standalone against a synthetic nested table — correct
nesting, array-compaction, string quoting). Next step: install the
plugin skeleton in Lightroom, manually apply a custom RGB tone curve to
a test photo, run the diagnostic, and read back the real field names
before writing `developsettings.lua` against them.

### Not yet built

`developsettings.lua` (blocked on the above), `ColorTransferMain.lua`
(the actual panel UI — sliders, reference/target pickers, apply button),
`ColorTransferMenuItem.lua`. None of this can be verified without a real
Lightroom Classic install — expect iteration rounds once the user tests,
same pattern as the web export work.

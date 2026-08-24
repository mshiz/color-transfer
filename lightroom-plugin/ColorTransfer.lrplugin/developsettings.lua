-- Assembles the develop-settings table passed to
-- LrApplication.addDevelopPresetForPlugin / photo:applyDevelopPreset.
--
-- Field names and the required companion flags (EnableToneCurve,
-- ToneCurveName2012, the base ToneCurvePV2012 identity curve) were
-- confirmed against a real photo:getDevelopSettings() dump from actual
-- Lightroom Classic (see RESEARCH.md, 2026-08-24) rather than guessed —
-- the tone-curve field names were genuinely undocumented before that.
--
-- Only grain sits outside the curves (not a pointwise function of a
-- pixel, can't live in a 1D response curve). Everything else the app
-- does to a pixel (color match + warmth/contrast/saturation/highlights/
-- shadows/fade) is baked into the three RGB tone curves by curvefit.lua,
-- which samples lab.transformPixel — so the Basic-panel tone fields
-- (Contrast2012 etc.) are explicitly zeroed here, not used to represent
-- the adjustments. That avoids double-applying if the target photo had
-- prior manual edits in those same fields.

local M = {}

-- curves: { red = {...}, green = {...}, blue = {...} } from curvefit.lua
-- grain: { amount = N, size = N, frequency = N } (0s if unused)
function M.build(curves, grain)
  return {
    EnableToneCurve = true,
    ToneCurveName2012 = "Custom",
    ToneCurvePV2012 = { 0, 0, 255, 255 },
    ToneCurvePV2012Red = curves.red,
    ToneCurvePV2012Green = curves.green,
    ToneCurvePV2012Blue = curves.blue,

    EnableEffects = true,
    GrainAmount = grain.amount,
    GrainSize = grain.size,
    GrainFrequency = grain.frequency,

    -- Explicitly zeroed: the look is fully carried by the curves above,
    -- these are here so a photo with prior manual edits in these fields
    -- doesn't stack on top of what the curves already encode.
    Contrast2012 = 0,
    Highlights2012 = 0,
    Shadows2012 = 0,
    Whites2012 = 0,
    Blacks2012 = 0,
    Vibrance = 0,
    Saturation = 0,
  }
end

-- Same grain scale factors already verified against real Lightroom via
-- the web app's export (RESEARCH.md, GrainSize scaling commit 069c826).
-- grainSlider: 0-40, matching index.html's sl-grain range.
function M.grainSettingsFromSlider(grainSlider)
  if not grainSlider or grainSlider <= 0 then
    return { amount = 0, size = 0, frequency = 0 }
  end
  return {
    amount = math.min(100, math.floor(grainSlider * 2.5 + 0.5)),
    size = math.floor(15 + (grainSlider / 40) * 45 + 0.5),
    frequency = 50,
  }
end

return M

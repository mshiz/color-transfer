-- CIE Lab color conversion + basic statistics.
-- Direct port of rgbToLab/labToRgb/computeStats from ../../index.html
-- (sRGB <-> linear -> XYZ (D65) -> Lab). Kept numerically identical to
-- the JS version -- see verify_lab.lua for a cross-check against known
-- JS outputs.

local M = {}

local function cbrt(v)
  if v >= 0 then return v ^ (1 / 3) end
  return -((-v) ^ (1 / 3))
end

-- r,g,b in [0,1] (sRGB, gamma-encoded) -> L,A,B
function M.rgbToLab(r, g, b)
  r = (r > 0.04045) and (((r + 0.055) / 1.055) ^ 2.4) or (r / 12.92)
  g = (g > 0.04045) and (((g + 0.055) / 1.055) ^ 2.4) or (g / 12.92)
  b = (b > 0.04045) and (((b + 0.055) / 1.055) ^ 2.4) or (b / 12.92)

  local function f(v)
    if v > 0.008856 then return cbrt(v) end
    return 7.787 * v + 16 / 116
  end

  local x = f((r * 0.4124 + g * 0.3576 + b * 0.1805) / 0.95047)
  local y = f(r * 0.2126 + g * 0.7152 + b * 0.0722)
  local z = f((r * 0.0193 + g * 0.1192 + b * 0.9505) / 1.08883)

  return 116 * y - 16, 500 * (x - y), 200 * (y - z)
end

-- L,A,B -> r,g,b in [0,1] (sRGB, gamma-encoded, NOT clamped)
function M.labToRgb(L, A, B)
  local function finv(v)
    if v > 0.206897 then return v * v * v end
    return (v - 16 / 116) / 7.787
  end

  local y0 = (L + 16) / 116
  local x = finv(A / 500 + y0) * 0.95047
  local y = finv(y0)
  local z = finv(y0 - B / 200) * 1.08883

  local function gamma(v)
    if v > 0.0031308 then return 1.055 * (v ^ (1 / 2.4)) - 0.055 end
    return 12.92 * v
  end

  local r = gamma(x * 3.2406 + y * (-1.5372) + z * (-0.4986))
  local g = gamma(x * (-0.9689) + y * 1.8758 + z * 0.0415)
  local bch = gamma(x * 0.0557 + y * (-0.204) + z * 1.057)
  return r, g, bch
end

function M.clamp01(v)
  if v < 0 then return 0 end
  if v > 1 then return 1 end
  return v
end

-- labArray: flat 1-indexed table {L1,A1,B1, L2,A2,B2, ...}
-- returns { mean = {L,A,B}, std = {L,A,B} }
-- Core color-match transform (the Lab mean/std blend), WITHOUT the
-- creative-slider tail (warmth/contrast/etc. — those are applied
-- separately as native Lightroom develop settings by developsettings.lua,
-- not baked into this transform). Mirrors the Lab-blend portion of
-- transformPixelForLUT in ../../index.html:715-723.
-- rSt/tSt: { mean = {L,A,B}, std = {L,A,B} }. intensity: 0..1.
function M.colorMatchPixel(r, g, b, rSt, tSt, intensity)
  local L, A, B = M.rgbToLab(r, g, b)
  local labIn = { L, A, B }
  local labOut = { 0, 0, 0 }
  for c = 1, 3 do
    local n = (labIn[c] - tSt.mean[c]) / (tSt.std[c] + 1e-6)
    labOut[c] = labIn[c] * (1 - intensity) + (n * rSt.std[c] + rSt.mean[c]) * intensity
  end
  local rr, gg, bb = M.labToRgb(labOut[1], labOut[2], labOut[3])
  return M.clamp01(rr), M.clamp01(gg), M.clamp01(bb)
end

-- Direct port of the creative-slider tail from transformPixelForLUT in
-- ../../index.html:724-730 (warmth/contrast/saturation/highlights/
-- shadows/fade -- everything except grain, which isn't a pointwise
-- function of the pixel and can't live in a curve or LUT).
-- adj: { warmth=, contrast=, saturation=, highlights=, shadows=, fade= }
-- (any field may be 0/nil; grain is intentionally not a field here)
function M.applyCreativeAdjustments(r, g, b, adj)
  if adj.warmth and adj.warmth ~= 0 then
    local w = adj.warmth / 100
    r = M.clamp01(r + w * 0.08)
    b = M.clamp01(b - w * 0.06)
  end
  if adj.contrast and adj.contrast ~= 0 then
    local c = 1 + adj.contrast / 100
    r = M.clamp01((r - 0.5) * c + 0.5)
    g = M.clamp01((g - 0.5) * c + 0.5)
    b = M.clamp01((b - 0.5) * c + 0.5)
  end
  if adj.saturation and adj.saturation ~= 0 then
    local s = 1 + adj.saturation / 100
    local lm = 0.299 * r + 0.587 * g + 0.114 * b
    r = M.clamp01(lm + (r - lm) * s)
    g = M.clamp01(lm + (g - lm) * s)
    b = M.clamp01(lm + (b - lm) * s)
  end
  local lum = 0.299 * r + 0.587 * g + 0.114 * b
  if adj.highlights and adj.highlights ~= 0 and lum > 0.6 then
    local t = (lum - 0.6) / 0.4
    local h = adj.highlights / 200
    r = M.clamp01(r + h * t)
    g = M.clamp01(g + h * t)
    b = M.clamp01(b + h * t)
  end
  if adj.shadows and adj.shadows ~= 0 and lum < 0.4 then
    local t = (0.4 - lum) / 0.4
    local s = adj.shadows / 200
    r = M.clamp01(r + s * t)
    g = M.clamp01(g + s * t)
    b = M.clamp01(b + s * t)
  end
  if adj.fade and adj.fade > 0 then
    local f = adj.fade / 100 * 0.4
    r = M.clamp01(r * (1 - f) + 0.75 * f)
    g = M.clamp01(g * (1 - f) + 0.75 * f)
    b = M.clamp01(b * (1 - f) + 0.75 * f)
  end
  return r, g, b
end

-- Full per-pixel transform: color match + creative tail, everything the
-- app does to a pixel except grain. Mirrors transformPixelForLUT in
-- ../../index.html:715-731 exactly.
function M.transformPixel(r, g, b, rSt, tSt, intensity, adj)
  local mr, mg, mb = M.colorMatchPixel(r, g, b, rSt, tSt, intensity)
  return M.applyCreativeAdjustments(mr, mg, mb, adj)
end

function M.computeStats(labArray)
  local n = #labArray / 3
  local mean = { 0, 0, 0 }
  for i = 1, #labArray, 3 do
    mean[1] = mean[1] + labArray[i]
    mean[2] = mean[2] + labArray[i + 1]
    mean[3] = mean[3] + labArray[i + 2]
  end
  mean[1] = mean[1] / n
  mean[2] = mean[2] / n
  mean[3] = mean[3] / n

  local std = { 0, 0, 0 }
  for i = 1, #labArray, 3 do
    std[1] = std[1] + (labArray[i] - mean[1]) ^ 2
    std[2] = std[2] + (labArray[i + 1] - mean[2]) ^ 2
    std[3] = std[3] + (labArray[i + 2] - mean[3]) ^ 2
  end
  std[1] = math.sqrt(std[1] / n)
  std[2] = math.sqrt(std[2] / n)
  std[3] = math.sqrt(std[3] / n)

  return { mean = mean, std = std }
end

return M

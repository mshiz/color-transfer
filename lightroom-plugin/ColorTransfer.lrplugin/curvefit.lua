-- Builds Lightroom-native per-channel tone curves that approximate the
-- app's full per-pixel transform (Lab color match + the creative-slider
-- tail — warmth/contrast/saturation/highlights/shadows/fade — everything
-- lab.transformPixel does except grain, which isn't a pointwise function
-- and gets its own native Grain settings instead, same as the web app).
--
-- There's no exact equivalent here: the web app bakes the transform into
-- a 3D LUT (arbitrary function of R,G,B jointly); Lightroom's
-- ToneCurvePV2012<Channel> settings are three independent 1D curves (each
-- channel a function of itself alone). This samples the transform holding
-- the other two channels at mid-gray, which captures the dominant
-- per-channel response well but can't reproduce cross-channel effects
-- (e.g. shifting only saturated reds without touching desaturated reds)
-- — see the plan/RESEARCH.md for that trade-off and why it was chosen
-- anyway (reliability + zero manual import > pixel-exact match).

local lab = require("lab")

local M = {}

-- 17 points is comfortably within what Lightroom's point-curve format
-- accepts and gives a reasonably smooth fit without being excessive.
M.NUM_POINTS = 17

local CHANNEL_INDEX = { r = 1, g = 2, b = 3 }

local function buildChannelCurve(channel, rSt, tSt, intensity, adj)
  local GRAY = 0.5
  local ci = CHANNEL_INDEX[channel]
  local points = {}
  for i = 0, M.NUM_POINTS - 1 do
    local level = i / (M.NUM_POINTS - 1) -- 0..1
    local r, g, b = GRAY, GRAY, GRAY
    if channel == "r" then r = level
    elseif channel == "g" then g = level
    else b = level end

    local outRGB = { lab.transformPixel(r, g, b, rSt, tSt, intensity, adj) }
    local outVal = outRGB[ci]

    local inPoint = math.floor(level * 255 + 0.5)
    local outPoint = math.floor(lab.clamp01(outVal) * 255 + 0.5)
    points[#points + 1] = inPoint
    points[#points + 1] = outPoint
  end
  return points
end

-- rSt, tSt: { mean = {L,A,B}, std = {L,A,B} } from lab.computeStats
-- intensity: 0..1
-- adj: { warmth=, contrast=, saturation=, highlights=, shadows=, fade= }
-- returns { red = {in0,out0, in1,out1, ...}, green = {...}, blue = {...} }
-- flat point arrays in 0-255 space, ready for
-- crs:ToneCurvePV2012Red/Green/Blue.
function M.buildToneCurves(rSt, tSt, intensity, adj)
  return {
    red = buildChannelCurve("r", rSt, tSt, intensity, adj),
    green = buildChannelCurve("g", rSt, tSt, intensity, adj),
    blue = buildChannelCurve("b", rSt, tSt, intensity, adj),
  }
end

return M

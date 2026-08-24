-- Standalone check: run with `lua verify_lab.lua` (needs a Lua interpreter,
-- not part of the plugin itself). Confirms lab.lua's output for a set of
-- known RGB values, cross-checked against the JS implementation in
-- ../../index.html via a JavaScriptCore run -- see RESEARCH.md for the
-- verification log. Values below were captured from that run.

package.path = package.path .. ";" .. (arg[0]:match("(.*/)") or "./") .. "?.lua"
local lab = require("lab")

local cases = {
  { input = {0,0,0},               expected = {0.00000000,0.00000000,0.00000000} },
  { input = {1,1,1},                expected = {100.00000000,0.00526050,-0.01040818} },
  { input = {0.5,0.5,0.5},          expected = {53.38896474,0.00314673,-0.00622598} },
  { input = {1,0,0},                expected = {53.23288179,80.10930953,67.22006831} },
  { input = {0,1,0},                expected = {87.73703347,-86.18463650,83.18116475} },
  { input = {0,0,1},                expected = {32.30258667,79.19666179,-107.86368104} },
  { input = {0.8,0.2,0.3},          expected = {46.62329753,60.40174372,22.42260151} },
  { input = {0.1,0.9,0.4},          expected = {80.45336015,-71.68646839,48.87839659} },
  { input = {0.234,0.567,0.891},    expected = {58.63213169,2.04676939,-49.20252201} },
  { input = {0.9,0.05,0.6},         expected = {51.06158066,80.45433179,-17.13276618} },
}

local allPass = true
for _, c in ipairs(cases) do
  local r, g, b = c.input[1], c.input[2], c.input[3]
  local L, A, B = lab.rgbToLab(r, g, b)
  local ok = math.abs(L - c.expected[1]) < 1e-6
    and math.abs(A - c.expected[2]) < 1e-6
    and math.abs(B - c.expected[3]) < 1e-6
  if not ok then allPass = false end
  print(string.format("%s %g,%g,%g -> %.8f,%.8f,%.8f", ok and "PASS" or "FAIL", r, g, b, L, A, B))
end
print(allPass and "ALL PASS" or "SOME FAILED")

-- transformPixel (color match + full creative tail, minus grain) --
-- cross-checked against ../../index.html's transformPixelForLUT via a
-- JavaScriptCore run with the same rSt/tSt/intensity/adj. See RESEARCH.md.
local rSt = { mean = {55, 12, -8}, std = {18, 9, 11} }
local tSt = { mean = {42, -3, 15}, std = {22, 14, 7} }
local intensity = 0.7
local adj = { warmth = 20, contrast = -15, saturation = 30, highlights = -25, shadows = 18, fade = 12 }

local transformCases = {
  { input = {0.5,0.5,0.5},  expected = {0.5784177563,0.5565499390,0.7206034107} },
  { input = {0,0.5,0.5},    expected = {0.1771745888,0.5879394223,0.7799880440} },
  { input = {0.25,0.5,0.5}, expected = {0.3415417786,0.5748045795,0.7603927963} },
  { input = {0.75,0.5,0.5}, expected = {0.8038261641,0.5331280522,0.6568589992} },
  { input = {1,0.5,0.5},    expected = {0.9641297928,0.5167634559,0.5826402654} },
  { input = {0.5,0,0.5},    expected = {0.4587945918,0.2830397614,0.9056151143} },
  { input = {0.5,0.25,0.5}, expected = {0.5011132029,0.3804669666,0.8394768497} },
  { input = {0.5,0.75,0.5}, expected = {0.6258587135,0.7164504547,0.5636907947} },
  { input = {0.5,1,0.5},    expected = {0.6628720948,0.8696997829,0.3968830392} },
  { input = {0.5,0.5,0},    expected = {0.6927408008,0.5571478915,0.0972156140} },
  { input = {0.5,0.5,0.25}, expected = {0.6659166453,0.5532939028,0.3647269997} },
  { input = {0.5,0.5,0.75}, expected = {0.3482904398,0.5798839741,0.9880000000} },
  { input = {0.5,0.5,1},    expected = {0.0360000000,0.6276974917,0.9880000000} },
  { input = {0.9,0.1,0.3},  expected = {0.9880000000,0.3042816267,0.4400546535} },
  { input = {0.05,0.6,0.95},expected = {0.0360000000,0.6918770947,0.9880000000} },
}

local transformAllPass = true
for _, c in ipairs(transformCases) do
  local r, g, b = c.input[1], c.input[2], c.input[3]
  local rr, gg, bb = lab.transformPixel(r, g, b, rSt, tSt, intensity, adj)
  local ok = math.abs(rr - c.expected[1]) < 1e-6
    and math.abs(gg - c.expected[2]) < 1e-6
    and math.abs(bb - c.expected[3]) < 1e-6
  if not ok then transformAllPass = false end
  print(string.format("%s transformPixel(%g,%g,%g) -> %.10f,%.10f,%.10f", ok and "PASS" or "FAIL", r, g, b, rr, gg, bb))
end
print(transformAllPass and "ALL PASS" or "SOME FAILED")

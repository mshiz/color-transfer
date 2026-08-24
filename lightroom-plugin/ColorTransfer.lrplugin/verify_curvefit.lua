-- Standalone sanity check: run with `lua verify_curvefit.lua`.
-- There's no JS equivalent to cross-check against (this logic is new to
-- the plugin, the web app never built tone curves), so this just checks
-- structural sanity: correct point count, strictly increasing x, y in
-- [0,255], and prints the curves for a manual look.

package.path = package.path .. ";" .. (arg[0]:match("(.*/)") or "./") .. "?.lua"
local lab = require("lab")
local curvefit = require("curvefit")

local rSt = { mean = {55, 12, -8}, std = {18, 9, 11} }
local tSt = { mean = {42, -3, 15}, std = {22, 14, 7} }
local adj = { warmth = 20, contrast = -15, saturation = 30, highlights = -25, shadows = 18, fade = 12 }

local function checkCurve(name, points)
  local ok = true
  if #points ~= curvefit.NUM_POINTS * 2 then
    print("FAIL " .. name .. ": expected " .. (curvefit.NUM_POINTS * 2) .. " values, got " .. #points)
    ok = false
  end
  local lastX = -1
  for i = 1, #points, 2 do
    local x, y = points[i], points[i + 1]
    if x <= lastX then
      print("FAIL " .. name .. ": x not strictly increasing at index " .. i .. " (" .. x .. " <= " .. lastX .. ")")
      ok = false
    end
    if y < 0 or y > 255 then
      print("FAIL " .. name .. ": y out of range at index " .. i .. " (" .. y .. ")")
      ok = false
    end
    lastX = x
  end
  local parts = {}
  for i = 1, #points, 2 do
    parts[#parts + 1] = string.format("(%d,%d)", points[i], points[i + 1])
  end
  print((ok and "PASS " or "") .. name .. ": " .. table.concat(parts, " "))
  return ok
end

local noAdj = { warmth = 0, contrast = 0, saturation = 0, highlights = 0, shadows = 0, fade = 0 }

local allOk = true
for _, intensity in ipairs({ 0.0, 0.5, 0.8, 1.0 }) do
  print("--- intensity = " .. intensity .. " (with creative adj) ---")
  local curves = curvefit.buildToneCurves(rSt, tSt, intensity, adj)
  allOk = checkCurve("red", curves.red) and allOk
  allOk = checkCurve("green", curves.green) and allOk
  allOk = checkCurve("blue", curves.blue) and allOk
end

-- intensity 0 AND no creative adj should be very close to the identity
-- curve (in == out at every point) -- not exact identity because the
-- OTHER two channels being held at gray still pass through a Lab
-- round-trip, but the swept channel's response should track closely.
local zeroCurves = curvefit.buildToneCurves(rSt, tSt, 0.0, noAdj)
local maxDelta = 0
for i = 1, #zeroCurves.red, 2 do
  local d = math.abs(zeroCurves.red[i] - zeroCurves.red[i + 1])
  if d > maxDelta then maxDelta = d end
end
print(string.format("max |in-out| on red curve at intensity=0: %d (expect small, Lab round-trip noise only)", maxDelta))

print(allOk and "ALL STRUCTURAL CHECKS PASS" or "SOME CHECKS FAILED")

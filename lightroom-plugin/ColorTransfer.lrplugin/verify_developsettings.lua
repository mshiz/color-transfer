-- Standalone check: run with `lua verify_developsettings.lua`.
-- Confirms grainSettingsFromSlider matches the exact values already
-- verified against real Lightroom via the web export (RESEARCH.md,
-- commit 069c826: grain=40 -> GrainAmount=100, GrainSize=60), and that
-- M.build produces a table with the confirmed-required companion fields.

package.path = package.path .. ";" .. (arg[0]:match("(.*/)") or "./") .. "?.lua"
local developsettings = require("developsettings")

local allPass = true
local function check(name, got, expected)
  local ok = got == expected
  if not ok then allPass = false end
  print(string.format("%s %s: got %s, expected %s", ok and "PASS" or "FAIL", name, tostring(got), tostring(expected)))
end

local g0 = developsettings.grainSettingsFromSlider(0)
check("grain=0 amount", g0.amount, 0)
check("grain=0 size", g0.size, 0)

local g40 = developsettings.grainSettingsFromSlider(40)
check("grain=40 amount", g40.amount, 100)
check("grain=40 size", g40.size, 60)

local curves = { red = {0,0,255,255}, green = {0,0,255,255}, blue = {0,0,255,255} }
local settings = developsettings.build(curves, g40)
check("EnableToneCurve", settings.EnableToneCurve, true)
check("ToneCurveName2012", settings.ToneCurveName2012, "Custom")
check("GrainAmount", settings.GrainAmount, 100)
check("Contrast2012 zeroed", settings.Contrast2012, 0)

print(allPass and "ALL PASS" or "SOME FAILED")

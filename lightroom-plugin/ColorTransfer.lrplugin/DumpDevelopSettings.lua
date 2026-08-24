-- Diagnostic tool, not part of the final feature: dumps the current
-- photo's develop settings table to a file on the Desktop so we can see
-- the real field names this Lightroom version uses (e.g. for tone
-- curves) before developsettings.lua is written against them.
--
-- Usage: in Lightroom, manually apply a custom RGB tone curve edit to a
-- photo (Develop module > Tone Curve panel > switch to "Point Curve" /
-- drag the Red/Green/Blue channel curves), select that photo, then run
-- File > Plug-in Extras > "Color Transfer: Dump Develop Settings
-- (diagnostic)". Share the resulting file's contents.

local LrApplication = import("LrApplication")
local LrTasks = import("LrTasks")
local LrDialogs = import("LrDialogs")
local LrPathUtils = import("LrPathUtils")

local serialize = require("serialize")

LrTasks.startAsyncTask(function()
  local catalog = LrApplication.activeCatalog()
  local photo = catalog:getTargetPhoto()

  if not photo then
    LrDialogs.message("Color Transfer", "Select a photo in Lightroom first, then run this again.", "warning")
    return
  end

  local ok, settingsOrErr = pcall(function()
    return photo:getDevelopSettings()
  end)

  if not ok then
    LrDialogs.message("Color Transfer", "photo:getDevelopSettings() failed:\n" .. tostring(settingsOrErr), "critical")
    return
  end

  local okPath, photoPath = pcall(function() return photo:getRawMetadata("path") end)
  local text = serialize.dump(settingsOrErr)

  local desktop = LrPathUtils.getStandardFilePath("desktop")
  local outPath = LrPathUtils.child(desktop, "color-transfer-develop-settings-dump.lua")

  local f, openErr = io.open(outPath, "w")
  if not f then
    LrDialogs.message("Color Transfer", "Could not write to " .. outPath .. ":\n" .. tostring(openErr), "critical")
    return
  end
  f:write("-- Dumped via Color Transfer plugin diagnostic.\n")
  f:write("-- Photo: " .. tostring(okPath and photoPath or "unknown") .. "\n")
  f:write("return " .. text .. "\n")
  f:close()

  LrDialogs.message(
    "Color Transfer",
    "Develop settings dumped to:\n" .. outPath .. "\n\nPlease share this file's contents.",
    "info"
  )
end)

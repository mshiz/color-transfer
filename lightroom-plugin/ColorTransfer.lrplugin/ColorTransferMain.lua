-- Main panel: pick a reference image, adjust sliders, apply to the
-- currently-selected photo. Ties together lab.lua (color math),
-- imageio.lua (pixel access), curvefit.lua (tone curve generation), and
-- developsettings.lua (assembling the settings table).
--
-- Applies via photo:applyDevelopSettings() directly (not
-- addDevelopPresetForPlugin + applyDevelopPresetFromPlugin) -- simpler,
-- and sidesteps a reported bug where the preset-based path can reset
-- White Balance on photos with prior WB edits or Smart Previews, even
-- when WhiteBalance isn't in the settings table (see RESEARCH.md).

local LrApplication = import("LrApplication")
local LrView = import("LrView")
local LrDialogs = import("LrDialogs")
local LrFunctionContext = import("LrFunctionContext")
local LrBinding = import("LrBinding")
local LrTasks = import("LrTasks")
local LrPathUtils = import("LrPathUtils")

local lab = require("lab")
local imageio = require("imageio")
local curvefit = require("curvefit")
local developsettings = require("developsettings")

local SLIDER_SPECS = {
  { key = "intensity", title = "Intensity", min = 0, max = 100, default = 80 },
  { key = "warmth", title = "Warmth", min = -50, max = 50, default = 0 },
  { key = "contrast", title = "Contrast", min = -50, max = 50, default = 0 },
  { key = "saturation", title = "Saturation", min = -50, max = 50, default = 0 },
  { key = "highlights", title = "Highlights", min = -50, max = 50, default = 0 },
  { key = "shadows", title = "Shadows", min = -50, max = 50, default = 0 },
  { key = "fade", title = "Fade", min = 0, max = 60, default = 0 },
  { key = "grain", title = "Grain", min = 0, max = 40, default = 0 },
}

-- Pixel stats (Lab mean/std) don't need full resolution -- downscale
-- during the sips conversion so a large RAW target file isn't decoded
-- at full native resolution just to be looped over pixel-by-pixel in
-- pure Lua.
local STATS_MAX_DIMENSION = 800

-- Converts flat RGB byte pixels (0-255) into Lab mean/std stats.
local function statsFromPixels(pixels)
  local n = #pixels / 3
  local labFlat = {}
  for i = 0, n - 1 do
    local r = pixels[i * 3 + 1] / 255
    local g = pixels[i * 3 + 2] / 255
    local b = pixels[i * 3 + 3] / 255
    local L, A, B = lab.rgbToLab(r, g, b)
    labFlat[i * 3 + 1] = L
    labFlat[i * 3 + 2] = A
    labFlat[i * 3 + 3] = B
  end
  return lab.computeStats(labFlat)
end

local function statsFromFile(path)
  local img = imageio.loadPixelsFromFile(path, STATS_MAX_DIMENSION)
  return statsFromPixels(img.pixels)
end

-- Originally used photo:requestJpegThumbnail (callback-based, adapted to
-- a synchronous-looking call via a yield-poll loop). Dropped that after
-- two real-Lightroom failures in a row (even after fixing a missing
-- held-reference bug per the SDK docs' own warning) -- it has a known
-- reputation for being slow/unreliable when Lightroom hasn't already
-- cached a preview for that photo. `sips` can decode the original file
-- directly (including most RAW formats), so this just reuses the same
-- proven path as the reference image instead of going through Lightroom
-- at all for pixel access. See RESEARCH.md for the two failed rounds
-- with requestJpegThumbnail before this change.
local function statsFromTargetPhoto(photo)
  local ok, path = LrTasks.pcall(function() return photo:getRawMetadata("path") end)
  if not ok or not path then
    error("Could not get the file path for the selected photo.")
  end
  return statsFromFile(path)
end

local function showDialog()
  LrFunctionContext.callWithContext("colorTransferMain", function(context)
    local f = LrView.osFactory()
    local props = LrBinding.makePropertyTable(context)

    for _, spec in ipairs(SLIDER_SPECS) do
      props[spec.key] = spec.default
    end
    props.profileName = ""
    props.referencePath = ""
    props.referenceLabel = "No reference chosen"
    props.statusText = "Choose a reference image, then Apply."

    local catalog = LrApplication.activeCatalog()
    local targetPhoto = catalog:getTargetPhoto()

    local function chooseReference()
      local paths = LrDialogs.runOpenPanel({
        title = "Choose reference image",
        canChooseFiles = true,
        canChooseDirectories = false,
        allowsMultipleSelection = false,
        fileTypes = { "jpg", "jpeg", "png", "tif", "tiff", "heic", "bmp" },
      })
      if paths and paths[1] then
        props.referencePath = paths[1]
        props.referenceLabel = LrPathUtils.leafName(paths[1])
        if props.profileName == "" then
          props.profileName = LrPathUtils.removeExtension(LrPathUtils.leafName(paths[1]))
        end
      end
    end

    local function apply()
      if props.referencePath == "" then
        LrDialogs.message("Color Transfer", "Choose a reference image first.", "warning")
        return
      end
      if not targetPhoto then
        LrDialogs.message("Color Transfer", "Select a photo in Lightroom first, then reopen this dialog.", "warning")
        return
      end

      local referencePath = props.referencePath
      local sliderValues = {}
      for _, spec in ipairs(SLIDER_SPECS) do
        sliderValues[spec.key] = props[spec.key]
      end
      local historyName = (props.profileName ~= "" and props.profileName) or "Color Transfer"

      LrTasks.startAsyncTask(function()
        local ok, err = LrTasks.pcall(function()
          props.statusText = "Analyzing reference image..."
          local rSt = statsFromFile(referencePath)

          props.statusText = "Analyzing target photo..."
          local tSt = statsFromTargetPhoto(targetPhoto)

          props.statusText = "Computing tone curves..."
          local intensity = sliderValues.intensity / 100
          local adj = {
            warmth = sliderValues.warmth,
            contrast = sliderValues.contrast,
            saturation = sliderValues.saturation,
            highlights = sliderValues.highlights,
            shadows = sliderValues.shadows,
            fade = sliderValues.fade,
          }
          local curves = curvefit.buildToneCurves(rSt, tSt, intensity, adj)
          local grain = developsettings.grainSettingsFromSlider(sliderValues.grain)
          local settings = developsettings.build(curves, grain)

          props.statusText = "Applying to photo..."
          catalog:withWriteAccessDo(historyName, function()
            targetPhoto:applyDevelopSettings(settings, historyName)
          end)

          props.statusText = "Applied \"" .. historyName .. "\" to the selected photo."
        end)
        if not ok then
          props.statusText = "Error — see dialog."
          LrDialogs.message("Color Transfer", tostring(err), "critical")
        end
      end)
    end

    local sliderRows = {}
    for _, spec in ipairs(SLIDER_SPECS) do
      sliderRows[#sliderRows + 1] = f:row {
        f:static_text { title = spec.title, width = 80 },
        f:slider {
          value = LrView.bind(spec.key),
          min = spec.min,
          max = spec.max,
          width = 200,
        },
        f:static_text { title = LrView.bind(spec.key), width = 40 },
      }
    end

    local targetRow
    if targetPhoto then
      targetRow = f:row {
        f:static_text { title = "Target (current selection):" },
        f:catalog_photo { photo = targetPhoto, width = 80, height = 80 },
      }
    else
      targetRow = f:static_text { title = "No photo selected in Lightroom — select one, then reopen this dialog." }
    end

    -- Built as a plain array + table.insert rather than a literal
    -- {a, b, unpack(sliderRows), c} constructor -- table.unpack is Lua
    -- 5.2+ only (plain `unpack` in 5.1), and Lightroom's Lua version
    -- isn't worth gambling on here.
    local children = { bind_to_object = props, spacing = f:control_spacing() }
    table.insert(children, targetRow)
    table.insert(children, f:row {
      f:push_button { title = "Choose Reference Image...", action = chooseReference },
      f:static_text { title = LrView.bind("referenceLabel") },
    })
    table.insert(children, f:row {
      f:static_text { title = "Name", width = 80 },
      f:edit_field { value = LrView.bind("profileName"), width = 240 },
    })
    table.insert(children, f:separator { fill_horizontal = 1 })
    for _, row in ipairs(sliderRows) do
      table.insert(children, row)
    end
    table.insert(children, f:separator { fill_horizontal = 1 })
    table.insert(children, f:static_text { title = LrView.bind("statusText"), width = 320, height_in_lines = 2 })
    table.insert(children, f:row { f:push_button { title = "Apply", action = apply } })

    local contents = f:column(children)

    LrDialogs.presentModalDialog({
      title = "Color Transfer",
      contents = contents,
    })
  end)
end

LrTasks.startAsyncTask(showDialog)

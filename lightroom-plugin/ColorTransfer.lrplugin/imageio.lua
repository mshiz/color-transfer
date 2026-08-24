-- Image pixel access for the plugin.
--
-- Lightroom's Lua sandbox has no image decoder and no zlib, so pixel data
-- comes from shelling out to `sips` (built into every Mac) to convert an
-- arbitrary image file to an uncompressed 24-bit BMP, which is simple
-- enough to parse in pure Lua (fixed header, raw BGR bytes, no
-- compression). macOS only -- see RESEARCH.md / the plan for why.
--
-- Split in two for testability: parseBMP is pure (no Lightroom APIs,
-- verified standalone against a real sips-generated file -- see
-- verify_imageio.lua). convertToBMP/loadPixels below it depend on
-- LrTasks/LrFileUtils and can only run inside Lightroom.

local M = {}

local function u16(bytes, off) -- off is 0-indexed byte offset
  local b1, b2 = bytes:byte(off + 1, off + 2)
  return b1 + b2 * 256
end

local function u32(bytes, off)
  local b1, b2, b3, b4 = bytes:byte(off + 1, off + 4)
  return b1 + b2 * 256 + b3 * 65536 + b4 * 16777216
end

local function i32(bytes, off)
  local v = u32(bytes, off)
  if v >= 0x80000000 then v = v - 0x100000000 end
  return v
end

-- Parses raw BMP file bytes (uncompressed BI_RGB only, either 24bpp BGR
-- or 32bpp BGRA -- `sips -s format bmp` writes 32bpp for any source with
-- an alpha channel, e.g. PNG screenshots) into:
--   { width = W, height = H, pixels = flatArray }
-- pixels is a 1-indexed flat table of R,G,B,R,G,B,... in [0,255] (alpha
-- dropped if present), row-major, always top-to-bottom regardless of the
-- file's internal row order (handles both the top-down and legacy
-- bottom-up cases).
function M.parseBMP(bytes)
  assert(bytes:sub(1, 2) == "BM", "not a BMP file")
  local pixelOffset = u32(bytes, 0x0A)
  local width = i32(bytes, 0x12)
  local heightRaw = i32(bytes, 0x16)
  local bpp = u16(bytes, 0x1C)
  local compression = u32(bytes, 0x1E)

  assert(bpp == 24 or bpp == 32, "expected 24bpp or 32bpp BMP, got " .. tostring(bpp))
  -- sips writes 32bpp BMPs (any source with an alpha channel, e.g. PNG
  -- screenshots) as BI_BITFIELDS (3) with an extended BITMAPV4HEADER
  -- carrying explicit channel bit masks, not plain BI_RGB (0) like its
  -- 24bpp output. Verified by hand-decoding a real sips-generated file
  -- (see verify_imageio.lua / RESEARCH.md): the masks always come out as
  -- standard byte-order BGRA, same layout as the 24bpp BGR case with an
  -- alpha byte appended -- so the pixel-reading loop below needs no
  -- change, just accepting this compression value.
  assert(compression == 0 or compression == 3,
    "expected uncompressed (BI_RGB) or bitfield (BI_BITFIELDS) BMP, got compression " .. tostring(compression))

  local topDown = heightRaw < 0
  local height = topDown and -heightRaw or heightRaw

  local bytesPerPixel = bpp / 8
  local rowBytes = math.floor((width * bytesPerPixel + 3) / 4) * 4
  local pixels = {}
  local idx = 1
  for row = 0, height - 1 do
    -- Output is always top-to-bottom. If the file is bottom-up (the
    -- classic BMP default, positive height), output row `row` lives at
    -- file row (height-1-row); if top-down, they match directly.
    local fileRow = topDown and row or (height - 1 - row)
    local rowStart = pixelOffset + fileRow * rowBytes
    for col = 0, width - 1 do
      local p = rowStart + col * bytesPerPixel
      local b, g, r = bytes:byte(p + 1, p + 3) -- alpha byte (p+4), if present, is simply not read
      pixels[idx] = r
      pixels[idx + 1] = g
      pixels[idx + 2] = b
      idx = idx + 3
    end
  end

  return { width = width, height = height, pixels = pixels }
end

-- Matches index.html's RAW_EXTENSIONS / isRawFile exactly.
M.RAW_EXTENSIONS = { cr2 = true, cr3 = true, raf = true, dng = true, rw2 = true, nef = true, arw = true }

function M.isRawFile(path)
  local ext = path:match("%.([^./]+)$")
  return ext ~= nil and M.RAW_EXTENSIONS[ext:lower()] == true
end

-- Finds every occurrence of the JPEG SOI+marker byte sequence (FF D8 FF)
-- in `bytes`. Direct port of the offset-scanning half of index.html's
-- extractEmbeddedJpeg -- same reasoning: RAW files store one or more
-- embedded JPEG previews (the camera's own rendering) at arbitrary
-- offsets, and this is how you find where they start.
function M.findJpegSOIOffsets(bytes)
  local SOI = "\255\216\255" -- FF D8 FF
  local offsets = {}
  local searchFrom = 1
  while true do
    local idx = bytes:find(SOI, searchFrom, true) -- plain=true: literal bytes, not a Lua pattern
    if not idx then break end
    offsets[#offsets + 1] = idx
    searchFrom = idx + 1
  end
  return offsets
end

-- Markers that plausibly start a real, displayable JPEG (APP0/JFIF,
-- APP1/Exif, DQT, baseline/progressive SOF). Deliberately excludes 0xC3
-- (SOF3, lossless JPEG) -- checked against a real 42MB DNG and found
-- 651 of 652 raw "FF D8 FF" occurrences were 0xC3, which turned out to
-- be the DNG's own internally lossless-JPEG-compressed RAW sensor
-- tiles, not preview images at all (see RESEARCH.md). Only the one
-- 0xDB candidate was the real embedded preview. Trying to sips-convert
-- all 652 (each a write-to-disk + subprocess spawn) would have been
-- minutes-to-hours of pointless work; this filter is what makes
-- RAW-preview extraction actually fast.
local LIKELY_PREVIEW_MARKERS = { [0xE0] = true, [0xE1] = true, [0xDB] = true, [0xC0] = true, [0xC2] = true }

-- Filters findJpegSOIOffsets' output down to offsets that plausibly
-- start a real preview JPEG, by checking the marker byte immediately
-- after the FF D8 FF. `maxCandidates` (optional) additionally caps the
-- result as a hard safety net, in case some other RAW format's internal
-- tile encoding doesn't happen to use SOF3 and slips past the marker
-- filter -- keeps the largest-offset-count case bounded regardless.
function M.filterLikelyPreviewOffsets(bytes, offsets, maxCandidates)
  local filtered = {}
  for _, offset in ipairs(offsets) do
    local marker = bytes:byte(offset + 3)
    if marker and LIKELY_PREVIEW_MARKERS[marker] then
      filtered[#filtered + 1] = offset
      if maxCandidates and #filtered >= maxCandidates then break end
    end
  end
  return filtered
end

-- Everything below requires the Lightroom SDK and cannot be exercised
-- outside the plugin runtime. `import` is a global injected by Lightroom's
-- Lua host; referencing an undefined global is not an error in Lua, it's
-- just nil, so this is a safe way to detect we're running standalone.
if import ~= nil then
  local LrTasks = import("LrTasks")
  local LrPathUtils = import("LrPathUtils")
  local LrFileUtils = import("LrFileUtils")

  -- Lua's %q string.format escapes for embedding back into LUA SOURCE,
  -- not for a POSIX shell -- not safe to use for building a shell
  -- command (could break, or worse, on paths with $, `, etc.). Standard
  -- POSIX single-quote escaping instead: wrap in '...', and turn any
  -- embedded ' into '\'' (close quote, escaped quote, reopen quote).
  local function shellQuote(s)
    return "'" .. s:gsub("'", "'\\''") .. "'"
  end

  -- Converts any image file sips can read to a temp BMP, returns its
  -- path. Caller is responsible for deleting the temp file when done.
  -- maxDimension (optional): passed to sips' -Z to downscale during
  -- conversion -- pixel stats don't need full resolution, and a full-res
  -- RAW file (this project has seen 40MB+ RAF/DNG originals) decoded and
  -- then looped over pixel-by-pixel in pure Lua would be needlessly slow.
  function M.convertToBMP(sourcePath, maxDimension)
    local tmpDir = LrPathUtils.getStandardFilePath("temp")
    local uid = tostring(math.random(1e9))
    local bmpPath = LrPathUtils.child(tmpDir, LrPathUtils.leafName(sourcePath) .. "-" .. uid .. ".bmp")
    local stderrPath = LrPathUtils.child(tmpDir, "colortransfer-stderr-" .. uid .. ".log")
    local resizeArg = maxDimension and (" -Z " .. tostring(math.floor(maxDimension))) or ""
    -- LrTasks.execute's only return value is the numeric exit status (no
    -- stdout/stderr capture per the SDK docs) -- redirect stderr to a
    -- file ourselves so a failure can be diagnosed instead of just
    -- "it didn't work". Confirmed via research (RESEARCH.md) that a
    -- previous version of this check (`if not ok`) was dead code: exit
    -- codes are numbers, and every number is truthy in Lua, so that
    -- branch could never fire -- fixed to check `exitCode ~= 0`.
    local cmd = "sips -s format bmp" .. resizeArg .. " " .. shellQuote(sourcePath)
      .. " --out " .. shellQuote(bmpPath) .. " 2> " .. shellQuote(stderrPath)
    local exitCode = LrTasks.execute(cmd)
    local outputExists = LrFileUtils.exists(bmpPath)
    if exitCode ~= 0 or not outputExists then
      local stderrText = ""
      if LrFileUtils.exists(stderrPath) then
        local ef = io.open(stderrPath, "r")
        if ef then stderrText = ef:read("*a") or ""; ef:close() end
      end
      LrFileUtils.delete(stderrPath)
      local sourceExists = LrFileUtils.exists(sourcePath)
      local sizeOk, sourceSize = LrTasks.pcall(function() return LrFileUtils.fileAttributes(sourcePath).fileSize end)
      if not sizeOk then sourceSize = "?" end
      error(string.format(
        "sips failed converting %s to BMP: exitCode=%s outputExists=%s sourceExists=%s sourceSize=%s stderr=%q cmd=%s",
        sourcePath, tostring(exitCode), tostring(outputExists), tostring(sourceExists), tostring(sourceSize), stderrText, cmd))
    end
    LrFileUtils.delete(stderrPath)
    return bmpPath
  end

  -- Loads pixel data for an arbitrary image file path via sips + BMP.
  -- maxDimension: see convertToBMP.
  function M.loadPixelsFromFile(sourcePath, maxDimension)
    local bmpPath = M.convertToBMP(sourcePath, maxDimension)
    local f = io.open(bmpPath, "rb")
    local bytes = f:read("*a")
    f:close()
    LrFileUtils.delete(bmpPath)
    return M.parseBMP(bytes)
  end

  -- Loads pixel data for a RAW file via its embedded JPEG preview (the
  -- camera's own rendering), NOT by letting sips demosaic the RAW itself.
  -- This matters: sips decoding a RAW from scratch uses Apple's own
  -- color/white-balance interpretation, which can render very
  -- differently from the camera's JPEG engine (or Lightroom's own
  -- rendering) -- exactly the mismatch that was producing wrong colors
  -- when this function didn't exist and the target photo's RAW file was
  -- being sips-decoded directly. Direct port of index.html's
  -- extractEmbeddedJpeg strategy: find every embedded JPEG's start
  -- offset, try decoding each, keep the largest one that works -- but
  -- pre-filtered by marker byte first (see filterLikelyPreviewOffsets),
  -- since a raw scan can turn up hundreds of false-positive offsets that
  -- are actually the RAW's own internally-compressed sensor data, not
  -- preview images, and trying to sips-convert all of them would be
  -- prohibitively slow.
  function M.loadPixelsFromRawFile(rawPath, maxDimension)
    local rf = assert(io.open(rawPath, "rb"))
    local rawBytes = rf:read("*a")
    rf:close()

    local allOffsets = M.findJpegSOIOffsets(rawBytes)
    if #allOffsets == 0 then
      error("No embedded JPEG preview found in " .. rawPath)
    end
    local offsets = M.filterLikelyPreviewOffsets(rawBytes, allOffsets, 20)
    if #offsets == 0 then
      -- Marker filter found nothing plausible -- fall back to trying the
      -- raw (unfiltered) candidates, capped, rather than giving up. Rare:
      -- only expected for a RAW format whose preview doesn't use a
      -- typical marker immediately after SOI.
      offsets = {}
      for i = 1, math.min(20, #allOffsets) do offsets[i] = allOffsets[i] end
    end

    local tmpDir = LrPathUtils.getStandardFilePath("temp")
    local bestBmpPath, bestPixelCount = nil, 0
    local candidateErrors = {}

    for _, offset in ipairs(offsets) do
      -- Slice from this offset to end of file, same as the web app --
      -- the decoder (here, sips) stops at the JPEG's own EOI marker and
      -- ignores whatever RAW data trails after it.
      local slice = rawBytes:sub(offset)
      local candidateJpegPath = LrPathUtils.child(tmpDir,
        "colortransfer-embedded-" .. tostring(offset) .. "-" .. tostring(math.random(1e9)) .. ".jpg")
      local jf = assert(io.open(candidateJpegPath, "wb"))
      jf:write(slice)
      jf:close()

      -- LrTasks.pcall, not plain pcall: convertToBMP calls LrTasks.execute
      -- internally, which yields, and plain pcall can't cross a yield
      -- boundary (this exact bug already bit DumpDevelopSettings.lua and
      -- ColorTransferMain.lua earlier -- see RESEARCH.md -- missed here).
      local ok, bmpPathOrErr = LrTasks.pcall(M.convertToBMP, candidateJpegPath, maxDimension)
      LrFileUtils.delete(candidateJpegPath)

      if ok then
        local bmpPath = bmpPathOrErr
        local bf = io.open(bmpPath, "rb")
        local header = bf and bf:read(26) or nil
        if bf then bf:close() end
        local pixelCount = nil
        if header and #header >= 26 then
          local width = u32(header, 0x12)
          local heightRaw = i32(header, 0x16)
          local height = heightRaw < 0 and -heightRaw or heightRaw
          pixelCount = width * height
        end
        if pixelCount and pixelCount > bestPixelCount then
          if bestBmpPath then LrFileUtils.delete(bestBmpPath) end
          bestBmpPath, bestPixelCount = bmpPath, pixelCount
        else
          LrFileUtils.delete(bmpPath)
        end
      else
        candidateErrors[#candidateErrors + 1] = "offset " .. offset .. ": " .. tostring(bmpPathOrErr)
      end
    end

    if not bestBmpPath then
      error("No decodable embedded JPEG preview found in " .. rawPath .. " (" .. #offsets
        .. " candidate offset(s) tried). Failures:\n" .. table.concat(candidateErrors, "\n"))
    end

    local bf = assert(io.open(bestBmpPath, "rb"))
    local bmpBytes = bf:read("*a")
    bf:close()
    LrFileUtils.delete(bestBmpPath)
    return M.parseBMP(bmpBytes)
  end

  -- Convenience: picks the right loading strategy based on file extension.
  function M.loadPixelsSmartly(path, maxDimension)
    if M.isRawFile(path) then
      return M.loadPixelsFromRawFile(path, maxDimension)
    end
    return M.loadPixelsFromFile(path, maxDimension)
  end
end

return M

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

-- Everything below requires the Lightroom SDK and cannot be exercised
-- outside the plugin runtime. `import` is a global injected by Lightroom's
-- Lua host; referencing an undefined global is not an error in Lua, it's
-- just nil, so this is a safe way to detect we're running standalone.
if import ~= nil then
  local LrTasks = import("LrTasks")
  local LrPathUtils = import("LrPathUtils")
  local LrFileUtils = import("LrFileUtils")

  -- Converts any image file sips can read to a temp BMP, returns its path.
  -- Caller is responsible for deleting the temp file when done.
  function M.convertToBMP(sourcePath)
    local tmpDir = LrPathUtils.getStandardFilePath("temp")
    local bmpPath = LrPathUtils.child(tmpDir, LrPathUtils.leafName(sourcePath) .. "-" .. tostring(math.random(1e9)) .. ".bmp")
    local cmd = string.format('sips -s format bmp %q --out %q', sourcePath, bmpPath)
    local ok, status = LrTasks.execute(cmd)
    if not ok or not LrFileUtils.exists(bmpPath) then
      error("sips failed to convert " .. sourcePath .. " to BMP (status: " .. tostring(status) .. ")")
    end
    return bmpPath
  end

  -- Loads pixel data for an arbitrary image file path via sips + BMP.
  function M.loadPixelsFromFile(sourcePath)
    local bmpPath = M.convertToBMP(sourcePath)
    local f = io.open(bmpPath, "rb")
    local bytes = f:read("*a")
    f:close()
    LrFileUtils.delete(bmpPath)
    return M.parseBMP(bytes)
  end
end

return M

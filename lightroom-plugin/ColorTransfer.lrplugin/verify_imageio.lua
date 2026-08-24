-- Standalone check: run with `lua verify_imageio.lua <path-to-bmp>`.
-- Confirms parseBMP reads dimensions and pixel bytes correctly against a
-- real sips-generated BMP file, cross-checked by manually decoding the
-- header bytes with `xxd` -- see RESEARCH.md for that manual decode log.

package.path = package.path .. ";" .. (arg[0]:match("(.*/)") or "./") .. "?.lua"
local imageio = require("imageio")

local path = arg[1]
if not path then
  print("usage: lua verify_imageio.lua <path-to-bmp>")
  os.exit(1)
end

local f = assert(io.open(path, "rb"))
local bytes = f:read("*a")
f:close()

local img = imageio.parseBMP(bytes)
print(string.format("width=%d height=%d pixelCount=%d", img.width, img.height, #img.pixels / 3))

local function pixelAt(img, x, y)
  local idx = (y * img.width + x) * 3 + 1
  return img.pixels[idx], img.pixels[idx + 1], img.pixels[idx + 2]
end

local r, g, b = pixelAt(img, 0, 0)
print(string.format("pixel(0,0) = R=%d G=%d B=%d", r, g, b))

local r2, g2, b2 = pixelAt(img, img.width - 1, img.height - 1)
print(string.format("pixel(w-1,h-1) = R=%d G=%d B=%d", r2, g2, b2))

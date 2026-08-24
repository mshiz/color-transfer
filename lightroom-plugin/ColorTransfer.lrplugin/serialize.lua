-- Minimal recursive table -> readable-text serializer, for dumping
-- Lightroom API tables (e.g. photo:getDevelopSettings()) to a file for
-- inspection. Not meant to round-trip / be re-parsed -- just readable.

local M = {}

local function isArray(t)
  local n = 0
  for _ in pairs(t) do n = n + 1 end
  for i = 1, n do
    if t[i] == nil then return false end
  end
  return n > 0
end

function M.dump(value, indent)
  indent = indent or 0
  local pad = string.rep("  ", indent)
  local t = type(value)

  if t == "table" then
    local keys = {}
    for k in pairs(value) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)

    if isArray(value) and #keys == #value then
      local parts = {}
      for _, v in ipairs(value) do
        parts[#parts + 1] = M.dump(v, 0)
      end
      return "{" .. table.concat(parts, ", ") .. "}"
    end

    local lines = { "{" }
    for _, k in ipairs(keys) do
      lines[#lines + 1] = pad .. "  " .. tostring(k) .. " = " .. M.dump(value[k], indent + 1) .. ","
    end
    lines[#lines + 1] = pad .. "}"
    return table.concat(lines, "\n")
  elseif t == "string" then
    return string.format("%q", value)
  elseif t == "nil" then
    return "nil"
  else
    return tostring(value)
  end
end

return M

-- GameGuardian Lua Bytecode Compiler (Lua 5.1)
-- Runs inside GameGuardian to compile .lua files to .luac using string.dump
-- Usage: Load this script in GG, then choose an option.

gg.setVisible(false)

gg.toast('Lua Compiler ready')

local function dirname(path)
  if not path then return nil end
  return path:match("(.*/)")
end

local function changeExtToLuac(path)
  if not path then return nil end
  if path:sub(-4):lower() == ".lua" then
    return path:sub(1, -5) .. ".luac"
  else
    return path .. ".luac"
  end
end

local function compileFile(inPath, outPath)
  if not inPath or inPath == "" then return false, "Input path is empty" end
  if not outPath or outPath == "" then return false, "Output path is empty" end

  local chunk, loadErr = loadfile(inPath)
  if not chunk then return false, tostring(loadErr) end

  local okDump, dumped = pcall(string.dump, chunk)
  if not okDump or not dumped then return false, "string.dump failed: " .. tostring(dumped) end

  local out, err = io.open(outPath, "wb")
  if not out then return false, tostring(err) end
  out:write(dumped)
  out:close()
  return true
end

local currentScript = gg.getFile()
local defaultDir = dirname(currentScript) or "/sdcard/"

local function menu()
  return gg.choice({
    "Compile current script",
    "Compile file by path",
    "Batch compile (paste paths)",
    "About",
    "Exit"
  }, nil, "Lua Compiler (GG, Lua 5.1)")
end

while true do
  local choice = menu()
  if not choice or choice == 5 then os.exit() end

  if choice == 1 then
    if not currentScript then
      gg.alert("Cannot detect current script path.")
      os.exit()
    end
    local defaultOut = changeExtToLuac(currentScript)
    local input = gg.prompt({"Input .lua path", "Output .luac path"}, {currentScript, defaultOut}, {"text", "text"})
    if not input then os.exit() end
    local inPath, outPath = input[1], input[2]
    if not outPath or outPath == "" then outPath = changeExtToLuac(inPath) end
    local ok, err = compileFile(inPath, outPath)
    if ok then
      gg.alert("Compiled:\n" .. inPath .. "\n→\n" .. outPath)
    else
      gg.alert("Error:\n" .. err)
    end
    os.exit()
  elseif choice == 2 then
    local input = gg.prompt({"Input .lua path", "Output .luac path (optional)"}, {defaultDir, ""}, {"text", "text"})
    if not input then os.exit() end
    local inPath, outPath = input[1], input[2]
    if not inPath or inPath == "" then
      gg.alert("Please provide an input file path.")
      os.exit()
    end
    if not outPath or outPath == "" then outPath = changeExtToLuac(inPath) end
    local ok, err = compileFile(inPath, outPath)
    if ok then
      gg.alert("Compiled:\n" .. inPath .. "\n→\n" .. outPath)
    else
      gg.alert("Error:\n" .. err)
    end
    os.exit()
  elseif choice == 3 then
    local input = gg.prompt({"Paste .lua file paths (one per line)"}, {""}, {"text"})
    if not input then os.exit() end
    local text = input[1] or ""
    local okCount, failCount = 0, 0
    local messages = {}
    for line in (text .. "\n"):gmatch("([^\n]*)\n") do
      local trimmed = line:gsub("^%s+", ""):gsub("%s+$", "")
      if trimmed ~= "" then
        local outPath = changeExtToLuac(trimmed)
        local ok, err = compileFile(trimmed, outPath)
        if ok then
          okCount = okCount + 1
        else
          failCount = failCount + 1
          messages[#messages + 1] = trimmed .. " -> ERROR: " .. tostring(err)
        end
      end
    end
    local report = "Batch done. Success: " .. okCount .. "  Failed: " .. failCount
    if #messages > 0 then
      report = report .. "\n\nErrors:\n" .. table.concat(messages, "\n")
    end
    gg.alert(report)
    os.exit()
  elseif choice == 4 then
    gg.alert("Compiles Lua 5.1 bytecode using string.dump.\n- Target: GameGuardian Lua 5.1\n- Note: Bytecode is version-specific.\n- Tip: Use 'Compile current script' for quick .luac export.")
    os.exit()
  end
end
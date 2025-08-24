-- GameGuardian Lua Bytecode Compiler (Lua 5.1)
-- Runs inside GameGuardian to compile .lua files to .luac using string.dump
-- Usage: Load this script in GG, then choose an option.

gg.setVisible(false)

gg.toast('Lua Compiler ready')

-- forward declare settings so helper functions can capture the local
local settings

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

-- Add path helpers for output selection
local function ensureDirEnd(dir)
  if not dir or dir == "" then return "" end
  if dir:sub(-1) ~= "/" then
    return dir .. "/"
  end
  return dir
end

local function basename(path)
  if not path then return nil end
  return path:match("([^/]+)$")
end

local function joinPath(dir, file)
  if not dir or dir == "" then return file end
  dir = ensureDirEnd(dir)
  return dir .. file
end

-- normalize any name or path to current output extension
local function normalizeExtToTarget(nameOrPath)
  if not nameOrPath or nameOrPath == "" then return "" end
  local lower = nameOrPath:lower()
  local withoutExt
  if lower:sub(-5) == ".luac" then
    withoutExt = nameOrPath:sub(1, -6)
  elseif lower:sub(-4) == ".lua" then
    withoutExt = nameOrPath:sub(1, -5)
  else
    withoutExt = nameOrPath
  end
  local ext = (settings and settings.outputExt or ".lua")
  if settings and settings.securityEnabled then ext = ".lua" end
  return withoutExt .. ext
end

local function ensureOutputFilename(name)
  return normalizeExtToTarget(name)
end

local function buildOutPathWithOverride(inPath, overrideName)
  local dir
  if settings and settings.useFixedOutputDir and settings.outputDir and settings.outputDir ~= "" then
    dir = settings.outputDir
  else
    dir = dirname(inPath) or "/sdcard/"
  end
  return joinPath(dir, ensureOutputFilename(overrideName))
end

-- bytewise XOR and helpers for security packer
local function bxor(a, b)
  local res = 0
  local p = 1
  while a > 0 or b > 0 do
    local aa = a % 2
    local bb = b % 2
    if aa ~= bb then res = res + p end
    a = (a - aa) / 2
    b = (b - bb) / 2
    p = p * 2
  end
  return res
end

local function xorCipher(data, key)
  if not key or key == "" then return data end
  local out = {}
  local klen = #key
  for i = 1, #data do
    out[i] = string.char(bxor(data:byte(i), key:byte(((i - 1) % klen) + 1)))
  end
  return table.concat(out)
end

local function adler32(str)
  local a, b = 1, 0
  for i = 1, #str do
    a = (a + str:byte(i)) % 65521
    b = (b + a) % 65521
  end
  return b * 65536 + a
end

local function toEscapedDecimalString(s)
  local t = {}
  for i = 1, #s do
    t[i] = "\\" .. string.format("%03d", s:byte(i))
  end
  return table.concat(t)
end

local function writeFileText(path, content)
  local f, err = io.open(path, "wb")
  if not f then return false, tostring(err) end
  f:write(content)
  f:close()
  return true
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

-- compile with optional security packing
local function compileWithSecurity(inPath, outPath)
  if not settings or not settings.securityEnabled then
    return compileFile(inPath, outPath)
  end
  -- force .lua extension for loader output
  outPath = normalizeExtToTarget(outPath)

  local chunk, loadErr = loadfile(inPath)
  if not chunk then return false, tostring(loadErr) end
  local okDump, dumped = pcall(string.dump, chunk)
  if not okDump or not dumped then return false, "string.dump failed: " .. tostring(dumped) end

  local key = settings.securityKey or ""
  local enc = xorCipher(dumped, key)
  local checksum = adler32(dumped)
  local bind = settings.securityBind or ""
  local prompt = settings.securityPromptKey and "true" or "false"
  local integ = settings.integrityCheck and "true" or "false"
  local escaped = toEscapedDecimalString(enc)

  local loader = "gg.setVisible(false)\n"
    .. "local function bxor(a,b) local r=0; local p=1; while a>0 or b>0 do local aa=a%2; local bb=b%2; if aa~=bb then r=r+p end; a=(a-aa)/2; b=(b-bb)/2; p=p*2 end; return r end\n"
    .. "local function xorCipher(s,k) if not k or k==\"\" then return s end local o={} local kl=#k for i=1,#s do o[i]=string.char(bxor(s:byte(i), k:byte(((i-1)%kl)+1))) end return table.concat(o) end\n"
    .. "local function adler32(s) local a=1 local b=0 for i=1,#s do a=(a+s:byte(i))%65521 b=(b+a)%65521 end return b*65536 + a end\n"
    .. "local function isAllowed(bind) if not bind or bind==\"\" then return true end local ok,info=pcall(gg.getTargetInfo) if ok and type(info)==\"table\" then local name=info.packageName or info.processName or info.label or \"\" return name:find(bind,1,true)~=nil end return true end\n"
    .. "if not isAllowed(" .. string.format('%q', bind) .. ") then gg.alert(\"Unauthorized target\"); os.exit() end\n"
    .. "local key\n"
    .. "if " .. prompt .. " then local r=gg.prompt({\"Enter decryption key\"},{\"\"},{\"text\"}); if not r then os.exit() end key=r[1] or \"\" else key=" .. string.format('%q', key) .. " end\n"
    .. "local enc=\"" .. escaped .. "\"\n"
    .. "local dec=xorCipher(enc, key)\n"
    .. "if " .. integ .. " and adler32(dec)~=" .. tostring(checksum) .. " then gg.alert(\"Integrity check failed\"); os.exit() end\n"
    .. "local fn,err=loadstring(dec)\n"
    .. "if not fn then gg.alert(\"Load error: \"..tostring(err)); os.exit() end\n"
    .. "return fn()\n"

  return writeFileText(outPath, loader)
end

local currentScript = gg.getFile()
local defaultDir = dirname(currentScript) or "/sdcard/"

-- Persistent settings for output selection
local settingsPath = defaultDir .. "gg_lua_compiler_settings.dat"
settings = {
  useFixedOutputDir = false,
  outputDir = defaultDir,
  outputExt = ".lua",
  -- security
  securityEnabled = false,
  securityPromptKey = false,
  securityKey = "",
  securityBind = "",
  integrityCheck = true
}

local function loadSettings()
  local ok, data = pcall(gg.loadVariable, settingsPath)
  if ok and type(data) == "table" then
    if type(data.useFixedOutputDir) == "boolean" then
      settings.useFixedOutputDir = data.useFixedOutputDir
    end
    if type(data.outputDir) == "string" and data.outputDir ~= "" then
      settings.outputDir = ensureDirEnd(data.outputDir)
    end
    if type(data.outputExt) == "string" and (data.outputExt == ".lua" or data.outputExt == ".luac") then
      settings.outputExt = data.outputExt
    end
    if type(data.securityEnabled) == "boolean" then
      settings.securityEnabled = data.securityEnabled
    end
    if type(data.securityPromptKey) == "boolean" then
      settings.securityPromptKey = data.securityPromptKey
    end
    if type(data.securityKey) == "string" then
      settings.securityKey = data.securityKey
    end
    if type(data.securityBind) == "string" then
      settings.securityBind = data.securityBind
    end
    if type(data.integrityCheck) == "boolean" then
      settings.integrityCheck = data.integrityCheck
    end
  end
end

local function saveSettings()
  settings.outputDir = ensureDirEnd(settings.outputDir)
  pcall(gg.saveVariable, settings, settingsPath)
end

local function getDefaultOutPath(inPath)
  if not inPath or inPath == "" then return "" end
  if settings.useFixedOutputDir and settings.outputDir and settings.outputDir ~= "" then
    return joinPath(settings.outputDir, normalizeExtToTarget(basename(inPath)))
  else
    return normalizeExtToTarget(inPath)
  end
end

loadSettings()

local function menu()
  return gg.choice({
    "Compile current script",
    "Compile file by path",
    "Batch compile (paste paths)",
    "Output settings",
    "Security options",
    "About",
    "Exit"
  }, nil, "Lua Compiler (GG, Lua 5.1)")
end

while true do
  local choice = menu()
  if not choice or choice == 7 then os.exit() end

  if choice == 1 then
    if not currentScript then
      gg.alert("Cannot detect current script path.")
      os.exit()
    end
    local defaultOut = getDefaultOutPath(currentScript)
    local input = gg.prompt({"Input .lua path", "Output path (optional)", "Override output filename (optional)"}, {currentScript, defaultOut, ""}, {"text", "text", "text"})
    if not input then os.exit() end
    local inPath, outPath, overrideName = input[1], input[2], input[3]
    if not outPath or outPath == "" then
      if overrideName and overrideName ~= "" then
        outPath = buildOutPathWithOverride(inPath, overrideName)
      else
        outPath = getDefaultOutPath(inPath)
      end
    else
      outPath = normalizeExtToTarget(outPath)
    end
    local ok, err = compileWithSecurity(inPath, outPath)
    if ok then
      gg.alert("Compiled:\n" .. inPath .. "\n→\n" .. outPath)
    else
      gg.alert("Error:\n" .. err)
    end
    os.exit()
  elseif choice == 2 then
    local input = gg.prompt({"Input .lua path", "Output path (optional)", "Override output filename (optional)"}, {defaultDir, "", ""}, {"text", "text", "text"})
    if not input then os.exit() end
    local inPath, outPath, overrideName = input[1], input[2], input[3]
    if not inPath or inPath == "" then
      gg.alert("Please provide an input file path.")
      os.exit()
    end
    if not outPath or outPath == "" then
      if overrideName and overrideName ~= "" then
        outPath = buildOutPathWithOverride(inPath, overrideName)
      else
        outPath = getDefaultOutPath(inPath)
      end
    else
      outPath = normalizeExtToTarget(outPath)
    end
    local ok, err = compileWithSecurity(inPath, outPath)
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
        local outPath = getDefaultOutPath(trimmed)
        local ok, err = compileWithSecurity(trimmed, outPath)
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
    while true do
      local fixedLabel = settings.useFixedOutputDir and "On" or "Off"
      local dirLabel = settings.outputDir or "(not set)"
      local sel = gg.choice({
        "Toggle fixed output dir (current: " .. fixedLabel .. ")",
        "Set output directory (current: " .. dirLabel .. ")",
        "Toggle output extension (current: " .. settings.outputExt .. ")",
        "Use current script directory",
        "Set directory from a file path",
        "Reset to defaults",
        "Back"
      }, nil, "Output settings")
      if not sel or sel == 7 then break end
      if sel == 1 then
        settings.useFixedOutputDir = not settings.useFixedOutputDir
        saveSettings()
      elseif sel == 2 then
        local res = gg.prompt({"Output directory"}, {settings.outputDir}, {"text"})
        if res then
          local dir = ensureDirEnd(res[1] or "")
          if dir == "" then
            gg.alert("Directory cannot be empty.")
          else
            settings.outputDir = dir
            saveSettings()
          end
        end
      elseif sel == 3 then
        settings.outputExt = (settings.outputExt == ".lua") and ".luac" or ".lua"
        saveSettings()
      elseif sel == 4 then
        settings.outputDir = defaultDir
        saveSettings()
      elseif sel == 5 then
        local res2 = gg.prompt({"Enter any file path inside desired folder"}, {defaultDir}, {"text"})
        if res2 and res2[1] and res2[1] ~= "" then
          local dir = dirname(res2[1])
          if dir and dir ~= "" then
            settings.outputDir = ensureDirEnd(dir)
            saveSettings()
          else
            gg.alert("Could not derive directory from that path.")
          end
        end
      elseif sel == 6 then
        settings.useFixedOutputDir = false
        settings.outputDir = defaultDir
        settings.outputExt = ".lua"
        saveSettings()
      end
    end
  elseif choice == 5 then
    while true do
      local secOn = settings.securityEnabled and "On" or "Off"
      local promptLabel = settings.securityPromptKey and "On" or "Off"
      local bindLabel = (settings.securityBind ~= "" and settings.securityBind) or "(none)"
      local integLabel = settings.integrityCheck and "On" or "Off"
      local keyLabel = (settings.securityKey ~= "" and ("*" .. string.rep("*", math.min(6, #settings.securityKey - 1)))) or "(not set)"
      local sel = gg.choice({
        "Toggle security pack (current: " .. secOn .. ")",
        "Set/Change key",
        "Toggle prompt for key at runtime (current: " .. promptLabel .. ")",
        "Set process/package bind (current: " .. bindLabel .. ")",
        "Toggle integrity check (current: " .. integLabel .. ")",
        "Back"
      }, nil, "Security options")
      if not sel or sel == 6 then break end
      if sel == 1 then
        settings.securityEnabled = not settings.securityEnabled
        if settings.securityEnabled then settings.outputExt = ".lua" end
        saveSettings()
      elseif sel == 2 then
        local res = gg.prompt({"Enter encryption key (keep secret)"}, {settings.securityKey}, {"text"})
        if res then settings.securityKey = res[1] or "" saveSettings() end
      elseif sel == 3 then
        settings.securityPromptKey = not settings.securityPromptKey
        saveSettings()
      elseif sel == 4 then
        local res = gg.prompt({"Bind to process/package (substring match, leave empty to disable)"}, {settings.securityBind}, {"text"})
        if res then settings.securityBind = res[1] or "" saveSettings() end
      elseif sel == 5 then
        settings.integrityCheck = not settings.integrityCheck
        saveSettings()
      end
    end
  elseif choice == 6 then
    gg.alert("Compiles Lua 5.1 bytecode using string.dump.\n- Target: GameGuardian Lua 5.1\n- Security: Optional XOR packing, password prompt, integrity, and package bind.\n- Output dir: Choose fixed or input folder.\n- Output ext: Toggle .lua/.luac (security forces .lua).\n- Override: Set a custom output filename per compile.")
    os.exit()
  end
end
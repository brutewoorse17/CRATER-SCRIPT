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

-- restore write helper (used when writing loader)
local function writeFileText(path, content)
  local f, err = io.open(path, "wb")
  if not f then return false, tostring(err) end
  f:write(content)
  f:close()
  return true
end

-- base64 encode (compiler side)
local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local function base64Encode(data)
  local out = {}
  local len = #data
  local i = 1
  while i <= len do
    local a = data:byte(i) or 0
    local b = data:byte(i + 1) or 0
    local c = data:byte(i + 2) or 0
    local pad2 = (i + 1 > len)
    local pad3 = (i + 2 > len)
    local v0 = math.floor(a / 4)
    local v1 = ((a % 4) * 16) + math.floor(b / 16)
    local v2 = ((b % 16) * 4) + math.floor(c / 64)
    local v3 = c % 64
    local s0 = B64:sub(v0 + 1, v0 + 1)
    local s1 = B64:sub(v1 + 1, v1 + 1)
    local s2 = pad2 and "=" or B64:sub(v2 + 1, v2 + 1)
    local s3 = pad3 and "=" or B64:sub(v3 + 1, v3 + 1)
    out[#out + 1] = s0 .. s1 .. s2 .. s3
    i = i + 3
  end
  return table.concat(out)
end

-- UTF-8 helpers (compiler side)
local function utf8NextLen(c)
  if not c then return 0 end
  if c < 0x80 then return 1 end
  if c < 0xE0 then return 2 end
  if c < 0xF0 then return 3 end
  return 4
end

local function utf8ToTable(s)
  local t = {}
  local i = 1
  local n = #s
  while i <= n do
    local c = s:byte(i)
    local l = utf8NextLen(c)
    t[#t + 1] = s:sub(i, i + l - 1)
    i = i + l
  end
  return t
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
  local loggingEnabled = settings.loggingEnabled and true or false
  local logPath = (settings.logPath and settings.logPath ~= "" and settings.logPath) or "/sdcard/gg_lua_loader.log"
  local antiHookEnabled = settings.antiHookEnabled and true or false
  local exitOnHook = settings.antiHookExitOnDetect and true or false

  local useChinese = settings.chineseEncodingEnabled and true or false
  local zhAlpha = settings.zhAlphabet or "的一是在不了有和人这中大为上个国我以要他时来用们生到作地于出就分对成会可主发年动同工也能下过子说产种面而方后多定学法所民得经十三"
  local zhPad = settings.zhPad or "。"

  local loader = "gg.setVisible(false)\n" .. "local function _log(m) end\n"

  if loggingEnabled then
    loader = loader
      .. "_log=function(m) local p=" .. string.format('%q', logPath) .. " local ok,f=pcall(io.open,p,\"a\") if not ok or not f then return end local ts=os.date(\"%Y-%m-%d %H:%M:%S\") f:write(\"[\"..ts..\"] \"..tostring(m)..\"\\n\") f:close() end\n"
  end

  loader = loader .. "_log(\"loader_start\")\n"
    .. "do local ok,info=pcall(gg.getTargetInfo); if ok and type(info)==\"table\" then _log(\"target:\"..tostring(info.processName or info.packageName or \"\")) end end\n"
    .. "local function bxor(a,b) local r=0; local p=1; while a>0 or b>0 do local aa=a%2; local bb=b%2; if aa~=bb then r=r+p end; a=(a-aa)/2; b=(b-bb)/2; p=p*2 end; return r end\n"
    .. "local function xorCipher(s,k) if not k or k==\"\" then return s end local o={} local kl=#k for i=1,#s do o[i]=string.char(bxor(s:byte(i), k:byte(((i-1)%kl)+1))) end return table.concat(o) end\n"
    .. "local function adler32(s) local a=1 local b=0 for i=1,#s do a=(a+s:byte(i))%65521 b=(b+a)%65521 end return b*65536 + a end\n"
    .. "local function isAllowed(bind) if not bind or bind==\"\" then return true end local ok,info=pcall(gg.getTargetInfo) if ok and type(info)==\"table\" then local name=info.packageName or info.processName or info.label or \"\" return name:find(bind,1,true)~=nil end return true end\n"

  if antiHookEnabled then
    loader = loader
      .. "local function _anti()\n"
      .. "  local flagged=false\n"
      .. "  if debug then\n"
      .. "    if debug.gethook then local okh,res=pcall(debug.gethook); if okh and res then flagged=true end end\n"
      .. "    if debug.sethook then pcall(debug.sethook) end\n"
      .. "    if debug.gethook then local okh2,res2=pcall(debug.gethook); if okh2 and res2 then flagged=true end end\n"
      .. "    if debug.getinfo then local ok1,info=pcall(debug.getinfo, 1, \"S\"); if ok1 and type(info)==\"table\" and info.what and tostring(info.what)~=\"C\" then flagged=true end end\n"
      .. "  end\n"
      .. "  if flagged then _log(\"hook_detected\")" .. (exitOnHook and "; gg.alert(\"Hook detected\"); os.exit()" or "") .. " end\n"
      .. "end\n"
      .. "_anti()\n"
  end

  loader = loader .. "if not isAllowed(" .. string.format('%q', bind) .. ") then _log(\"bind_block\"); gg.alert(\"Unauthorized target\"); os.exit() end\n"
    .. "local key\n"
    .. "if " .. prompt .. " then local r=gg.prompt({\"Enter decryption key\"},{\"\"},{\"text\"}); if not r then os.exit() end key=r[1] or \"\" else key=" .. string.format('%q', key) .. " end\n"

  if useChinese then
    local b64 = base64Encode(enc)
    local zhList = utf8ToTable(zhAlpha)
    if #zhList ~= 64 then
      local escaped = toEscapedDecimalString(enc)
      loader = loader .. "local enc=\"" .. escaped .. "\"\n"
        .. "local dec=xorCipher(enc, key)\n"
        .. "if " .. integ .. " then if adler32(dec)~=" .. tostring(checksum) .. " then _log(\"integrity_fail\"); gg.alert(\"Integrity check failed\"); os.exit() else _log(\"integrity_ok\") end else _log(\"integrity_skip\") end\n"
        .. "local fn,err=loadstring(dec)\n"
        .. "if not fn then _log(\"load_error:\"..tostring(err)); gg.alert(\"Load error: \"..tostring(err)); os.exit() end\n"
        .. "_log(\"exec_start\")\nlocal ok,perr=pcall(fn)\nif not ok then _log(\"exec_error:\"..tostring(perr)); gg.alert(\"Runtime error: \"..tostring(perr)); os.exit() end\n_log(\"exec_done\")\nreturn\n"
      return writeFileText(outPath, loader)
    end
    local asciiIndex = {}
    for i = 1, #B64 do asciiIndex[B64:sub(i,i)] = i - 1 end
    local encZhParts = {}
    for i = 1, #b64 do
      local ch = b64:sub(i,i)
      if ch == "=" then
        encZhParts[#encZhParts + 1] = zhPad
      else
        local idx = asciiIndex[ch]
        encZhParts[#encZhParts + 1] = zhList[idx + 1]
      end
    end
    local encZh = table.concat(encZhParts)
    loader = loader
      .. "local ZH_ALPHA=\"" .. zhAlpha .. "\"\n"
      .. "local ZH_PAD=\"" .. zhPad .. "\"\n"
      .. "local function _u8n(c) if c<128 then return 1 elseif c<224 then return 2 elseif c<240 then return 3 else return 4 end end\n"
      .. "local function _u8iter(s) local i=1 local n=#s return function() if i>n then return nil end local c=s:byte(i) local l=_u8n(c) local ch=s:sub(i,i+l-1) i=i+l return ch end end\n"
      .. "local function _buildIdx(alpha) local m={} local i=0 for ch in _u8iter(alpha) do m[ch]=i i=i+1 end return m end\n"
      .. "local _IDX=_buildIdx(ZH_ALPHA)\n"
      .. "local function _zh_b64_decode(z) local out={} local vals={} local vi=0 local pad=-1 local function push(v) vi=vi+1 vals[vi]=v if vi==4 then local v0,v1,v2,v3=vals[1],vals[2],vals[3],vals[4] local b1= v0*4 + math.floor(v1/16) local b2= ((v1%16)*16) + math.floor((v2<0 and 0 or v2)/4) local b3= (( (v2<0 and 0 or v2)%4)*64) + (v3<0 and 0 or v3) if v2<0 then out[#out+1]=string.char(b1) elseif v3<0 then out[#out+1]=string.char(b1,b2) else out[#out+1]=string.char(b1,b2,b3) end vi=0 end end for ch in _u8iter(z) do if ch==ZH_PAD then push(-1) else local v=_IDX[ch]; if v==nil then else push(v) end end end if vi>0 then while vi<4 do push(-1) end end return table.concat(out) end\n"
      .. "local enc_zh=\"" .. encZh .. "\"\n"
      .. "local enc=_zh_b64_decode(enc_zh)\n"
      .. "local dec=xorCipher(enc, key)\n"
      .. "if " .. integ .. " then if adler32(dec)~=" .. tostring(checksum) .. " then _log(\"integrity_fail\"); gg.alert(\"Integrity check failed\"); os.exit() else _log(\"integrity_ok\") end else _log(\"integrity_skip\") end\n"
      .. "local fn,err=loadstring(dec)\n"
      .. "if not fn then _log(\"load_error:\"..tostring(err)); gg.alert(\"Load error: \"..tostring(err)); os.exit() end\n"
      .. "_log(\"exec_start\")\nlocal ok,perr=pcall(fn)\nif not ok then _log(\"exec_error:\"..tostring(perr)); gg.alert(\"Runtime error: \"..tostring(perr)); os.exit() end\n_log(\"exec_done\")\nreturn\n"
    return writeFileText(outPath, loader)
  else
    local escaped = toEscapedDecimalString(enc)
    loader = loader .. "local enc=\"" .. escaped .. "\"\n"
      .. "local dec=xorCipher(enc, key)\n"
      .. "if " .. integ .. " then if adler32(dec)~=" .. tostring(checksum) .. " then _log(\"integrity_fail\"); gg.alert(\"Integrity check failed\"); os.exit() else _log(\"integrity_ok\") end else _log(\"integrity_skip\") end\n"
      .. "local fn,err=loadstring(dec)\n"
      .. "if not fn then _log(\"load_error:\"..tostring(err)); gg.alert(\"Load error: \"..tostring(err)); os.exit() end\n"
      .. "_log(\"exec_start\")\nlocal ok,perr=pcall(fn)\nif not ok then _log(\"exec_error:\"..tostring(perr)); gg.alert(\"Runtime error: \"..tostring(perr)); os.exit() end\n_log(\"exec_done\")\nreturn\n"
    return writeFileText(outPath, loader)
  end
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
  integrityCheck = true,
  -- logging
  loggingEnabled = false,
  logPath = defaultDir .. "gg_lua_loader.log",
  -- anti-hook
  antiHookEnabled = false,
  antiHookExitOnDetect = true,
  -- chinese encoding
  chineseEncodingEnabled = false,
  zhAlphabet = "的一是在不了有和人这中大为上个国我以要他时来用们生到作地于出就分对成会可主发年动同工也能下过子说产种面而方后多定学法所民得经十三",
  zhPad = "。"
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
    if type(data.loggingEnabled) == "boolean" then
      settings.loggingEnabled = data.loggingEnabled
    end
    if type(data.logPath) == "string" and data.logPath ~= "" then
      settings.logPath = data.logPath
    end
    if type(data.antiHookEnabled) == "boolean" then
      settings.antiHookEnabled = data.antiHookEnabled
    end
    if type(data.antiHookExitOnDetect) == "boolean" then
      settings.antiHookExitOnDetect = data.antiHookExitOnDetect
    end
    if type(data.chineseEncodingEnabled) == "boolean" then
      settings.chineseEncodingEnabled = data.chineseEncodingEnabled
    end
    if type(data.zhAlphabet) == "string" and data.zhAlphabet ~= "" then
      settings.zhAlphabet = data.zhAlphabet
    end
    if type(data.zhPad) == "string" and data.zhPad ~= "" then
      settings.zhPad = data.zhPad
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
      local logLabel = settings.loggingEnabled and "On" or "Off"
      local ahLabel = settings.antiHookEnabled and "On" or "Off"
      local ahExitLabel = settings.antiHookExitOnDetect and "On" or "Off"
      local cnLabel = settings.chineseEncodingEnabled and "On" or "Off"
      local keyLabel = (settings.securityKey ~= "" and ("*" .. string.rep("*", math.min(6, #settings.securityKey - 1)))) or "(not set)"
      local sel = gg.choice({
        "Toggle security pack (current: " .. secOn .. ")",
        "Set/Change key",
        "Toggle prompt for key at runtime (current: " .. promptLabel .. ")",
        "Set process/package bind (current: " .. bindLabel .. ")",
        "Toggle integrity check (current: " .. integLabel .. ")",
        "Toggle logging (current: " .. logLabel .. ")",
        "Set log path (current: " .. (settings.logPath or "(not set)") .. ")",
        "Toggle anti-hook protection (current: " .. ahLabel .. ")",
        "Exit on hook detection (current: " .. ahExitLabel .. ")",
        "Chinese payload encoding (current: " .. cnLabel .. ")",
        "Apply Revo 6.0 preset",
        "Back"
      }, nil, "Security options")
      if not sel or sel == 12 then break end
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
      elseif sel == 6 then
        settings.loggingEnabled = not settings.loggingEnabled
        saveSettings()
      elseif sel == 7 then
        local res = gg.prompt({"Log file path"}, {settings.logPath}, {"text"})
        if res and res[1] and res[1] ~= "" then settings.logPath = res[1]; saveSettings() end
      elseif sel == 8 then
        settings.antiHookEnabled = not settings.antiHookEnabled
        saveSettings()
      elseif sel == 9 then
        settings.antiHookExitOnDetect = not settings.antiHookExitOnDetect
        saveSettings()
      elseif sel == 10 then
        settings.chineseEncodingEnabled = not settings.chineseEncodingEnabled
        saveSettings()
      elseif sel == 11 then
        settings.securityEnabled = true
        settings.outputExt = ".lua"
        settings.securityPromptKey = false
        settings.integrityCheck = true
        settings.loggingEnabled = true
        settings.logPath = defaultDir .. "revo_loader.log"
        settings.antiHookEnabled = true
        settings.antiHookExitOnDetect = true
        settings.chineseEncodingEnabled = true
        saveSettings()
        gg.toast("Applied Revo 6.0 preset")
      end
    end
  elseif choice == 6 then
    gg.alert("Compiles Lua 5.1 bytecode using string.dump.\n- Target: GameGuardian Lua 5.1\n- Security: XOR pack, optional password prompt, integrity check, bind, anti-hook, logging.\n- Payload encoding: ASCII bytes or Chinese Base64 mapping.\n- Output dir: Choose fixed or input folder.\n- Output ext: Toggle .lua/.luac (security forces .lua).\n- Override: Custom output filename per compile.")
    os.exit()
  end
end
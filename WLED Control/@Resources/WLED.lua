-- WLED control logic.
-- State/lists come from downloaded JSON files; commands are POSTed to /json/state with curl.
local fxNames, palNames, fxdata, presetNames, presetIds = {}, {}, {}, {}, {}
local devices, devIdx, scanning = {}, 1, false
local S = nil                       -- decoded { state = ..., info = ... }
local selSeg, slot, page = 1, 1, 1
local rbArm = 0
local lastRaw = {}
local hasW, hasCct = false, false
local hsvMem = nil
local ROWS, TRACK_H = 14, 336
local MAX_QUEUED_POSTS = 32
local picker = { mode = nil, offset = 0 }
local cache, dirty = {}, false
local postQueue, postInFlight, postSequence = {}, nil, 0
local postSession = ''
local scanStatus = 'Ready'
local requestFailed = false
local scanStarted = nil
local dispatchPost, pollPostResult, refreshState

-- ------------------------------------------------------------- helpers
local function setVar(k, v)
  v = tostring(v):gsub('"', "'")
  if cache[k] == v then return end
  cache[k] = v
  dirty = true
  SKIN:Bang('!SetVariable ' .. k .. ' "' .. v .. '"')
end

local function redraw(force)
  if dirty or force then
    SKIN:Bang('!UpdateMeter', '*')
    SKIN:Bang('!Redraw')
    dirty = false
  end
end

local function readFile(path)
  local f = io.open(path, 'r')
  if not f then return nil end
  local s = f:read('*a')
  f:close()
  return s
end

local function dl(name) return readFile(SKIN:MakePathAbsolute('DownloadFile\\' .. name)) end
local function clamp(v, lo, hi) return math.max(lo, math.min(hi, v)) end
local function round(v) return math.floor(v + 0.5) end
local function toByte(pct) return round(clamp(pct, 0, 100) * 2.55) end
local function ip() return SKIN:GetVariable('IP') or '' end
local function bool(v) return v and 'true' or 'false' end

local function showStatus(text, failed)
  scanStatus = text
  if failed ~= nil then requestFailed = failed end
  setVar('StatusText', text)
  redraw()
end

local function normalizeAddress(value)
  if type(value) ~= 'string' then return nil end
  local address = value:gsub('^%s+', ''):gsub('%s+$', ''):lower()
  if address == '' or #address > 253 then return nil end

  local a, b, c, d = address:match('^(%d+)%.(%d+)%.(%d+)%.(%d+)$')
  if a then
    local octets = {}
    for _, octet in ipairs({ a, b, c, d }) do
      local number = tonumber(octet)
      if not number or number > 255 then return nil end
      octets[#octets + 1] = tostring(number)
    end
    return table.concat(octets, '.')
  end
  if address:match('^[%d%.]+$') or address:sub(1, 1) == '.' or
    address:sub(-1) == '.' or address:find('%.%.') then return nil end

  for label in address:gmatch('[^.]+') do
    if #label > 63 or not label:match('^[a-z0-9%-]+$') or
      label:sub(1, 1) == '-' or label:sub(-1) == '-' then return nil end
  end
  if address:find('[^a-z0-9%.%-]') then return nil end
  return address
end

local function utf8enc(c)
  if c < 128 then return string.char(c) end
  if c < 2048 then return string.char(192 + math.floor(c / 64), 128 + c % 64) end
  return string.char(224 + math.floor(c / 4096), 128 + math.floor(c / 64) % 64, 128 + c % 64)
end

-- Minimal JSON decoder (objects, arrays, strings, numbers, booleans, null).
local function jdecode(s)
  local pos = 1
  local val
  local function ws() pos = s:find('[^ \t\r\n]', pos) or (#s + 1) end
  local function str()
    local out, i = {}, pos + 1
    while true do
      local c = s:sub(i, i)
      if c == '"' then pos = i + 1 return table.concat(out) end
      if c == '' then error('eof') end
      if c == '\\' then
        local n = s:sub(i + 1, i + 1)
        if n == 'u' then
          out[#out + 1] = utf8enc(tonumber(s:sub(i + 2, i + 5), 16) or 63)
          i = i + 6
        else
          out[#out + 1] = ({ n = '\n', t = '\t', r = '\r', b = '\b', f = '\f' })[n] or n
          i = i + 2
        end
      else
        local j = s:find('["\\]', i)
        if not j then error('eof') end
        out[#out + 1] = s:sub(i, j - 1)
        i = j
      end
    end
  end
  function val()
    ws()
    local c = s:sub(pos, pos)
    if c == '{' then
      local t = {}
      pos = pos + 1 ws()
      if s:sub(pos, pos) == '}' then pos = pos + 1 return t end
      while true do
        ws()
        local k = str()
        ws() pos = pos + 1
        t[k] = val()
        ws()
        local d = s:sub(pos, pos) pos = pos + 1
        if d == '}' then return t end
        if d ~= ',' then error('object') end
      end
    elseif c == '[' then
      local t, n = {}, 0
      pos = pos + 1 ws()
      if s:sub(pos, pos) == ']' then pos = pos + 1 return t end
      while true do
        n = n + 1
        t[n] = val()
        ws()
        local d = s:sub(pos, pos) pos = pos + 1
        if d == ']' then return t end
        if d ~= ',' then error('array') end
      end
    elseif c == '"' then return str()
    elseif s:sub(pos, pos + 3) == 'true' then pos = pos + 4 return true
    elseif s:sub(pos, pos + 4) == 'false' then pos = pos + 5 return false
    elseif s:sub(pos, pos + 3) == 'null' then pos = pos + 4 return nil
    else
      local num = s:match('^-?%d+%.?%d*[eE]?[+-]?%d*', pos)
      if not num or num == '' then error('value') end
      pos = pos + #num
      return tonumber(num)
    end
  end
  local ok, res = pcall(val)
  if ok then return res end
  return nil
end

local function split(s, sep)
  local t, i = {}, 1
  while true do
    local j = s:find(sep, i, true)
    if not j then t[#t + 1] = s:sub(i) break end
    t[#t + 1] = s:sub(i, j - 1)
    i = j + #sep
  end
  return t
end

-- ------------------------------------------------------------- colour maths
local function hsv2rgb(h, s, v)
  h = clamp(h, 0, 0.9999)
  local i = math.floor(h * 6)
  local f = h * 6 - i
  local p, q, t = v * (1 - s), v * (1 - f * s), v * (1 - (1 - f) * s)
  local r, g, b
  if i == 0 then r, g, b = v, t, p
  elseif i == 1 then r, g, b = q, v, p
  elseif i == 2 then r, g, b = p, v, t
  elseif i == 3 then r, g, b = p, q, v
  elseif i == 4 then r, g, b = t, p, v
  else r, g, b = v, p, q end
  return round(r * 255), round(g * 255), round(b * 255)
end

local function rgb2hsv(r, g, b)
  r, g, b = r / 255, g / 255, b / 255
  local mx, mn = math.max(r, g, b), math.min(r, g, b)
  local d = mx - mn
  local h = 0
  if d > 0 then
    if mx == r then h = ((g - b) / d) % 6
    elseif mx == g then h = (b - r) / d + 2
    else h = (r - g) / d + 4 end
    h = h / 6
  end
  return h, mx == 0 and 0 or d / mx, mx
end

-- ------------------------------------------------------------- state accessors
local function seg()
  if not S or not S.state or not S.state.seg then return nil end
  local n = #S.state.seg
  if n == 0 then return nil end
  selSeg = clamp(selSeg, 1, n)
  return S.state.seg[selSeg]
end

local SLN = { 'Effect speed', 'Effect intensity', 'Custom 1', 'Custom 2', 'Custom 3', 'Option 1', 'Option 2', 'Option 3' }
local COLN = { 'Fx', 'Bg', 'Cs' }

-- fxdata format: "sliders;colours;palette;flags;defaults"
local function meta(id)
  local m = { sl = {}, col = {}, pal = true }
  if #fxdata == 0 then
    for i = 1, 5 do m.sl[i] = SLN[i] end
    m.col = { COLN[1], COLN[2], COLN[3] }
    return m
  end
  local d = fxdata[id + 1]
  if not d or d == '' then
    m.col = { COLN[1], COLN[2], COLN[3] }
    m.pal = false
    return m
  end
  local p = split(d, ';')
  local sl = split(p[1] or '', ',')
  for i = 1, 8 do
    local x = sl[i]
    if x and x ~= '' then m.sl[i] = (x == '!') and SLN[i] or x end
  end
  local cl = split(p[2] or '', ',')
  for i = 1, 3 do
    local x = cl[i]
    if x and x ~= '' then m.col[i] = (x == '!') and COLN[i] or x end
  end
  m.pal = (p[3] or '') ~= ''
  local defaultPal = (p[5] or ''):match('pal=(%d+)')
  if defaultPal then m.defaultPal = tonumber(defaultPal) end
  return m
end

local function fxLabel(i) return fxNames[i + 1] or ('Effect ' .. i) end
local function palLabel(i) return palNames[i + 1] or ('Palette ' .. i) end

local function presetLabel(id)
  if not id or id < 0 then return 'None' end
  for i, pid in ipairs(presetIds) do
    if pid == id then return presetNames[i] end
  end
  return 'Preset ' .. id
end

local function deviceLabel()
  if scanning then return 'Scanning network...' end
  local cur = ip()
  if cur == '' then return 'No device - press Scan' end
  for _, d in ipairs(devices) do
    if d.ip == cur then return d.name .. '  ' .. d.ip end
  end
  return cur
end

-- ------------------------------------------------------------- layout
local shown, ypos, xpos, wpos = {}, {}, {}, {}

local function showMeter(name, v)
  if shown[name] == v then return end
  shown[name] = v
  SKIN:Bang(v and '!ShowMeter' or '!HideMeter', name)
  dirty = true
end

local function setOpt(store, name, opt, v)
  if store[name] == v then return end
  store[name] = v
  SKIN:Bang('!SetOption', name, opt, v)
  dirty = true
end

local TOP = 188

-- Each block is a vertical slot: h = height, m = { meter, y-offset, ... }
local function buildPages(m)
  local p = {}
  p[1] = {
    { h = 56, m = { 'Slot1', 0, 'Slot2', 0, 'Slot3', 0, 'SlotL1', 34, 'SlotL2', 34, 'SlotL3', 34 } },
    { h = 38, m = { 'HexBtn', 14 } },
    { h = 54, m = { 'LblHue', 0, 'Spectrum', 18, 'HueMark', 16 } },
    { h = 44, m = { 'LblSat', 0, 'BarSat', 18 } },
    { h = 44, m = { 'LblVal', 0, 'BarVal', 18 } },
    { h = 44, vis = hasW, m = { 'LblW', 0, 'BarW', 18 } },
    { h = 44, vis = hasCct, m = { 'LblCct', 0, 'BarCct', 18 } },
    { h = 34, m = { 'Sw1', 0, 'Sw2', 0, 'Sw3', 0, 'Sw4', 0, 'Sw5', 0, 'Sw6', 0, 'Sw7', 0, 'Sw8', 0,
                    'Sw9', 0, 'Sw10', 0, 'Sw11', 0, 'Sw12', 0 } },
  }
  local fxPage = {
    { h = 58, m = { 'LblFx', 0, 'FxPanel', 16, 'FxPrev', 30, 'FxText', 30, 'FxNext', 30, 'FxRand', 30 } },
  }
  for i = 1, 5 do
    fxPage[#fxPage + 1] = { h = 44, vis = m.sl[i] ~= nil, m = { 'LblS' .. i, 0, 'BarS' .. i, 18 } }
  end
  fxPage[#fxPage + 1] = { h = 42, vis = (m.sl[6] or m.sl[7] or m.sl[8]) ~= nil, checks = true,
                          m = { 'Ck1', 14, 'Ck2', 14, 'Ck3', 14 } }
  fxPage[#fxPage + 1] = { h = 62, m = { 'LblPal', 0, 'PalPanel', 16, 'PalPrev', 30, 'PalText', 30, 'PalNext', 30 } }
  p[2] = fxPage
  p[3] = {
    { h = 58, m = { 'LblSeg', 0, 'SegPanel', 16, 'SegPrev', 30, 'SegText', 30, 'SegNext', 30 } },
    { h = 42, m = { 'TgSegOn', 14, 'TgRev', 14, 'TgMir', 14, 'TgFrz', 14 } },
    { h = 44, m = { 'LblSegBri', 0, 'BarSegBri', 18 } },
    { h = 44, m = { 'LblStart', 0, 'BarStart', 18 } },
    { h = 44, m = { 'LblStop', 0, 'BarStop', 18 } },
    { h = 42, m = { 'SegAdd', 14, 'SegDel', 14 } },
  }
  p[4] = {
    { h = 58, m = { 'LblPre', 0, 'PrePanel', 16, 'PrePrev', 30, 'PreText', 30, 'PreNext', 30 } },
    { h = 44, m = { 'LblTrans', 0, 'BarTrans', 18 } },
    { h = 20, m = { 'LblNl', 0 } },
    { h = 42, m = { 'TgNl', 14, 'NlMode', 14 } },
    { h = 44, m = { 'LblNlDur', 0, 'BarNlDur', 18 } },
    { h = 44, m = { 'LblNlBri', 0, 'BarNlBri', 18 } },
    { h = 20, m = { 'LblSync', 0 } },
    { h = 42, m = { 'TgSend', 14, 'TgRecv', 14 } },
    { h = 36, m = { 'InfoA', 0, 'InfoB', 16 } },
    { h = 36, m = { 'WebUI', 14, 'Reboot', 14 } },
  }
  return p
end

local function layout()
  local sg = seg()
  local m = meta(sg and sg.fx or 0)
  local pages = buildPages(m)
  for pg, blocks in ipairs(pages) do
    local y = TOP
    for _, b in ipairs(blocks) do
      local vis = (b.vis == nil) or b.vis
      local on = (pg == page) and vis
      local idx = {}
      for i = 1, #b.m, 2 do
        local name = b.m[i]
        local mOn = on
        if b.checks then
          local n = tonumber(name:sub(3))
          mOn = on and m.sl[5 + n] ~= nil
          if mOn then idx[#idx + 1] = n end
        end
        if mOn then setOpt(ypos, name, 'Y', y + b.m[i + 1]) end
        showMeter(name, mOn)
      end
      if b.checks and on and #idx > 0 then
        local w = (328 - (#idx - 1) * 8) / #idx
        for k, n in ipairs(idx) do
          setOpt(xpos, 'Ck' .. n, 'X', round(16 + (k - 1) * (w + 8) + w / 2))
          setOpt(wpos, 'Ck' .. n, 'W', round(w))
        end
      end
      if vis then y = y + b.h end
    end
  end
end

-- ------------------------------------------------------------- render state into variables
local function fmtUptime(sec)
  sec = sec or 0
  local d, h, mi = math.floor(sec / 86400), math.floor(sec / 3600) % 24, math.floor(sec / 60) % 60
  if d > 0 then return d .. 'd ' .. h .. 'h' end
  if h > 0 then return h .. 'h ' .. mi .. 'm' end
  return mi .. 'm ' .. (sec % 60) .. 's'
end

local NLMODES = { [0] = 'Instant', 'Fade', 'Colour fade', 'Sunrise' }
local ACC, OFFC = '0,150,255,255', '50,50,70,255'

function Render()
  local sg = seg()
  if not sg then return end
  local st, info = S.state, S.info or {}
  local leds = info.leds or {}
  local count = leds.count or sg.stop or 1
  local lc = sg.lc or leds.lc or 1
  hasW = math.floor(lc / 2) % 2 == 1
  hasCct = math.floor(lc / 4) % 2 == 1
  local m = meta(sg.fx or 0)
  sg.col = sg.col or {}

  setVar('On', st.on and 1 or 0)
  setVar('PowerCol', st.on and '0,150,255' or '90,90,110')
  setVar('Name', info.name or 'WLED')
  setVar('Sub', ip() .. '  -  v' .. (info.ver or '?') .. '  -  ' .. count .. ' LEDs')
  if not requestFailed and not scanning and scanStatus == 'Connecting...' then
    scanStatus = 'Connected'
  end
  setVar('StatusText', scanStatus)
  setVar('Fbri', clamp((st.bri or 0) / 255, 0, 1))
  setVar('TxtBri', 'BRIGHTNESS  ' .. (st.bri or 0) .. ' / 255')

  for i = 1, 3 do
    local c = sg.col[i] or { 0, 0, 0 }
    setVar('C' .. i, (c[1] or 0) .. ',' .. (c[2] or 0) .. ',' .. (c[3] or 0))
    setVar('Stk' .. i, i == slot and '255,255,255,255' or '255,255,255,60')
    setVar('SlotL' .. i, i .. ' - ' .. (m.col[i] or 'unused'))
  end
  local c = sg.col[slot] or { 0, 0, 0 }
  local r, g, b, w = c[1] or 0, c[2] or 0, c[3] or 0, c[4] or 0
  setVar('Hex', string.format('%02X%02X%02X', r, g, b))
  local h, s, v
  if hsvMem then
    local mr, mg, mb = hsv2rgb(hsvMem[1], hsvMem[2], hsvMem[3])
    if mr == r and mg == g and mb == b then h, s, v = hsvMem[1], hsvMem[2], hsvMem[3] end
  end
  if not h then h, s, v = rgb2hsv(r, g, b) end
  local hr, hg, hb = hsv2rgb(h, 1, 1)
  local sr, sg2, sb = hsv2rgb(h, s, 1)
  setVar('HueCol', hr .. ',' .. hg .. ',' .. hb)
  setVar('SatCol', sr .. ',' .. sg2 .. ',' .. sb)
  setVar('Fhue', h)
  setVar('Fsat', s)
  setVar('Fval', v)
  setVar('TxtSat', 'SATURATION  ' .. round(s * 100) .. '%')
  setVar('TxtVal', 'VALUE  ' .. round(v * 100) .. '%')
  setVar('Fw', clamp(w / 255, 0, 1))
  setVar('TxtW', 'WHITE CHANNEL  ' .. w)
  setVar('Fcct', clamp((sg.cct or 0) / 255, 0, 1))
  setVar('TxtCct', 'WHITE TEMPERATURE  ' .. (sg.cct or 0) .. '  (0 warm - 255 cool)')

  setVar('FxName', fxLabel(sg.fx or 0))
  setVar('PalName', palLabel(sg.pal or 0))
  setVar('TxtPal', m.pal and 'PALETTE' or 'PALETTE  (not used by this effect)')
  local keys = { 'sx', 'ix', 'c1', 'c2', 'c3' }
  for i = 1, 5 do
    local val = sg[keys[i]] or 0
    setVar('TxtS' .. i, string.upper(m.sl[i] or SLN[i]) .. '  ' .. val)
    setVar('Fs' .. i, clamp(val / 255, 0, 1))
  end
  for i = 1, 3 do
    setVar('TxtCk' .. i, m.sl[5 + i] or SLN[5 + i])
    setVar('CkC' .. i, sg['o' .. i] and ACC or OFFC)
  end

  local nseg = #st.seg
  local stop = sg.stop or count
  local start = sg.start or 0
  setVar('SegText', 'Segment ' .. selSeg .. ' of ' .. nseg .. '   (LEDs ' .. start .. '-' .. (stop - 1) .. ')')
  setVar('TgSegOnC', sg.on and ACC or OFFC)
  setVar('TgRevC', sg.rev and ACC or OFFC)
  setVar('TgMirC', sg.mi and ACC or OFFC)
  setVar('TgFrzC', sg.frz and ACC or OFFC)
  setVar('Fsb', clamp((sg.bri or 0) / 255, 0, 1))
  setVar('TxtSegBri', 'SEGMENT BRIGHTNESS  ' .. (sg.bri or 0) .. ' / 255')
  setVar('Fstart', clamp(start / math.max(1, count), 0, 1))
  setVar('TxtStart', 'START LED  ' .. start)
  setVar('Fstop', clamp(stop / math.max(1, count), 0, 1))
  setVar('TxtStop', 'STOP LED  ' .. stop .. '  (of ' .. count .. ')')

  setVar('PreText', presetLabel(st.ps))
  local tr = st.transition or 0
  setVar('Ftrans', clamp(tr / 100, 0, 1))
  setVar('TxtTrans', 'TRANSITION TIME  ' .. string.format('%.1f', tr / 10) .. ' s')
  local nl = st.nl or {}
  setVar('TgNlC', nl.on and ACC or OFFC)
  setVar('TgNlT', nl.on and 'Sleep timer: ON' or 'Sleep timer: OFF')
  setVar('NlModeT', 'Mode: ' .. (NLMODES[nl.mode or 1] or '?'))
  setVar('Fdur', clamp((nl.dur or 1) / 120, 0, 1))
  setVar('TxtNlDur', 'FADE DURATION  ' .. (nl.dur or 1) .. ' min')
  setVar('Fnlbri', clamp((nl.tbri or 0) / 255, 0, 1))
  setVar('TxtNlBri', 'TARGET BRIGHTNESS  ' .. (nl.tbri or 0))
  local u = st.udpn or {}
  setVar('TgSendC', u.send and ACC or OFFC)
  setVar('TgRecvC', u.recv and ACC or OFFC)
  local wifi = info.wifi or {}
  setVar('InfoA', 'Uptime ' .. fmtUptime(info.uptime) .. '   -   WiFi ' .. (wifi.signal or '?') .. '% (' ..
    (wifi.rssi or '?') .. ' dBm)   -   ' .. (info.arch or '?'))
  setVar('InfoB', 'Free heap ' .. round((info.freeheap or 0) / 1024) .. ' KB   -   ' ..
    (leds.fps or '?') .. ' fps   -   ' .. (leds.pwr or 0) .. ' mA')

  for i = 1, 4 do setVar('TabC' .. i, i == page and ACC or OFFC) end
  setVar('DevLabel', deviceLabel())
  layout()
  if picker.mode then RenderPicker() end
  redraw()
end

local function refreshLabel()
  setVar('DevLabel', deviceLabel())
  redraw()
end

-- ------------------------------------------------------------- lifecycle
function Initialize()
  math.randomseed(os.time())
  postSession = tostring(os.time()) .. tostring(math.random(100000, 999999))
  LoadDevices(true)
  if ip() ~= '' and not normalizeAddress(ip()) then
    SKIN:Bang('!SetVariable', 'IP', '')
    SKIN:Bang('!WriteKeyValue Variables IP "" "#@#Variables.inc"')
    showStatus('Saved address invalid; scanning...', true)
  end
  if ip() == '' then StartScan() end
  for i = 1, 4 do setVar('TabC' .. i, i == page and ACC or OFFC) end
  layout()
  redraw(true)
end

local function listFrom(raw)
  local t = raw and jdecode(raw)
  return type(t) == 'table' and t or {}
end

local function changed(key, file)
  local s = dl(file)
  if s and s ~= '' and s ~= lastRaw[key] then
    lastRaw[key] = s
    return s
  end
end

function Update()
  local reload = false
  local s = changed('eff', 'eff.json')
  if s then fxNames = listFrom(s) reload = true end
  s = changed('pal', 'pal.json')
  if s then palNames = listFrom(s) reload = true end
  s = changed('fxdata', 'fxdata.json')
  if s then fxdata = listFrom(s) reload = true end
  s = changed('presets', 'presets.json')
  if s then
    local t = jdecode(s) or {}
    local ids = {}
    for k, v in pairs(t) do
      local id = tonumber(k)
      if id and id > 0 and type(v) == 'table' and v.n then ids[#ids + 1] = id end
    end
    table.sort(ids)
    presetIds, presetNames = ids, {}
    for i, id in ipairs(ids) do presetNames[i] = id .. '  ' .. t[tostring(id)].n end
    reload = true
  end

  if reload and S then Render() end

  pollPostResult()
  if scanning and scanStarted and os.time() - scanStarted > 60 then
    scanning = false
    showStatus('Scan timed out - try again', true)
  end

  if rbArm > 0 and os.time() - rbArm > 5 then
    rbArm = 0
    setVar('RbTxt', 'Reboot')
    redraw()
  end
  return 0
end

function StateDownloaded()
  if postInFlight or #postQueue > 0 then return end
  local raw = dl('state.json')
  if not raw or raw == '' or raw == lastRaw.state then return end
  lastRaw.state = raw
  local t = jdecode(raw)
  if t and t.state and t.state.seg then
    S = t
    Render()
  else
    SetOffline()
  end
end

function SetOffline()
  S = nil
  postQueue = {}
  setVar('Name', 'Offline')
  setVar('Sub', ip() == '' and 'No device selected' or ('Cannot reach ' .. ip()))
  setVar('PowerCol', '70,70,90')
  showStatus('Device unavailable', true)
  redraw()
end

-- ------------------------------------------------------------- devices
function SetIP(addr)
  local normalized = normalizeAddress(addr)
  if not normalized then
    showStatus('Enter a valid IPv4 address or hostname', true)
    return false
  end
  addr = normalized
  SKIN:Bang('!SetVariable', 'IP', addr)
  SKIN:Bang('!WriteKeyValue Variables IP "' .. addr .. '" "#@#Variables.inc"')
  S = nil
  postQueue = {}
  requestFailed = false
  scanStatus = 'Connecting...'
  setVar('StatusText', scanStatus)
  setVar('Name', 'Connecting...')
  setVar('Sub', addr)
  setVar('DevLabel', addr)
  lastRaw = {}
  redraw(true)
  for _, mname in ipairs({ 'State', 'Eff', 'Pal', 'FxData', 'Presets' }) do
    SKIN:Bang('!CommandMeasure', mname, 'Update')
  end
  return true
end

function SetIPFromInput()
  local measure = SKIN:GetMeasure('InputIP')
  SetIP(measure and measure:GetStringValue() or '')
end

function SelectDevice(i)
  if #devices == 0 then return end
  devIdx = ((i - 1) % #devices) + 1
  SetIP(devices[devIdx].ip)
end

function StepDevice(delta) SelectDevice(devIdx + delta) end

function LoadDevices(quiet)
  local scanWasStarted = scanStarted ~= nil
  scanning = false
  scanStarted = nil
  devices = {}
  local s = readFile(SKIN:GetVariable('@') .. 'Devices.txt')
  if s then
    for line in s:gmatch('[^\r\n]+') do
      local addr, name = line:match('^(.-)|(.*)$')
      if addr then devices[#devices + 1] = { ip = addr, name = name ~= '' and name or 'WLED' } end
    end
  end
  table.sort(devices, function(a, b) return a.ip < b.ip end)

  if scanWasStarted then
    local status = readFile(SKIN:GetVariable('@') .. 'ScanStatus.txt') or ''
    local kind, message = status:match('^(%u+)|([^\r\n]+)')
    if kind == 'ERROR' then
      showStatus('Scan failed: ' .. message, true)
    elseif kind == 'OK' then
      showStatus(message, false)
    else
      showStatus('Scan finished', false)
    end
  end

  local found = false
  for i, d in ipairs(devices) do
    if d.ip == ip() then devIdx = i found = true end
  end
  if not found and #devices > 0 and (ip() == '' or quiet ~= true) then
    SelectDevice(1)
  elseif not quiet and #devices == 0 then
    setVar('DevLabel', 'No WLED found - click here to enter IP')
    redraw()
  else
    refreshLabel()
  end
end

function StartScan()
  if scanning then return end
  scanning = true
  scanStarted = os.time()
  showStatus('Scanning local IPv4 networks...', false)
  refreshLabel()
  local at = SKIN:GetVariable('@')
  SKIN:Bang('["wscript.exe" //B //NoLogo "' .. at .. 'RunHidden.vbs" "' ..
    at .. 'Scan.ps1" -Config "' .. SKIN:GetVariable('CURRENTCONFIG') ..
    '" -Rainmeter "' .. SKIN:GetVariable('PROGRAMPATH') .. 'Rainmeter.exe" -Out "' ..
    at .. 'Devices.txt" -Status "' .. at .. 'ScanStatus.txt"]')
end

-- ------------------------------------------------------------- sending
refreshState = function()
  lastRaw.state = nil
  SKIN:Bang('!CommandMeasure', 'State', 'Update')
end

dispatchPost = function()
  if postInFlight or #postQueue == 0 then return end
  local request = table.remove(postQueue, 1)
  if request.address ~= ip() then
    return dispatchPost()
  end

  postSequence = postSequence + 1
  local suffix = postSession .. '-' .. postSequence
  local at = SKIN:GetVariable('@')
  local payloadPath = at .. 'cmd-' .. suffix .. '.json'
  local resultPath = at .. 'result-' .. suffix .. '.txt'
  local f = io.open(payloadPath, 'w')
  if not f then
    postQueue = {}
    requestFailed = true
    showStatus('Command failed: cannot write request file', true)
    refreshState()
    return
  end
  f:write(request.json)
  f:close()

  postInFlight = {
    address = request.address,
    payloadPath = payloadPath,
    resultPath = resultPath,
    deadline = os.time() + 15,
  }
  local command = '["wscript.exe" //B //NoLogo "' .. at .. 'RunHidden.vbs" "' ..
    at .. 'Post.ps1" -Address "' .. request.address .. '" -Payload "' .. payloadPath ..
    '" -Result "' .. resultPath .. '"]'
  SKIN:Bang(command)
end

pollPostResult = function()
  if not postInFlight then return end
  local request = postInFlight
  local result = readFile(request.resultPath)
  if (not result or result == '') and os.time() < request.deadline then return end
  if not result or result == '' then result = 'ERROR|request timed out' end

  postInFlight = nil
  os.remove(request.payloadPath)
  os.remove(request.resultPath)
  local kind, message = result:match('^(%u+)|([^\r\n]+)')
  if request.address == ip() then
    if kind == 'OK' then
      if #postQueue == 0 then
        if not requestFailed then showStatus('Command accepted by WLED', false) end
        refreshState()
      else
        showStatus('Sending queued commands...', false)
        dispatchPost()
      end
    else
      postQueue = {}
      requestFailed = true
      showStatus('Command failed: ' .. (message or 'unknown error'), true)
      refreshState()
    end
  else
    if #postQueue > 0 then dispatchPost() else refreshState() end
  end
end

local function post(json)
  local address = normalizeAddress(ip())
  if not address then
    showStatus('Choose a valid WLED address first', true)
    return
  end
  if #postQueue >= MAX_QUEUED_POSTS then
    postQueue = {}
    requestFailed = true
    showStatus('Command queue full - pending changes cancelled', true)
    if not postInFlight then refreshState() end
    return
  end
  postQueue[#postQueue + 1] = { address = address, json = json }
  requestFailed = false
  showStatus('Sending command...', false)
  dispatchPost()
end

local function segPost(frag)
  local sg = seg()
  if not sg then return end
  post('{"seg":[{"id":' .. (sg.id or 0) .. ',' .. frag .. '}]}')
end

local function colJson(sg)
  local t = {}
  for i = 1, 3 do
    local c = sg.col[i] or { 0, 0, 0 }
    t[i] = '[' .. (c[1] or 0) .. ',' .. (c[2] or 0) .. ',' .. (c[3] or 0) ..
      (hasW and (',' .. (c[4] or 0)) or '') .. ']'
  end
  return '"col":[' .. table.concat(t, ',') .. ']'
end

-- ------------------------------------------------------------- global controls
function SetPage(n)
  page = n
  if picker.mode then ClosePicker() end
  Render()
  layout()
  redraw(true)
end

function Toggle()
  if not S then return end
  S.state.on = not S.state.on
  post('{"on":' .. bool(S.state.on) .. '}')
  Render()
end

function SetBri(pct)
  if not S then return end
  local v = math.max(1, toByte(pct))
  S.state.bri = v
  post('{"bri":' .. v .. '}')
  Render()
end

-- ------------------------------------------------------------- colours
function SelectSlot(n)
  slot = n
  hsvMem = nil
  Render()
end

function SetRGB(r, g, b)
  local sg = seg()
  if not sg then return end
  local old = sg.col[slot] or { 0, 0, 0 }
  sg.col[slot] = { r, g, b, old[4] }
  segPost(colJson(sg))
  Render()
end

function SetHex(hex)
  if type(hex) ~= 'string' then return end
  hex = hex:gsub('#', '')
  if #hex == 6 and hex:match('^%x+$') then
    hsvMem = nil
    SetRGB(tonumber(hex:sub(1, 2), 16), tonumber(hex:sub(3, 4), 16), tonumber(hex:sub(5, 6), 16))
  end
end

function SetHexFromInput()
  local measure = SKIN:GetMeasure('InputHex')
  SetHex(measure and measure:GetStringValue() or '')
end

function SetColorStr(str)
  local r, g, b = str:match('(%d+)%s*,%s*(%d+)%s*,%s*(%d+)')
  if r then
    hsvMem = nil
    SetRGB(tonumber(r), tonumber(g), tonumber(b))
  end
end

local function curHSV()
  local sg = seg()
  local c = sg and sg.col[slot] or { 0, 0, 0 }
  if hsvMem then
    local mr, mg, mb = hsv2rgb(hsvMem[1], hsvMem[2], hsvMem[3])
    if mr == c[1] and mg == c[2] and mb == c[3] then return hsvMem[1], hsvMem[2], hsvMem[3] end
  end
  return rgb2hsv(c[1] or 0, c[2] or 0, c[3] or 0)
end

local function setHSV(h, s, v)
  hsvMem = { h, s, v }
  SetRGB(hsv2rgb(h, s, v))
end

function SetHue(pct)
  local _, s, v = curHSV()
  if s < 0.05 then s = 1 end
  if v < 0.05 then v = 1 end
  setHSV(math.min(clamp(pct, 0, 100) / 100, 0.9999), s, v)
end

function SetSat(pct)
  local h, _, v = curHSV()
  if v < 0.05 then v = 1 end
  setHSV(h, clamp(pct, 0, 100) / 100, v)
end

function SetVal(pct)
  local h, s = curHSV()
  setHSV(h, s, clamp(pct, 0, 100) / 100)
end

function SetWhite(pct)
  local sg = seg()
  if not sg then return end
  local c = sg.col[slot] or { 0, 0, 0 }
  c[4] = toByte(pct)
  sg.col[slot] = c
  segPost(colJson(sg))
  Render()
end

function SetCct(pct)
  local sg = seg()
  if not sg then return end
  sg.cct = toByte(pct)
  segPost('"cct":' .. sg.cct)
  Render()
end

-- ------------------------------------------------------------- effect, palette, parameters
local function applyFx(i)
  local sg = seg()
  if not sg then return end
  local m = meta(i)
  sg.fx = i
  if m.defaultPal then sg.pal = m.defaultPal end
  segPost('"fx":' .. i .. ',"fxdef":true')
  Render()
end

local function applyPal(i)
  local sg = seg()
  if not sg then return end
  sg.pal = i
  segPost('"pal":' .. i)
  Render()
end

local function step(current, delta, count)
  if count < 1 then return math.max(0, current + delta) end
  return (current + delta) % count
end

function StepFx(delta)
  local sg = seg()
  if sg then applyFx(step(sg.fx or 0, delta, #fxNames)) end
end

function StepPal(delta)
  local sg = seg()
  if sg then applyPal(step(sg.pal or 0, delta, #palNames)) end
end

function RandomFx()
  if #fxNames > 0 then applyFx(math.random(0, #fxNames - 1)) end
end

local SEGKEYS = { 'sx', 'ix', 'c1', 'c2', 'c3' }

-- i = 1..5 -> speed, intensity, custom 1-3
function SetParam(i, pct)
  local sg = seg()
  if not sg then return end
  local key, v = SEGKEYS[i], toByte(pct)
  sg[key] = v
  segPost('"' .. key .. '":' .. v)
  Render()
end

function ToggleOpt(i)
  local sg = seg()
  if not sg then return end
  local key = 'o' .. i
  sg[key] = not sg[key]
  segPost('"' .. key .. '":' .. bool(sg[key]))
  Render()
end

-- ------------------------------------------------------------- segments
function StepSeg(delta)
  if not S then return end
  selSeg = ((selSeg - 1 + delta) % #S.state.seg) + 1
  hsvMem = nil
  Render()
end

function ToggleSegFlag(key)
  local sg = seg()
  if not sg then return end
  sg[key] = not sg[key]
  segPost('"' .. key .. '":' .. bool(sg[key]))
  Render()
end

function SetSegBri(pct)
  local sg = seg()
  if not sg then return end
  sg.bri = toByte(pct)
  segPost('"bri":' .. sg.bri)
  Render()
end

local function ledCount(sg)
  return (S.info and S.info.leds and S.info.leds.count) or sg.stop
end

function SetSegStart(pct)
  local sg = seg()
  if not sg then return end
  local count = ledCount(sg)
  sg.start = clamp(round(clamp(pct, 0, 100) / 100 * count), 0, (sg.stop or count) - 1)
  segPost('"start":' .. sg.start)
  Render()
end

function SetSegStop(pct)
  local sg = seg()
  if not sg then return end
  local count = ledCount(sg)
  sg.stop = clamp(round(clamp(pct, 0, 100) / 100 * count), (sg.start or 0) + 1, count)
  segPost('"stop":' .. sg.stop)
  Render()
end

local function copy(t)
  if type(t) ~= 'table' then return t end
  local r = {}
  for k, v in pairs(t) do r[k] = copy(v) end
  return r
end

-- Splits the selected segment in half; the second half becomes a new segment.
function AddSeg()
  local sg = seg()
  if not sg then return end
  local maxseg = (S.info and S.info.leds and S.info.leds.maxseg) or 16
  if #S.state.seg >= maxseg then return end
  local start, stop = sg.start or 0, sg.stop or 0
  if stop - start < 2 then return end
  local maxId = 0
  for _, s2 in ipairs(S.state.seg) do maxId = math.max(maxId, s2.id or 0) end
  local mid = start + math.floor((stop - start) / 2)
  local new = copy(sg)
  new.id, new.start, new.stop = maxId + 1, mid, stop
  sg.stop = mid
  table.insert(S.state.seg, selSeg + 1, new)
  post('{"seg":[{"id":' .. sg.id .. ',"stop":' .. mid .. '},{"id":' .. new.id .. ',"start":' .. mid ..
    ',"stop":' .. stop .. '}]}')
  selSeg = selSeg + 1
  Render()
end

function DeleteSeg()
  local sg = seg()
  if not sg or #S.state.seg < 2 then return end
  post('{"seg":[{"id":' .. (sg.id or 0) .. ',"stop":0}]}')
  table.remove(S.state.seg, selSeg)
  selSeg = math.max(1, selSeg - 1)
  Render()
end

-- ------------------------------------------------------------- presets, nightlight, sync, system
local function applyPreset(id)
  if not S then return end
  S.state.ps = id
  post('{"ps":' .. id .. '}')
  Render()
end

function StepPreset(delta)
  if #presetIds == 0 or not S then return end
  local cur = S.state.ps or -1
  local idx = 0
  for i, id in ipairs(presetIds) do if id == cur then idx = i end end
  if idx == 0 then idx = delta > 0 and 0 or 1 end
  idx = ((idx - 1 + delta) % #presetIds) + 1
  applyPreset(presetIds[idx])
end

function SetTransition(pct)
  if not S then return end
  S.state.transition = round(clamp(pct, 0, 100))
  post('{"transition":' .. S.state.transition .. '}')
  Render()
end

local function nlPost(key, value, text)
  if not S then return end
  S.state.nl = S.state.nl or {}
  S.state.nl[key] = value
  post('{"nl":{"' .. key .. '":' .. text .. '}}')
  Render()
end

function Nightlight()
  if not S then return end
  local on = not (S.state.nl or {}).on
  nlPost('on', on, bool(on))
end

function NightlightMode()
  if not S then return end
  local mode = (((S.state.nl or {}).mode or 1) + 1) % 4
  nlPost('mode', mode, tostring(mode))
end

function SetNlDur(pct)
  local v = clamp(round(clamp(pct, 0, 100) / 100 * 119) + 1, 1, 120)
  nlPost('dur', v, tostring(v))
end

function SetNlBri(pct)
  local v = toByte(pct)
  nlPost('tbri', v, tostring(v))
end

function ToggleSync(key)
  if not S then return end
  S.state.udpn = S.state.udpn or {}
  S.state.udpn[key] = not S.state.udpn[key]
  post('{"udpn":{"' .. key .. '":' .. bool(S.state.udpn[key]) .. '}}')
  Render()
end

function OpenWebUI()
  if ip() ~= '' then SKIN:Bang('["http://' .. ip() .. '"]') end
end

function Reboot()
  if rbArm > 0 and os.time() - rbArm <= 5 then
    rbArm = 0
    post('{"rb":true}')
    setVar('RbTxt', 'Rebooting...')
    SetOffline()
  else
    rbArm = os.time()
    setVar('RbTxt', 'Click again to confirm')
    redraw()
  end
end

-- ------------------------------------------------------------- picker (effects / palettes / presets)
local function pickerData()
  local sg, st = seg(), S and S.state or {}
  if picker.mode == 'fx' then return fxNames, nil, sg and sg.fx or 0, 'SELECT EFFECT' end
  if picker.mode == 'pal' then return palNames, nil, sg and sg.pal or 0, 'SELECT PALETTE' end
  return presetNames, presetIds, st.ps or -1, 'SELECT PRESET'
end

function RenderPicker()
  local list, ids, cur, title = pickerData()
  local total = #list
  picker.offset = clamp(picker.offset, 0, math.max(0, total - ROWS))
  for i = 1, ROWS do
    local idx = picker.offset + i
    local isCur = list[idx] and ((ids and ids[idx] == cur) or (not ids and idx - 1 == cur))
    setVar('Row' .. i, list[idx] or '')
    setVar('RowC' .. i, isCur and '0,150,255,255' or '0,0,0,1')
  end
  setVar('PickTitle', title)
  setVar('PickInfo', total == 0 and 'Nothing to show yet - press Refresh' or
    ((picker.offset + 1) .. '-' .. math.min(total, picker.offset + ROWS) .. ' of ' .. total ..
     '   (scroll with the mouse wheel)'))
  local thumbH = total <= ROWS and TRACK_H or math.max(20, TRACK_H * ROWS / total)
  local range = math.max(1, total - ROWS)
  setVar('PickThumbH', thumbH)
  setVar('PickThumbY', (TRACK_H - thumbH) * picker.offset / range)
  redraw(true)
end

function OpenPicker(mode)
  picker.mode = mode
  local _, ids, cur = pickerData()
  local pos = cur
  if ids then
    pos = 0
    for i, id in ipairs(ids) do if id == cur then pos = i - 1 end end
  end
  picker.offset = math.max(0, pos - math.floor(ROWS / 2))
  SKIN:Bang('!ShowMeterGroup Picker')
  RenderPicker()
end

function ClosePicker()
  picker.mode = nil
  SKIN:Bang('!HideMeterGroup Picker')
  redraw(true)
end

function PickerScroll(delta)
  if not picker.mode then return end
  picker.offset = picker.offset + delta
  RenderPicker()
end

function PickerScrollTo(pct)
  if not picker.mode then return end
  local list = pickerData()
  picker.offset = round(clamp(pct, 0, 100) / 100 * math.max(0, #list - ROWS))
  RenderPicker()
end

function PickRow(i)
  if not picker.mode then return end
  local list, ids = pickerData()
  local idx = picker.offset + i
  if not list[idx] then return end
  local mode = picker.mode
  ClosePicker()
  if mode == 'fx' then applyFx(idx - 1)
  elseif mode == 'pal' then applyPal(idx - 1)
  else applyPreset(ids[idx]) end
end

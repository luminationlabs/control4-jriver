--[[
  JRiver Media Center - Control4 MSP Driver

  Browses and controls JRiver Media Center directly over MCWS, with no helper
  service. Library navigation follows Media Center's own browse tree, so the
  categories shown in Navigator are whatever MC's Browse Rules define.

  See DESIGN.md for architecture and the MCWS endpoints used.

  Copyright 2026 Lumination Labs, Inc. MIT License.
]]

JSON = require('module.json')

function JSON:assert()
  -- Return nil on malformed payloads rather than throwing into the C4 sandbox.
end

--------------------------------------------------------------------------------
-- Globals
--------------------------------------------------------------------------------

do
  Navigators = Navigators or {}
  Navigator = Navigator or {}
  RFP = RFP or {}
  Timer = Timer or {}
  MCWS = MCWS or {}

  -- True while a room has this device selected as its source.
  DeviceSelected = false
  PlayerSelected = false

  Config = {
    host = '',
    port = 52199,
    zone = '-1',
    pollInterval = 2,
    cacheTtl = 300,
    takeFocus = false,
    enterTheaterOnSelect = true,
    leaveTheaterOnDeselect = true,
    leaveTheaterOnListen = true,
    handleVolume = false,
    username = '',
    password = '',
    debugMode = false,
  }

  -- Command table for the media_player proxy (Watch mode). Populated below.
  PLAYER = PLAYER or {}

  PlaybackState = {
    state = 'stopped',
    fileKey = nil,
    name = nil,
    artist = nil,
    album = nil,
    position = 0,
    positionSyncedAt = 0,
    duration = 0,
    queuePosition = 0,
    queueCount = 0,
    changeCounter = nil,
    shuffleMode = false,
    repeatMode = false,
    muted = false,
    uiMode = nil,
    viewName = '',
    selectionName = '',
  }

  -- Current Playing Now contents, refreshed only when the change counter moves.
  Queue = {}

  -- Browse tree state. Node IDs are allocation counters handed out by MC as the
  -- tree is walked; they are stable within a session but are reissued after a
  -- Browse/Reset or an MC restart, so they are never persisted.
  Browse = {
    tabIds = {},    -- tabId -> browse node id
    children = {},  -- node id -> { ts = <clock>, items = { ... } }
    files = {},     -- node id -> { ts = <clock>, items = { ... } }
  }

  Auth = { token = nil, obtainedAt = 0 }
  AUTH_TOKEN_TTL_S = 24 * 60 * 60

  -- Browse results are cached per node. The tree is walked freely, so without a
  -- ceiling this grows for the life of the driver on a large library.
  MAX_CACHED_NODES = 200

  GlobalTicketHandlers = GlobalTicketHandlers or {}

  -- Which browse node each tab lands on, expressed as a path through the tree
  -- so it survives MC reissuing IDs. Resolved lazily against Browse/Children.
  TAB_PATHS = {
    Artists   = {'Audio', 'Artist'},
    Albums    = {'Audio', 'Album'},
    Playlists = {'Playlists'},
    More      = {'Audio'},
  }

  SCREEN_TABS = {
    ArtistsScreen   = 'Artists',
    AlbumsScreen    = 'Albums',
    PlaylistsScreen = 'Playlists',
    MoreScreen      = 'More',
  }

  -- Fields requested for track listings. Names containing spaces or '#' are
  -- URL-encoded by MakeQuery.
  TRACK_FIELDS = 'Key,Name,Artist,Album,Album Artist,Track #,Duration,Genre'

  IMAGE_SIZES = {20, 30, 40, 50, 60, 70, 80, 90, 100, 110, 120, 130, 140, 300}

  -- The large artwork on the Now Playing screen, which is bigger than any list icon.
  NOW_PLAYING_ART_SIZE = 400

  MSP_BINDING = 5001
  PLAYER_BINDING = 5002
  -- Virtual amp. Exists only to give the service and the player a shared route
  -- to the AVR. It acknowledges input switching and is hidden from every room.
  SWITCH_BINDING = 5003

  -- Proxy command -> Media Center key name, sent via Control/Key. Key names are
  -- from MCWS's documented set: Up, Down, Left, Right, Enter, Backspace,
  -- Escape, Home, End, Page Up, Page Down, Menu, Apps, Space, Tab, letters, F1-F24.
  KEY_MAP = {
    UP = 'Up',
    DOWN = 'Down',
    LEFT = 'Left',
    RIGHT = 'Right',
    ENTER = 'Enter',
    SELECT = 'Enter',
    -- Backspace walks back one level in Theater View and eventually reaches
    -- home; Escape would drop out of Theater View entirely, which is not what
    -- a "back" press should do.
    CANCEL = 'Backspace',
    EXIT = 'Backspace',
    INFO = 'Menu',
    PAGE_UP = 'Page Up',
    PAGE_DOWN = 'Page Down',
  }

  -- Directional keys repeat while held.
  HOLD_REPEAT_MS = 300

  -- Window in which an identical view-switch command is treated as a repeat.
  LastViewCommand = { action = nil, at = 0 }
  VIEW_DEBOUNCE_S = 3

  -- UI_MODES value for Theater View, from UserInterface/Info.
  UI_MODE_THEATER = 3

  -- Media Core Commands, confirmed against MC 35.0.74. Entry and exit are
  -- asymmetric: 22001 with Parameter=0 enters Theater View but will not toggle
  -- back out, so leaving requires 22009.
  MCC_THEATER_VIEW = 22001
  MCC_SHOW_STANDARD_VIEW = 22009
  THEATER_MODE_TOGGLE = 0
  THEATER_MODE_HOME = 1
  THEATER_MODE_PLAYING_NOW = 2
  THEATER_MODE_AUDIO = 3

  -- How far <<  and  >> jump, in milliseconds, and how often a held scan
  -- repeats. MCWS also accepts Position=-1 to jump "the default amount for the
  -- media type", but an explicit step is predictable across content.
  SEEK_STEP_MS = 10000
  SCAN_REPEAT_MS = 500

  -- Poll rate when nothing is selected and nothing is playing.
  IDLE_POLL_MS = 30000

  -- Proxy commands seen but not handled, reported once each so a hardware test
  -- reveals exactly what the remote's buttons emit. The MSP documentation lists
  -- no scan/seek command at all, so whether << and >> reach a media service
  -- driver is unknown until it runs on real hardware.
  UnhandledCommands = {}

  -- Last value written to each variable, so unchanged values are not rewritten.
  VariableCache = {}
  Connected = nil

  LastSwitcherHide = 0
  SWITCHER_HIDE_INTERVAL_S = 60

  DRIVER_VERSION = '1.0.0'
end

--------------------------------------------------------------------------------
-- Logging
--------------------------------------------------------------------------------

function dbg(msg, ...)
  if Config.debugMode then
    print('[JRIVER] ' .. os.date('%X') .. ' ' .. tostring(msg), ...)
  end
end

function log(msg, ...)
  print('[JRIVER] ' .. tostring(msg), ...)
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

function OnDriverLateInit()
  dbg('OnDriverLateInit')

  if C4.AllowExecute then
    C4:AllowExecute(true)
  end

  C4:urlSetTimeout(10)

  for property, _ in pairs(Properties) do
    OnPropertyChanged(property)
  end

  C4:UpdateProperty('Driver Version', DRIVER_VERSION)
  SetupVariables()

  pcall(HideSwitcherInAllRooms)
  MCWS.RefreshToken()

  StartPolling()
end

function OnDriverDestroyed()
  dbg('OnDriverDestroyed')
  KillAllTimers()
end

function OnPropertyChanged(strProperty)
  local value = Properties[strProperty]
  if value == nil then value = '' end

  dbg('OnPropertyChanged: ' .. strProperty .. ' = ' .. tostring(value))

  if strProperty == 'Debug Mode' then
    Config.debugMode = (value == 'On')

  elseif strProperty == 'JRiver Host' then
    Config.host = value
    ResetBrowseCache()

  elseif strProperty == 'JRiver Port' then
    Config.port = tonumber(value) or 52199
    ResetBrowseCache()

  elseif strProperty == 'Zone' then
    Config.zone = (value ~= '' and value) or '-1'

  elseif strProperty == 'Poll Interval' then
    Config.pollInterval = tonumber(value) or 2
    StartPolling()

  elseif strProperty == 'Cache TTL' then
    Config.cacheTtl = tonumber(value) or 300

  elseif strProperty == 'Take Focus on Key' then
    Config.takeFocus = (value == 'On')

  elseif strProperty == 'Enter Theater View on Select' then
    Config.enterTheaterOnSelect = (value == 'On')

  elseif strProperty == 'Leave Theater View on Deselect' then
    Config.leaveTheaterOnDeselect = (value == 'On')

  elseif strProperty == 'Leave Theater View on Listen' then
    Config.leaveTheaterOnListen = (value == 'On')

  elseif strProperty == 'Handle Volume' then
    Config.handleVolume = (value == 'On')

  elseif strProperty == 'Username' then
    Config.username = value
    Auth.token = nil
    MCWS.RefreshToken()

  elseif strProperty == 'Password' then
    Config.password = value
    Auth.token = nil
    MCWS.RefreshToken()
  end
end

--------------------------------------------------------------------------------
-- MCWS client
--------------------------------------------------------------------------------

function URLEncode(s)
  if s == nil then return '' end
  return (string.gsub(tostring(s), '([^%w%-%.%_%~])', function(c)
    return string.format('%%%02X', string.byte(c))
  end))
end

-- Keys are sorted so the same parameters always produce a byte-identical URL.
-- MCWS does not care about order, but Navigators cache artwork by URL, and a
-- query string that reshuffles between polls defeats that cache.
function MakeQuery(params)
  if not params then return '' end

  local keys = {}
  for k, v in pairs(params) do
    if v ~= nil then table.insert(keys, k) end
  end

  if #keys == 0 then return '' end
  table.sort(keys)

  local parts = {}
  for _, k in ipairs(keys) do
    table.insert(parts, URLEncode(k) .. '=' .. URLEncode(params[k]))
  end

  return '?' .. table.concat(parts, '&')
end

-- Builds a fully qualified MCWS URL. Safe to hand to a Navigator for artwork:
-- the auth token, when one is in use, is embedded in the query string.
function MCWS.Url(path, params)
  if Config.host == '' then return nil end

  params = params or {}
  if Auth.token then
    params.Token = Auth.token
  end

  return string.format('http://%s:%d/MCWS/v1/%s%s',
    Config.host, Config.port, path, MakeQuery(params))
end

-- Media Network authentication is optional in Media Center and off by default.
-- Driver requests authenticate with a Basic header; artwork URLs cannot carry
-- headers because navigators fetch them directly, so those use a token instead.
function MCWS.AuthHeaders()
  if Config.username == '' then return {} end
  return {
    Authorization = 'Basic ' .. C4:Base64Encode(Config.username .. ':' .. Config.password),
  }
end

-- Fetches the token used to sign artwork URLs. Without this the Username and
-- Password properties did nothing at all: the token was read when building URLs
-- but nothing ever obtained one.
function MCWS.RefreshToken()
  if Config.username == '' then
    Auth.token = nil
    return
  end

  if Auth.token and (os.time() - Auth.obtainedAt) < AUTH_TOKEN_TTL_S then
    return
  end

  MCWS.Request('Authenticate', {}, 'items', function(err, data)
    if err or not data or not data.map.Token then
      log('Authentication failed: ' .. tostring(err or 'no token returned'))
      return
    end
    Auth.token = data.map.Token
    Auth.obtainedAt = os.time()
    dbg('Obtained auth token')
  end)
end

-- parseMode: 'items' (MCWS XML Item list) or 'json' (Action=JSON payloads).
function MCWS.Request(path, params, parseMode, callback)
  local url = MCWS.Url(path, params)
  if not url then
    if callback then callback('JRiver Host not configured', nil) end
    return
  end

  dbg('MCWS ' .. path .. ' ' .. MakeQuery(params))

  local ticket = C4:urlGet(url, MCWS.AuthHeaders(), false)

  if ticket and ticket ~= 0 then
    table.insert(GlobalTicketHandlers, {
      TICKET = ticket,
      PARSE = parseMode,
      CALLBACK = callback,
      PATH = path,
    })
  else
    dbg('Failed to create request ticket for ' .. path)
    if callback then callback('Request failed', nil) end
  end
end

function ReceivedAsync(ticketId, strData, responseCode, tHeaders, strError)
  for k, info in pairs(GlobalTicketHandlers) do
    if info.TICKET == ticketId then
      table.remove(GlobalTicketHandlers, k)

      if not info.CALLBACK then return end

      if strError then
        dbg('MCWS error on ' .. tostring(info.PATH) .. ': ' .. tostring(strError))
        info.CALLBACK(strError, nil)
        return
      end

      if responseCode == 401 then
        Auth.token = nil
        Auth.obtainedAt = 0
        if info.PATH ~= 'Authenticate' then MCWS.RefreshToken() end
        info.CALLBACK('HTTP 401 (check Username and Password)', nil)
        return
      end

      if responseCode and responseCode ~= 200 then
        info.CALLBACK('HTTP ' .. tostring(responseCode), nil)
        return
      end

      if info.PARSE == 'json' then
        local ok, decoded = pcall(function() return JSON:decode(strData) end)
        info.CALLBACK(nil, (ok and decoded) or nil)
      else
        info.CALLBACK(nil, MCWS.ParseItems(strData))
      end
      return
    end
  end
end

-- Turns <Response Status="OK"><Item Name="X" Type="2">val</Item></Response>
-- into { status = 'OK', items = { {name=, value=, attrs=} }, map = { X = val } }.
function MCWS.ParseItems(strData)
  local result = { status = nil, items = {}, map = {} }
  if not strData then return result end

  local parsed = C4:ParseXml(strData)
  if not parsed then return result end

  if parsed.Attributes then
    result.status = parsed.Attributes.Status
  end

  for _, node in pairs(parsed.ChildNodes or {}) do
    local attrs = node.Attributes or {}
    local name = attrs.Name
    local value = node.Value or ''

    table.insert(result.items, { name = name, value = value, attrs = attrs })
    if name then
      result.map[name] = value
    end
  end

  return result
end

function MCWS.ZoneParams(params)
  params = params or {}
  params.Zone = Config.zone
  params.ZoneType = 'ID'
  return params
end

-- Fire-and-forget command. MCWS returns Status="OK" for most control calls
-- whether or not they had an effect, so the response is logged, not trusted.
function MCWS.Command(path, params, label)
  MCWS.Request(path, params, 'items', function(err, data)
    if err then
      log((label or path) .. ' failed: ' .. tostring(err))
    else
      dbg((label or path) .. ' -> ' .. tostring(data and data.status))
    end
  end)
end

--------------------------------------------------------------------------------
-- Browse tree
--------------------------------------------------------------------------------

function Now()
  return os.time()
end

function ResetBrowseCache()
  dbg('Resetting browse cache')
  Browse.tabIds = {}
  Browse.children = {}
  Browse.files = {}
end

function CacheFresh(entry)
  return entry and (Now() - entry.ts) < Config.cacheTtl
end

-- TTL alone only marks entries stale; it never reclaims them. Drop the oldest
-- once the table outgrows its ceiling.
function PruneCache(cache)
  local count = 0
  for _ in pairs(cache) do count = count + 1 end
  if count <= MAX_CACHED_NODES then return end

  local oldestKey, oldestTs
  for key, entry in pairs(cache) do
    if not oldestTs or entry.ts < oldestTs then
      oldestKey, oldestTs = key, entry.ts
    end
  end
  if oldestKey then cache[oldestKey] = nil end
end

-- Fetches the child nodes of a browse node. An empty Item list means the node
-- is a leaf and its contents should be read with Browse/Files instead.
function Browse.GetChildren(nodeId, callback)
  local cached = Browse.children[nodeId]
  if CacheFresh(cached) then
    callback(nil, cached.items)
    return
  end

  MCWS.Request('Browse/Children', { ID = nodeId, ErrorOnMissing = 0 }, 'items',
    function(err, data)
      if err or not data then
        callback(err or 'No response', nil)
        return
      end

      local items = {}
      for _, item in ipairs(data.items) do
        if item.name and item.value ~= '' then
          table.insert(items, {
            id = item.value,
            name = item.name,
            nodeType = item.attrs.Type,
          })
        end
      end

      Browse.children[nodeId] = { ts = Now(), items = items }
      PruneCache(Browse.children)
      callback(nil, items)
    end)
end

function Browse.GetFiles(nodeId, callback)
  local cached = Browse.files[nodeId]
  if CacheFresh(cached) then
    callback(nil, cached.items)
    return
  end

  MCWS.Request('Browse/Files', {
    ID = nodeId,
    Action = 'JSON',
    Fields = TRACK_FIELDS,
    NoLocalFilenames = 1,
  }, 'json', function(err, data)
    if err or type(data) ~= 'table' then
      callback(err or 'No response', nil)
      return
    end

    local items = {}
    for _, f in ipairs(data) do
      table.insert(items, {
        key = tostring(f.Key or ''),
        name = f.Name or 'Unknown',
        artist = f.Artist or f['Album Artist'] or '',
        album = f.Album or '',
        trackNumber = tonumber(f['Track #']) or 0,
        duration = tonumber(f.Duration) or 0,
      })
    end

    Browse.files[nodeId] = { ts = Now(), items = items }
    PruneCache(Browse.files)
    callback(nil, items)
  end)
end

-- Walks a list of node names from the browse root, resolving each to the ID MC
-- has currently allocated for it. Used for the tabs and for the Play Path
-- programming command, which both address nodes by name rather than by ID.
function Browse.ResolvePath(path, callback)
  if not path or #path == 0 then
    callback('Empty browse path', nil)
    return
  end

  local function step(index, parentId)
    Browse.GetChildren(parentId, function(err, items)
      if err or not items then
        callback(err or 'Browse failed', nil)
        return
      end

      local wanted = path[index]
      for _, item in ipairs(items) do
        if item.name == wanted then
          if index == #path then
            callback(nil, item.id)
          else
            step(index + 1, item.id)
          end
          return
        end
      end

      callback('Browse node not found: ' .. tostring(wanted), nil)
    end)
  end

  step(1, '-1')
end

function Browse.ResolveTab(tabId, callback)
  local cachedId = Browse.tabIds[tabId]
  if cachedId then
    callback(nil, cachedId)
    return
  end

  local path = TAB_PATHS[tabId]
  if not path then
    callback('Unknown tab: ' .. tostring(tabId), nil)
    return
  end

  Browse.ResolvePath(path, function(err, nodeId)
    if not err then Browse.tabIds[tabId] = nodeId end
    callback(err, nodeId)
  end)
end

-- Splits "Audio\\Artist\\Example Artist" into its node names. Both separators
-- are accepted because Media Center displays paths with backslashes while most
-- people type forward slashes.
function SplitBrowsePath(text)
  local names = {}
  for raw in tostring(text or ''):gmatch('[^\\/]+') do
    local part = raw:match('^%s*(.-)%s*$')
    if part ~= '' then table.insert(names, part) end
  end
  return names
end

--------------------------------------------------------------------------------
-- Transport
--------------------------------------------------------------------------------

-- Transport reaches the driver by three different routes: Navigator dashboard
-- taps (with a NAVID), the room's physical remote buttons (no NAVID, just
-- ROOM_ID/DEVICE_ID), and the media_player proxy in Watch mode. They all run
-- the same implementations rather than three near-copies.
Transport = {
  PLAY = function()
    MCWS.Command('Playback/PlayPause', MCWS.ZoneParams(), 'PLAY')
    PollSoon()
  end,
  PAUSE = function()
    MCWS.Command('Playback/Pause', MCWS.ZoneParams({ State = 1 }), 'PAUSE')
    PollSoon()
  end,
  STOP = function()
    MCWS.Command('Playback/Stop', MCWS.ZoneParams(), 'STOP')
    PollSoon()
  end,
  SKIP_FWD = function()
    MCWS.Command('Playback/Next', MCWS.ZoneParams(), 'SKIP_FWD')
    PollSoon()
  end,
  SKIP_REV = function()
    MCWS.Command('Playback/Previous', MCWS.ZoneParams(), 'SKIP_REV')
    PollSoon()
  end,
  SCAN_FWD = function()
    Seek(1)
    PollSoon()
  end,
  SCAN_REV = function()
    Seek(-1)
    PollSoon()
  end,
}

Transport.PLAY_PAUSE = Transport.PLAY
Transport.PLAYPAUSE = Transport.PLAY

--------------------------------------------------------------------------------
-- ReceivedFromProxy
--------------------------------------------------------------------------------

function ReceivedFromProxy(idBinding, strCommand, tParams)
  strCommand = strCommand or ''
  tParams = tParams or {}

  local args = {}
  if tParams.ARGS then
    local parsedArgs = C4:ParseXml(tParams.ARGS)
    if parsedArgs and parsedArgs.ChildNodes then
      for _, v in pairs(parsedArgs.ChildNodes) do
        if v.Attributes and v.Attributes.name then
          args[v.Attributes.name] = v.Value
        end
      end
    end
    tParams.ARGS = nil
  end

  if Config.debugMode then
    local output = {'ReceivedFromProxy [' .. idBinding .. ']: ' .. strCommand}
    for k, v in pairs(tParams) do
      table.insert(output, '  ' .. tostring(k) .. ' = ' .. tostring(v))
    end
    for k, v in pairs(args) do
      table.insert(output, '  args.' .. tostring(k) .. ' = ' .. tostring(v))
    end
    dbg(table.concat(output, '\n'))
  end

  if idBinding == SWITCH_BINDING then
    local handler = SWITCH[string.gsub(strCommand, '%s+', '_')]
    if handler then
      handler(tParams)
    else
      dbg('Virtual switcher: ignoring ' .. strCommand)
    end
    return
  end

  -- Watch mode: the room drives the media_player proxy directly, with no
  -- navigator session involved.
  if idBinding == PLAYER_BINDING then
    local handler = PLAYER[string.gsub(strCommand, '%s+', '_')]
    if handler then
      handler(tParams, args)
    else
      ReportUnhandled(strCommand .. ' (media_player)')
    end
    return
  end

  local navId = tParams.NAVID
  local nav = Navigators[navId]

  if strCommand == 'DESTROY_NAVIGATOR' or strCommand == 'DESTROY_NAV' then
    if nav then
      if nav.DestroyNavTimer then
        nav.DestroyNavTimer = nav.DestroyNavTimer:Cancel()
      end
      nav.DestroyNavTimer = C4:SetTimer(5000, function(timer)
        Navigators[navId] = nil
        UpdatePollRate()
      end)
    end
    return
  end

  if not navId and RFP then
    local cmd = string.gsub(strCommand, '%s+', '_')
    if RFP[cmd] then
      RFP[cmd](tParams, args, idBinding)
    else
      ReportUnhandled(cmd .. ' (room, binding ' .. tostring(idBinding) .. ')')
    end
    return
  end

  if navId and not nav then
    nav = Navigator:new(navId)
    Navigators[navId] = nav
    UpdatePollRate()
  end

  if nav then
    if nav.DestroyNavTimer then
      nav.DestroyNavTimer = nav.DestroyNavTimer:Cancel()
    end
    nav.DestroyNavTimer = C4:SetTimer(1000 * 60 * 60 * 3, function(timer)
      Navigators[navId] = nil
      UpdatePollRate()
    end)

    nav.roomId = tonumber(tParams.ROOMID) or 0
    local seq = tParams.SEQ

    local handler = nav[strCommand]
    if handler then
      local success, ret = pcall(handler, nav, idBinding, seq, args)
      if success then
        if ret then
          DataReceived(idBinding, navId, seq, ret)
        end
      else
        dbg('Handler error: ' .. tostring(ret))
        DataReceivedError(idBinding, navId, seq, tostring(ret))
      end
    elseif strCommand == 'DEVICE_CMD' then
      -- DEVICE_CMD is a wrapper sent by Composer Pro that duplicates commands
      -- already dispatched directly. Ignore it to avoid double-processing.
      dbg('Ignoring DEVICE_CMD wrapper')
    else
      ReportUnhandled(strCommand)
    end
  end
end

-- The room's physical transport buttons arrive on the media_service binding
-- with no NAVID -- only ROOM_ID and DEVICE_ID -- so they land here rather than
-- on a Navigator session. Confirmed on hardware: this includes SCAN_FWD and
-- SCAN_REV from the remote's << and >> keys, which appear nowhere in the MSP
-- documentation.
for command, handler in pairs(Transport) do
  RFP[command] = function(tParams, args, idBinding)
    handler()
  end
  -- Buttons report press and release as a pair (PAUSE then END_PAUSE with a
  -- DURATION). The press already acted, so the release only needs to stop any
  -- repeat a held key started.
  RFP['END_' .. command] = function(tParams, args, idBinding)
    StopScan()
  end
end

-- Logs each unrecognised proxy command once, at normal log level rather than
-- debug. The MSP command set is documented but not exhaustive, so this is how a
-- hardware test reveals what the remote actually sends -- particularly the <<
-- and >> keys, which have no documented media_service equivalent.
function ReportUnhandled(strCommand)
  if UnhandledCommands[strCommand] then return end
  UnhandledCommands[strCommand] = true
  log('Unhandled proxy command: ' .. tostring(strCommand) ..
      ' (please report -- this may be a remote key we can map)')
end

--------------------------------------------------------------------------------
-- RFP handlers (non-navigator)
--------------------------------------------------------------------------------

-- Listen mode: the music service was selected as the room's source. The
-- projector is generally off in this case, so if Media Center was left sitting
-- in Theater View, drop it back to the standard view.
--
-- This fires on selection only, never continuously from the poll loop: if
-- someone deliberately switches Media Center into Theater View at the machine
-- while music is playing, the driver must not fight them for it.
-- Pushes the full Now Playing state. Polling only re-sends media info when the
-- track changes, so without this a navigator that opens while something is
-- already playing gets no artwork and no progress bar.
function PushNowPlaying()
  UpdateMediaInfo()
  UpdateProgress()
  UpdateDashboard()
  UpdateQueue()
end

function RFP.DEVICE_SELECTED(tParams, args, idBinding)
  dbg('Listen mode selected')
  DeviceSelected = true
  UpdatePollRate()

  if Config.leaveTheaterOnListen and InTheaterView() then
    LeaveTheaterView()
  end

  PushNowPlaying()
  PollNow()
end

function RFP.DEVICE_DESELECTED(tParams, args, idBinding)
  dbg('DEVICE_DESELECTED')
  DeviceSelected = false
  UpdatePollRate()
  PushNowPlaying()
end

-- Navigator asks for these by name with no NAVID, so they belong on RFP rather
-- than on a Navigator session. The dashboard request is what drives the progress
-- bar; leaving it unanswered is why no bar appeared. Both spellings are wired
-- because the documentation and the reference driver disagree on the capital B.
function RFP.GetDashboard(tParams, args, idBinding)
  UpdateDashboard()
  UpdateProgress()
end
RFP.GetDashBoard = RFP.GetDashboard

function RFP.GetQueue(tParams, args, idBinding)
  UpdateQueue()
  UpdateDashboard()
  UpdateProgress()
end

--------------------------------------------------------------------------------
-- Virtual switcher (binding 5003)
--
-- Plumbing, not a source: it exists so the music service and Theater View share
-- one HDMI to the AVR. It has a single input, so switching is a formality, but
-- the proxy still has to acknowledge input changes or the room's AV path never
-- completes. It is also hidden from every room, the way the shipping Kodi driver
-- hides its own virtual amp.
--------------------------------------------------------------------------------

SWITCH = SWITCH or {}

SWITCH.ON = function() dbg('Virtual switcher ON') end
SWITCH.OFF = function() dbg('Virtual switcher OFF') end

SWITCH.SET_INPUT = function(tParams)
  local input = tParams and tParams.INPUT
  local output = tParams and tParams.OUTPUT
  dbg('Virtual switcher input ' .. tostring(input) .. ' -> output ' .. tostring(output))
  C4:SendToProxy(SWITCH_BINDING, 'INPUT_CHANGED', { INPUT = input })
  C4:SendToProxy(SWITCH_BINDING, 'INPUT_OUTPUT_CHANGED', { INPUT = input, OUTPUT = output })
end

-- Keeps the virtual amp out of every room's source list. Rooms can appear after
-- the driver starts, so this runs on system events rather than once at init.
function HideSwitcherInAllRooms()
  local bound = C4:GetBoundConsumerDevices(C4:GetDeviceID(), SWITCH_BINDING)
  if type(bound) ~= 'table' then return end

  local deviceId = next(bound)
  if not deviceId then return end

  for roomId, _ in pairs(C4:GetDevicesByC4iName('roomdevice.c4i') or {}) do
    C4:SendToDevice(roomId, 'SET_DEVICE_HIDDEN_STATE', {
      PROXY_GROUP = 'ALL',
      DEVICE_ID = deviceId,
      IS_HIDDEN = true,
    })
  end
end

-- System events fire constantly, and this walks every room in the project, so
-- it is rate limited. Rooms can still appear after startup, hence not doing it
-- once and never again.
function OnSystemEvent(data)
  local now = os.time()
  if (now - LastSwitcherHide) < SWITCHER_HIDE_INTERVAL_S then return end
  LastSwitcherHide = now
  pcall(HideSwitcherInAllRooms)
end

--------------------------------------------------------------------------------
-- Watch mode: media_player proxy (binding 5002)
--
-- Forwards the room remote's keys into Media Center's own UI via Control/Key.
-- Note that Control/Key answers Status="OK" whether or not the keystroke landed,
-- so its response is never treated as confirmation.
--------------------------------------------------------------------------------

function SendKeys(keys)
  if type(keys) == 'table' then
    keys = table.concat(keys, ';')
  end

  MCWS.Command('Control/Key', {
    Key = keys,
    Focus = Config.takeFocus and 1 or 0,
  }, 'Key ' .. tostring(keys))
end

function InTheaterView()
  return PlaybackState.uiMode == UI_MODE_THEATER
end

-- Switching sources fires a deselect on one binding and a select on the other,
-- and the polled UI mode is still stale in between, so the same view command can
-- be issued twice in quick succession. Suppress the repeat.
function ViewCommandRepeated(action)
  local now = os.time()
  if LastViewCommand.action == action and (now - LastViewCommand.at) < VIEW_DEBOUNCE_S then
    dbg('Skipping repeated view command: ' .. action)
    return true
  end
  LastViewCommand.action = action
  LastViewCommand.at = now
  return false
end

function ShowTheaterView(mode)
  mode = mode or THEATER_MODE_TOGGLE
  if ViewCommandRepeated('theater:' .. mode) then return end

  MCWS.Command('Control/MCC', {
    Command = MCC_THEATER_VIEW,
    Parameter = mode,
    Block = 1,
  }, 'Theater View mode ' .. tostring(mode))
  PollSoon()
end

function LeaveTheaterView()
  if ViewCommandRepeated('standard') then return end

  -- MCC 22001 Parameter=0 enters Theater View but does not toggle back out, so
  -- returning to the standard view needs a different command.
  MCWS.Command('Control/MCC', {
    Command = MCC_SHOW_STANDARD_VIEW,
    Parameter = 0,
    Block = 1,
  }, 'Leave Theater View')
  PollSoon()
end

function StartKeyRepeat(key)
  StopKeyRepeat()
  SendKeys(key)
  Timer.KeyRepeat = C4:SetTimer(HOLD_REPEAT_MS, function(timer)
    SendKeys(key)
  end, true)
end

function StopKeyRepeat()
  if Timer.KeyRepeat then
    Timer.KeyRepeat = Timer.KeyRepeat:Cancel()
  end
end

-- Builds PLAYER handlers for every mapped key, including the START_/STOP_ pairs
-- the remote sends when a directional key is held.
for command, key in pairs(KEY_MAP) do
  PLAYER[command] = function(tParams, args)
    SendKeys(key)
  end
  PLAYER['START_' .. command] = function(tParams, args)
    StartKeyRepeat(key)
  end
  PLAYER['STOP_' .. command] = function(tParams, args)
    StopKeyRepeat()
  end
end

-- Transport goes to MCWS rather than through the UI, so it works whether or not
-- Theater View happens to be on screen.
for command, handler in pairs(Transport) do
  PLAYER[command] = function(tParams, args) handler() end
  PLAYER['END_' .. command] = function(tParams, args) StopScan() end
end

PLAYER.START_SCAN_FWD = function() StartScan(1) end
PLAYER.START_SCAN_REV = function() StartScan(-1) end
PLAYER.STOP_SCAN_FWD = function() StopScan() end
PLAYER.STOP_SCAN_REV = function() StopScan() end

-- The button bar maps HOME to GUIDE and MENU to MENU. Both jump within Theater
-- View rather than sending a raw key, which is more predictable than relying on
-- wherever the cursor happens to be.
PLAYER.GUIDE = function() ShowTheaterView(THEATER_MODE_HOME) end
PLAYER.MENU = function() ShowTheaterView(THEATER_MODE_AUDIO) end
PLAYER.RECALL = function() ShowTheaterView(THEATER_MODE_PLAYING_NOW) end

-- Volume is the AVR's job by default; MC's own volume is only touched when the
-- installer opts in.
local function volumeCommand(path, params, label)
  return function()
    if not Config.handleVolume then
      dbg('Ignoring ' .. label .. ' (Handle Volume is Off)')
      return
    end
    MCWS.Command(path, MCWS.ZoneParams(params), label)
  end
end

PLAYER.VOL_UP = volumeCommand('Playback/Volume', { Level = 0.05, Relative = 1 }, 'VOL_UP')
PLAYER.VOL_DOWN = volumeCommand('Playback/Volume', { Level = -0.05, Relative = 1 }, 'VOL_DOWN')
PLAYER.PULSE_VOL_UP = PLAYER.VOL_UP
PLAYER.PULSE_VOL_DOWN = PLAYER.VOL_DOWN

-- Playback/Mute takes Set=1 or Set=0 only; there is no toggle value, so the
-- toggle is resolved against the mute state read back from Playback/Info.
PLAYER.MUTE_ON = volumeCommand('Playback/Mute', { Set = 1 }, 'MUTE_ON')
PLAYER.MUTE_OFF = volumeCommand('Playback/Mute', { Set = 0 }, 'MUTE_OFF')
PLAYER.MUTE_TOGGLE = function()
  if not Config.handleVolume then
    dbg('Ignoring MUTE_TOGGLE (Handle Volume is Off)')
    return
  end
  MCWS.Command('Playback/Mute', MCWS.ZoneParams({
    Set = PlaybackState.muted and 0 or 1,
  }), 'MUTE_TOGGLE')
  PollSoon()
end

PLAYER.ON = function()
  ShowTheaterView(THEATER_MODE_TOGGLE)
end

PLAYER.OFF = function()
  if Config.leaveTheaterOnDeselect then
    LeaveTheaterView()
  end
end

PLAYER.DEVICE_SELECTED = function()
  dbg('Watch mode selected')
  PlayerSelected = true
  UpdatePollRate()
  if Config.enterTheaterOnSelect and not InTheaterView() then
    ShowTheaterView(THEATER_MODE_TOGGLE)
  end
  PollNow()
end

PLAYER.DEVICE_DESELECTED = function()
  dbg('Watch mode deselected')
  PlayerSelected = false
  StopKeyRepeat()
  StopScan()
  UpdatePollRate()
  if Config.leaveTheaterOnDeselect and InTheaterView() then
    LeaveTheaterView()
  end
end

--------------------------------------------------------------------------------
-- Navigator object
--------------------------------------------------------------------------------

function Navigator:new(navId)
  local n = { navId = navId, roomId = 0, DestroyNavTimer = nil }
  setmetatable(n, self)
  self.__index = self
  return n
end

--------------------------------------------------------------------------------
-- Browse handler
--------------------------------------------------------------------------------

function Navigator:Browse(idBinding, seq, args)
  local navId = self.navId
  local nodeId = args.id

  -- Root of a tab: resolve the tab's path to a node, then list it.
  if nodeId == nil or nodeId == '' or args.itemType == nil then
    local tabId = args.tabId
    if (not tabId) or tabId == '' then
      tabId = SCREEN_TABS[args.screenId or '']
    end

    Browse.ResolveTab(tabId, function(err, resolvedId)
      if err or not resolvedId then
        dbg('Tab resolve failed: ' .. tostring(err))
        DataReceived(idBinding, navId, seq, MakeList({}))
        return
      end
      self:ListNode(idBinding, seq, resolvedId, { isTabRoot = true })
    end)
    return
  end

  self:ListNode(idBinding, seq, nodeId)
end

-- The Play All / Shuffle All rows. Browse/Files returns everything *beneath* a
-- node, so these work just as well on a branch (an artist, a genre) as on an
-- album, which is where they used to be the only option.
function ActionRows(nodeId)
  return {
    { title = 'Play', isHeader = 'true', image_list = {} },
    {
      id = nodeId,
      itemType = 'nodeAction',
      title = 'Play All',
      default_action = 'PlayNode',
      image_list = ImageListForAsset('action_play'),
    },
    {
      id = nodeId,
      itemType = 'nodeAction',
      title = 'Shuffle All',
      default_action = 'ShuffleNode',
      image_list = ImageListForAsset('action_shuffle'),
    },
  }
end

-- Lists a browse node: child nodes if it has any, otherwise its tracks.
-- opts.isTabRoot suppresses the Play All rows, because at the top of a tab they
-- would mean the whole library rather than the thing just selected.
function Navigator:ListNode(idBinding, seq, nodeId, opts)
  local navId = self.navId

  Browse.GetChildren(nodeId, function(err, children)
    if err then
      dbg('Browse/Children failed for ' .. tostring(nodeId) .. ': ' .. tostring(err))
      ResetBrowseCache()
      DataReceived(idBinding, navId, seq, MakeList({}))
      return
    end

    if children and #children > 0 then
      local items = {}

      if not (opts and opts.isTabRoot) then
        for _, row in ipairs(ActionRows(nodeId)) do
          table.insert(items, row)
        end
      end

      for _, child in ipairs(children) do
        table.insert(items, {
          id = child.id,
          itemType = 'node',
          title = child.name,
          isLink = 'true',
          default_action = 'SelectItem',
          actions_list = 'PlayNode ShuffleNode PlayNodeNext AddNode',
          image_list = ImageListForNode(child.id),
        })
      end
      DataReceived(idBinding, navId, seq, MakeList(items))
      return
    end

    -- Leaf node: list its files.
    Browse.GetFiles(nodeId, function(fileErr, files)
      if fileErr or not files then
        dbg('Browse/Files failed for ' .. tostring(nodeId) .. ': ' .. tostring(fileErr))
        DataReceived(idBinding, navId, seq, MakeList({}))
        return
      end

      local items = {}

      if #files > 0 then
        -- Headers carry an empty image list rather than none: MakeList fills a
        -- missing one with the driver tile, which is just noise on a divider.
        for _, row in ipairs(ActionRows(nodeId)) do
          table.insert(items, row)
        end
        table.insert(items, { title = 'Tracks', isHeader = 'true', image_list = {} })
      end

      for _, track in ipairs(files) do
        table.insert(items, {
          id = track.key,
          parentId = nodeId,
          itemType = 'track',
          title = track.name,
          subtitle = track.artist,
          duration = FormatTime(track.duration),
          default_action = 'PlayNow',
          actions_list = 'PlayNow PlayNext AddToQueue',
          image_list = ImageListForFile(track.key),
        })
      end

      DataReceived(idBinding, navId, seq, MakeList(items))
    end)
  end)
end

function Navigator:SelectItem(idBinding, seq, args)
  if args.itemType == 'node' then
    return { NextScreen = 'BrowseScreen' }
  end
  return nil
end

--------------------------------------------------------------------------------
-- Playback actions
--------------------------------------------------------------------------------

-- With the projector off, NoUI=1 stops playback from surfacing Media Center's
-- window on a dark screen. With Theater View already up, NoUI=0 lets MC's own
-- display follow what was just started from the navigator.
function NoUIValue()
  return InTheaterView() and 0 or 1
end

-- Every play action is Browse/Files with different flags.
function PlayNode(nodeId, opts)
  opts = opts or {}
  if not nodeId then return end

  local params = MCWS.ZoneParams({
    ID = nodeId,
    Action = 'Play',
    NoUI = NoUIValue(),
  })

  if opts.shuffle then params.Shuffle = 1 end
  if opts.playMode then params.PlayMode = opts.playMode end
  if opts.activeFile then
    params.ActiveFile = opts.activeFile
    if opts.activeFileOnly then params.ActiveFileOnly = 1 end
  end

  MCWS.Command('Browse/Files', params, 'Play node ' .. tostring(nodeId))
end

function Navigator:PlayNode(idBinding, seq, args)
  PlayNode(args.id)
  return ''
end

function Navigator:ShuffleNode(idBinding, seq, args)
  PlayNode(args.id, { shuffle = true })
  return ''
end

function Navigator:PlayNodeNext(idBinding, seq, args)
  PlayNode(args.id, { playMode = 'NextToPlay' })
  return ''
end

function Navigator:AddNode(idBinding, seq, args)
  PlayNode(args.id, { playMode = 'Add' })
  return ''
end

-- Tapping a track loads its whole node and starts at that track, so playback
-- continues through the rest of the album rather than stopping after one file.
function Navigator:PlayNow(idBinding, seq, args)
  if args.parentId and args.id then
    PlayNode(args.parentId, { activeFile = args.id })
  end
  return ''
end

function Navigator:PlayNext(idBinding, seq, args)
  if args.parentId and args.id then
    PlayNode(args.parentId, {
      activeFile = args.id,
      activeFileOnly = true,
      playMode = 'NextToPlay',
    })
  end
  return ''
end

function Navigator:AddToQueue(idBinding, seq, args)
  if args.parentId and args.id then
    PlayNode(args.parentId, {
      activeFile = args.id,
      activeFileOnly = true,
      playMode = 'Add',
    })
  end
  return ''
end

--------------------------------------------------------------------------------
-- Transport
--------------------------------------------------------------------------------


function Navigator:PLAY(idBinding, seq, args)
  Transport.PLAY()
  return ''
end

function Navigator:PAUSE(idBinding, seq, args)
  Transport.PAUSE()
  return ''
end

function Navigator:STOP(idBinding, seq, args)
  Transport.STOP()
  return ''
end

function Navigator:SKIP_FWD(idBinding, seq, args)
  Transport.SKIP_FWD()
  return ''
end

function Navigator:SKIP_REV(idBinding, seq, args)
  Transport.SKIP_REV()
  return ''
end

--------------------------------------------------------------------------------
-- Seeking
--
-- The remote's << and >> keys. These are NOT in the MSP proxy's documented
-- command set (which has no scan or seek command of any kind), so they may
-- never arrive on the media_service binding. They are wired anyway: if the
-- proxy passes them through, seeking works; if not, this costs nothing. The
-- media_player proxy added in Phase 3 does deliver them, so the same handlers
-- serve Watch mode.
--------------------------------------------------------------------------------

function Seek(direction)
  MCWS.Command('Playback/Position', MCWS.ZoneParams({
    Position = SEEK_STEP_MS,
    Relative = direction,
    Mode = 'ms',
  }), 'Seek ' .. (direction > 0 and 'forward' or 'back'))
end

function StartScan(direction)
  StopScan()
  Seek(direction)
  Timer.Scan = C4:SetTimer(SCAN_REPEAT_MS, function(timer)
    Seek(direction)
  end, true)
end

function StopScan()
  if Timer.Scan then
    Timer.Scan = Timer.Scan:Cancel()
  end
  PollSoon()
end

function Navigator:SCAN_FWD(idBinding, seq, args)
  Seek(1)
  PollSoon()
  return ''
end

function Navigator:SCAN_REV(idBinding, seq, args)
  Seek(-1)
  PollSoon()
  return ''
end

function Navigator:START_SCAN_FWD(idBinding, seq, args)
  StartScan(1)
  return ''
end

function Navigator:START_SCAN_REV(idBinding, seq, args)
  StartScan(-1)
  return ''
end

function Navigator:STOP_SCAN_FWD(idBinding, seq, args)
  StopScan()
  return ''
end

function Navigator:STOP_SCAN_REV(idBinding, seq, args)
  StopScan()
  return ''
end

--------------------------------------------------------------------------------

function Navigator:ToggleShuffle(idBinding, seq, args)
  -- Reshuffle/Off are the documented Mode values; state is re-read on the next
  -- poll rather than assumed here.
  local mode = PlaybackState.shuffleMode and 'Off' or 'Reshuffle'
  MCWS.Command('Playback/Shuffle', MCWS.ZoneParams({ Mode = mode }), 'Shuffle ' .. mode)
  PollSoon()
  return ''
end

function Navigator:ToggleRepeat(idBinding, seq, args)
  local mode = PlaybackState.repeatMode and 'Off' or 'Playlist'
  MCWS.Command('Playback/Repeat', MCWS.ZoneParams({ Mode = mode }), 'Repeat ' .. mode)
  PollSoon()
  return ''
end

-- Jumping within Playing Now, from the queue list on the Now Playing screen.
-- Browse/Files would rebuild the queue from scratch; PlayByIndex moves within
-- the queue that is already loaded.
function Navigator:PlayQueueItem(idBinding, seq, args)
  local index = tonumber(args.queueIndex)
  if not index then return '' end

  MCWS.Command('Playback/PlayByIndex', MCWS.ZoneParams({
    Index = index,
    NoUI = NoUIValue(),
  }), 'Play queue index ' .. index)
  PollSoon()
  return ''
end

function Navigator:GetDashboard(idBinding, seq, args)
  UpdateDashboard(self.navId, self.roomId)
  return ''
end

function Navigator:GetQueue(idBinding, seq, args)
  UpdateQueue(self.navId, self.roomId)
  return ''
end

--------------------------------------------------------------------------------
-- Polling
--------------------------------------------------------------------------------

function ActiveSessionCount()
  local count = 0
  for _ in pairs(Navigators) do count = count + 1 end
  if DeviceSelected then count = count + 1 end
  if PlayerSelected then count = count + 1 end
  return count
end

-- Idle polling is slowed rather than stopped, so Now Playing is roughly current
-- the moment a navigator opens without hammering MC when nothing is watching.
function CurrentPollInterval()
  if ActiveSessionCount() > 0 then
    return Config.pollInterval * 1000
  end
  -- Also poll at full rate while something is playing, even with nothing
  -- selected anywhere. Programming reacts to Track Changed and to the playback
  -- variables, and those come from this loop; at the idle rate a track change
  -- could be reported up to half a minute late.
  if PlaybackState.state == 'playing' then
    return Config.pollInterval * 1000
  end
  return IDLE_POLL_MS
end

function StartPolling()
  if Timer.Poll then
    Timer.Poll:Cancel()
    Timer.Poll = nil
  end

  Timer.PollRate = CurrentPollInterval()
  Timer.Poll = C4:SetTimer(Timer.PollRate, function(timer)
    PollNow()
  end, true)

  -- Ticks the interpolated progress bar between polls. The MSP proxy documents
  -- ProgressChanged as "should not be sent more frequently than once per
  -- second", so this runs at exactly 1Hz and only while something is playing.
  if Timer.Progress then
    Timer.Progress = Timer.Progress:Cancel()
  end
  Timer.Progress = C4:SetTimer(1000, function(timer)
    if PlaybackState.state == 'playing' and ActiveSessionCount() > 0 then
      UpdateProgress()
    end
  end, true)
end

function UpdatePollRate()
  if Timer.PollRate ~= CurrentPollInterval() then
    StartPolling()
  end
end

-- Nudges a refresh shortly after a command, since MC needs a moment to settle.
function PollSoon()
  if Timer.PollSoon then
    Timer.PollSoon = Timer.PollSoon:Cancel()
  end
  Timer.PollSoon = C4:SetTimer(400, function(timer)
    Timer.PollSoon = nil
    PollNow()
  end)
end

function PollNow()
  if Config.host == '' then return end

  MCWS.Request('Playback/Info', MCWS.ZoneParams(), 'items', function(err, data)
    if err or not data then
      SetConnected(false)
      return
    end
    SetConnected(true)
    ApplyPlaybackInfo(data.map)
  end)

  MCWS.Request('UserInterface/Info', {}, 'items', function(err, data)
    if err or not data then return end
    ApplyUiInfo(data.map)
  end)
end

function ApplyPlaybackInfo(map)
  if not map then return end

  local previous = {
    state = PlaybackState.state,
    fileKey = PlaybackState.fileKey,
  }

  local stateNum = tonumber(map.State) or 0
  local state = 'stopped'
  if stateNum == 1 then state = 'paused'
  elseif stateNum == 2 then state = 'playing'
  elseif stateNum == 3 then state = 'waiting' end

  local trackChanged = (map.FileKey ~= PlaybackState.fileKey) or (state ~= PlaybackState.state)

  PlaybackState.state = state
  PlaybackState.fileKey = map.FileKey
  PlaybackState.name = map.Name
  PlaybackState.artist = map.Artist
  PlaybackState.album = map.Album
  PlaybackState.position = math.floor((tonumber(map.PositionMS) or 0) / 1000)
  PlaybackState.positionSyncedAt = os.time()
  PlaybackState.duration = math.floor((tonumber(map.DurationMS) or 0) / 1000)
  PlaybackState.queuePosition = tonumber(map.PlayingNowPosition) or 0
  PlaybackState.queueCount = tonumber(map.PlayingNowTracks) or 0
  PlaybackState.muted = (map.VolumeDisplay == 'Muted')

  -- PlayingNowChangeCounter moves whenever the queue changes, so the (much
  -- larger) playlist payload is only fetched when it actually differs.
  local counter = map.PlayingNowChangeCounter
  if counter ~= PlaybackState.changeCounter then
    PlaybackState.changeCounter = counter
    RefreshQueue()
  end

  if trackChanged then
    UpdateMediaInfo()
    RefreshPlayModes()
  end

  -- Starting or stopping changes how often this loop needs to run.
  if previous.state ~= PlaybackState.state then
    UpdatePollRate()
  end

  UpdateProgress()
  UpdateDashboard()
  PublishState(previous)
end

function ApplyUiInfo(map)
  if not map then return end

  local mode = tonumber(map.Mode)
  local changed = (mode ~= PlaybackState.uiMode)
  local previousMode = PlaybackState.uiMode

  PlaybackState.uiMode = mode
  PlaybackState.viewName = map.ViewDisplayName or ''
  PlaybackState.selectionName = map.SelectionDisplayName or ''

  if changed then
    dbg('UI mode -> ' .. tostring(mode))
    C4:UpdateProperty('UI Mode', UiModeName(mode))
  end

  PublishUiState(previousMode)
end

function UiModeName(mode)
  if mode == 0 then return 'Standard'
  elseif mode == 1 then return 'Mini'
  elseif mode == 2 then return 'Display'
  elseif mode == 3 then return 'Theater'
  elseif mode == 4 then return 'Cover'
  elseif mode == -1000 then return 'No UI' end
  return 'Unknown'
end

-- Shuffle and repeat are absent from Playback/Info; calling these endpoints
-- without a Mode parameter returns the current setting.
function RefreshPlayModes()
  MCWS.Request('Playback/Shuffle', MCWS.ZoneParams(), 'items', function(err, data)
    if err or not data then return end
    PlaybackState.shuffleMode = (data.map.Mode ~= nil and data.map.Mode ~= 'Off')
  end)

  MCWS.Request('Playback/Repeat', MCWS.ZoneParams(), 'items', function(err, data)
    if err or not data then return end
    PlaybackState.repeatMode = (data.map.Mode ~= nil and data.map.Mode ~= 'Off')
  end)
end

function RefreshQueue()
  MCWS.Request('Playback/Playlist', MCWS.ZoneParams({
    Action = 'JSON',
    Fields = TRACK_FIELDS,
  }), 'json', function(err, data)
    if err or type(data) ~= 'table' then return end

    Queue = {}
    for _, f in ipairs(data) do
      table.insert(Queue, {
        key = tostring(f.Key or ''),
        name = f.Name or 'Unknown',
        artist = f.Artist or '',
        duration = tonumber(f.Duration) or 0,
      })
    end

    dbg('Queue refreshed: ' .. #Queue .. ' tracks')
    UpdateQueue()
  end)
end

--------------------------------------------------------------------------------
-- Programming surface: variables and events
--------------------------------------------------------------------------------

VARIABLES = {
  { 'Connected', false, 'BOOL' },
  { 'Playback State', 'stopped', 'STRING' },
  { 'Playing', false, 'BOOL' },
  { 'Track', '', 'STRING' },
  { 'Artist', '', 'STRING' },
  { 'Album', '', 'STRING' },
  { 'Position', 0, 'NUMBER' },
  { 'Duration', 0, 'NUMBER' },
  { 'Shuffle', false, 'BOOL' },
  { 'Repeat', false, 'BOOL' },
  { 'Theater View', false, 'BOOL' },
  { 'UI Mode', '', 'STRING' },
  { 'Queue Position', 0, 'NUMBER' },
  { 'Queue Count', 0, 'NUMBER' },
}

function SetupVariables()
  -- Clearing the cache matters: the variables are being (re)declared at their
  -- defaults, so the next publish has to write every one of them. Leaving stale
  -- cache entries would suppress those writes and leave Director holding values
  -- that no longer reflect anything.
  VariableCache = {}
  for _, v in ipairs(VARIABLES) do
    C4:AddVariable(v[1], v[2], v[3], true, false)
  end
end

-- Only writes on change. Variable updates propagate to every navigator and can
-- re-trigger programming, so writing unchanged values every poll would be noisy.
function SetVar(name, value)
  if VariableCache[name] == value then return end
  VariableCache[name] = value
  C4:SetVariable(name, value)
end

function FireDriverEvent(name)
  dbg('Event: ' .. name)
  C4:FireEvent(name)
end

-- Mirrors playback and UI state into variables, firing events on the
-- transitions programming is likely to care about.
function PublishState(previous)
  SetVar('Playback State', PlaybackState.state)
  SetVar('Playing', PlaybackState.state == 'playing')
  SetVar('Track', PlaybackState.name or '')
  SetVar('Artist', PlaybackState.artist or '')
  SetVar('Album', PlaybackState.album or '')
  SetVar('Position', EffectivePosition())
  SetVar('Duration', PlaybackState.duration)
  SetVar('Shuffle', PlaybackState.shuffleMode)
  SetVar('Repeat', PlaybackState.repeatMode)
  SetVar('Queue Position', PlaybackState.queuePosition)
  SetVar('Queue Count', PlaybackState.queueCount)

  if previous.state ~= PlaybackState.state then
    if PlaybackState.state == 'playing' then
      FireDriverEvent('Playback Started')
    elseif PlaybackState.state == 'paused' then
      FireDriverEvent('Playback Paused')
    elseif PlaybackState.state == 'stopped' then
      FireDriverEvent('Playback Stopped')
    end
  end

  if previous.fileKey ~= PlaybackState.fileKey and PlaybackState.fileKey then
    FireDriverEvent('Track Changed')
  end
end

function PublishUiState(previousMode)
  local inTheater = InTheaterView()
  SetVar('Theater View', inTheater)
  SetVar('UI Mode', UiModeName(PlaybackState.uiMode))

  if previousMode ~= nil and previousMode ~= PlaybackState.uiMode then
    if inTheater then
      FireDriverEvent('Theater View Entered')
    elseif previousMode == UI_MODE_THEATER then
      FireDriverEvent('Theater View Exited')
    end
  end
end

-- Reachability is inferred from whether polls are answered, so a driver that
-- silently stops talking to Media Center is visible to programming.
function SetConnected(connected)
  if Connected == connected then return end
  Connected = connected
  SetVar('Connected', connected)
  FireDriverEvent(connected and 'Connection Restored' or 'Connection Lost')
end

--------------------------------------------------------------------------------
-- Navigator updates
--------------------------------------------------------------------------------

-- UPDATE_MEDIA_INFO takes LINE1..LINE4, not TITLE/ALBUM/ARTIST/GENRE. The MSP
-- documentation and the shipping Kodi driver agree on this; the "MSP By Numbers"
-- tutorial uses the older field names, which is where the wrong ones came from.
--
-- IMAGEURL must be Base64 encoded. Passing a plain URL leaves the Now Playing
-- screen showing a stock icon rather than the album art.
function UpdateMediaInfo()
  local args = {
    LINE1 = PlaybackState.name or '',
    LINE2 = PlaybackState.artist or '',
    LINE3 = PlaybackState.album or '',
    LINE4 = '',
    IMAGEURL = '',
    MERGE = 'False',
  }

  if PlaybackState.fileKey then
    local url = FileImageUrl(PlaybackState.fileKey, NOW_PLAYING_ART_SIZE)
    if url then
      args.IMAGEURL = C4:Base64Encode(url)
    end
  end

  C4:SendToProxy(MSP_BINDING, 'UPDATE_MEDIA_INFO', args, 'COMMAND', true)
end

-- Position only arrives as fast as the poll interval, which would make the
-- progress bar jump in 2s (or 5s) steps. While playing, advance it locally from
-- the last synced value; every poll re-syncs, so drift cannot accumulate.
function EffectivePosition()
  if PlaybackState.state ~= 'playing' then
    return PlaybackState.position
  end

  local elapsed = os.time() - PlaybackState.positionSyncedAt
  if elapsed < 0 then elapsed = 0 end

  local position = PlaybackState.position + elapsed
  if PlaybackState.duration > 0 and position > PlaybackState.duration then
    position = PlaybackState.duration
  end
  return position
end

function UpdateProgress(navId, roomId)
  local position = EffectivePosition()
  local remaining = PlaybackState.duration - position
  local label = FormatTime(position) .. ' / -' .. FormatTime(remaining)

  SendEvent(MSP_BINDING, navId, roomId, 'ProgressChanged', {
    length = PlaybackState.duration,
    offset = position,
    label = label,
  })
end

function UpdateDashboard(navId, roomId)
  local items

  if PlaybackState.state == 'playing' then
    items = {'Pause', 'Stop', 'SkipRev', 'SkipFwd'}
  elseif PlaybackState.state == 'paused' then
    items = {'Play', 'Stop', 'SkipRev', 'SkipFwd'}
  else
    items = {'Play'}
  end

  SendEvent(MSP_BINDING, navId, roomId, 'DashboardChanged', {
    Items = table.concat(items, ' '),
  })
end

function UpdateQueue(navId, roomId)
  local list = {}

  for index, track in ipairs(Queue) do
    local item = {
      -- Playing Now is indexed from 0; ipairs counts from 1.
      queueIndex = index - 1,
      title = track.name,
      subtitle = track.artist,
      duration = FormatTime(track.duration),
      -- Without a default action, tapping a queue entry does nothing at all.
      default_action = 'PlayQueueItem',
      image_list = ImageListForFile(track.key),
    }
    table.insert(list, XMLTag('item', item))
  end

  -- actionIds is what ties this element to the <ActionIds> declared on the
  -- NowPlaying screen; without it the global Shuffle and Repeat buttons have
  -- nothing to bind to.
  local tags = {
    actionIds = 'Shuffle Repeat',
    can_shuffle = true,
    can_repeat = true,
    shufflemode = PlaybackState.shuffleMode,
    repeatmode = PlaybackState.repeatMode,
  }

  SendEvent(MSP_BINDING, navId, roomId, 'QueueChanged', {
    List = table.concat(list),
    NowPlayingIndex = PlaybackState.queuePosition,
    NowPlaying = XMLTag(tags),
  })
end

--------------------------------------------------------------------------------
-- Artwork
--------------------------------------------------------------------------------

function FileImageUrl(fileKey, size)
  if not fileKey or fileKey == '' then return nil end
  return MCWS.Url('File/GetImage', {
    File = fileKey,
    Width = size,
    Height = size,
    Square = 1,
    Pad = 1,
    Format = 'jpg',
  })
end

function NodeImageUrl(nodeId, size)
  if not nodeId or nodeId == '' then return nil end
  return MCWS.Url('Browse/Image', {
    ID = nodeId,
    Width = size,
    Height = size,
    Square = 1,
    Pad = 1,
    Format = 'jpg',
    UseStackedImages = 1,
  })
end

function BuildImageList(urlFor)
  local imageList = {}
  for _, size in ipairs(IMAGE_SIZES) do
    local url = urlFor(size)
    if url then
      table.insert(imageList,
        '<image_list width="' .. size .. '" height="' .. size .. '">' ..
        XMLEncode(url) .. '</image_list>')
    end
  end
  return imageList
end

function ImageListForFile(fileKey)
  if not fileKey or fileKey == '' then return DefaultImageList() end
  return BuildImageList(function(size) return FileImageUrl(fileKey, size) end)
end

function ImageListForNode(nodeId)
  if not nodeId or nodeId == '' then return DefaultImageList() end
  return BuildImageList(function(size) return NodeImageUrl(nodeId, size) end)
end

-- Icons bundled with the driver, for rows that have no artwork of their own.
function ImageListForAsset(prefix)
  local imageList = {}
  for _, size in ipairs(IMAGE_SIZES) do
    table.insert(imageList,
      '<image_list width="' .. size .. '" height="' .. size .. '">' ..
      'controller://driver/jriver_media_center/icons/' .. prefix .. '_' .. size .. '.png' ..
      '</image_list>')
  end
  return imageList
end

function DefaultImageList()
  local imageList = {}
  for _, size in ipairs(IMAGE_SIZES) do
    table.insert(imageList,
      '<image_list width="' .. size .. '" height="' .. size .. '">' ..
      'controller://driver/jriver_media_center/icons/device_' .. size .. '.png' ..
      '</image_list>')
  end
  return imageList
end

--------------------------------------------------------------------------------
-- Response helpers
--------------------------------------------------------------------------------

function DataReceived(idBinding, navId, seq, args)
  local data = ''

  if type(args) == 'string' then
    data = args
  elseif type(args) == 'boolean' or type(args) == 'number' then
    data = tostring(args)
  elseif type(args) == 'table' then
    data = XMLTag(nil, args, false, false)
  end

  C4:SendToProxy(idBinding, 'DATA_RECEIVED', {
    NAVID = navId,
    SEQ = seq,
    DATA = data,
  })
end

function DataReceivedError(idBinding, navId, seq, msg)
  C4:SendToProxy(idBinding, 'DATA_RECEIVED', {
    NAVID = navId,
    SEQ = seq,
    DATA = '',
    ERROR = msg,
  })
end

function SendEvent(idBinding, navId, roomId, name, args)
  local data = ''

  if type(args) == 'string' then
    data = args
  elseif type(args) == 'boolean' or type(args) == 'number' then
    data = tostring(args)
  elseif type(args) == 'table' then
    data = XMLTag(nil, args, false, false)
  end

  -- The shipping Kodi driver targets a room with ROOMID and clears NAVID; the
  -- tutorial sample uses ROOMS, which appears nowhere else. With neither set the
  -- event broadcasts to every navigator, which is what the poll loop wants.
  local tParams = {
    NAVID = navId,
    NAME = name,
    EVTARGS = data,
  }

  if roomId then
    tParams.NAVID = nil
    tParams.ROOMID = tostring(roomId)
  end

  C4:SendToProxy(idBinding, 'SEND_EVENT', tParams, 'COMMAND')
end

--------------------------------------------------------------------------------
-- List / XML helpers
--------------------------------------------------------------------------------

function MakeList(items, collection, options)
  if collection then
    collection = XMLTag(collection)
  end

  local list = {}
  for _, item in ipairs(items) do
    if not (options and options.suppressItemImages) then
      item.image_list = item.image_list or DefaultImageList()
    end
    table.insert(list, XMLTag('item', item))
  end

  return { Collection = collection, List = table.concat(list) }
end

function XMLEncode(s)
  if s == nil then return '' end
  s = tostring(s)
  s = string.gsub(s, '&', '&amp;')
  s = string.gsub(s, '"', '&quot;')
  s = string.gsub(s, '<', '&lt;')
  s = string.gsub(s, '>', '&gt;')
  s = string.gsub(s, "'", '&apos;')
  return s
end

function XMLTag(strName, tParams, tagSubTables, xmlEncodeElements)
  local retXML = {}

  if type(strName) == 'table' and tParams == nil then
    tParams = strName
    strName = nil
  end

  if strName then
    table.insert(retXML, '<')
    table.insert(retXML, tostring(strName))
    table.insert(retXML, '>')
  end

  if type(tParams) == 'table' then
    for k, v in pairs(tParams) do
      if v == nil then v = '' end
      if type(v) == 'table' then
        if k == 'image_list' then
          for _, image in pairs(v) do
            table.insert(retXML, image)
          end
        elseif tagSubTables == true then
          table.insert(retXML, XMLTag(k, v))
        end
      else
        table.insert(retXML, '<')
        table.insert(retXML, tostring(k))
        table.insert(retXML, '>')
        if xmlEncodeElements ~= false then
          table.insert(retXML, XMLEncode(tostring(v)))
        else
          table.insert(retXML, tostring(v))
        end
        table.insert(retXML, '</')
        table.insert(retXML, string.match(tostring(k), '^(%S+)'))
        table.insert(retXML, '>')
      end
    end
  elseif tParams then
    if xmlEncodeElements ~= false then
      table.insert(retXML, XMLEncode(tostring(tParams)))
    else
      table.insert(retXML, tostring(tParams))
    end
  end

  if strName then
    table.insert(retXML, '</')
    table.insert(retXML, string.match(tostring(strName), '^(%S+)'))
    table.insert(retXML, '>')
  end

  return table.concat(retXML)
end

function FormatTime(seconds)
  seconds = tonumber(seconds)
  if not seconds or seconds < 0 then return '0:00' end
  seconds = math.floor(seconds)

  local hours = math.floor(seconds / 3600)
  local mins = math.floor((seconds % 3600) / 60)
  local secs = seconds % 60

  if hours > 0 then
    return string.format('%d:%02d:%02d', hours, mins, secs)
  end
  return string.format('%d:%02d', mins, secs)
end

--------------------------------------------------------------------------------
-- Timers
--------------------------------------------------------------------------------

function KillAllTimers()
  for name, timer in pairs(Timer) do
    if type(timer) == 'userdata' then
      timer:Cancel()
    end
    Timer[name] = nil
  end
end

--------------------------------------------------------------------------------
-- Composer actions
--------------------------------------------------------------------------------

-- Plays whatever sits under a browse path, e.g. "Audio\\Artist\\Example Artist".
function PlayBrowsePath(path, opts)
  local names = SplitBrowsePath(path)
  if #names == 0 then
    log('Play Path: no path given')
    return
  end

  Browse.ResolvePath(names, function(err, nodeId)
    if err or not nodeId then
      log('Play Path failed for "' .. tostring(path) .. '": ' .. tostring(err))
      return
    end
    PlayNode(nodeId, opts)
  end)
end

-- Playlists are addressed by name rather than by the numeric ID Media Center
-- assigns them, because the name is what a person writing programming knows.
function PlayPlaylistByName(name, shuffle)
  if not name or name == '' then
    log('Play Playlist: no name given')
    return
  end
  PlayBrowsePath('Playlists\\' .. name, { shuffle = shuffle })
end

-- These act on Media Center over MCWS regardless of which proxy is selected, or
-- whether anything is selected at all. ExecuteCommand is not proxy-scoped -- it
-- is not even told which binding the programming came from -- so where Composer
-- files them in its device tree does not affect what they do. The JRiver prefix
-- distinguishes them from the transport the proxies expose separately, which
-- does depend on the room's current selection.
PROGRAMMING = {
  ['JRiver Play'] = function() Transport.PLAY() end,
  ['JRiver Pause'] = function() Transport.PAUSE() end,
  ['JRiver Stop'] = function() Transport.STOP() end,
  ['JRiver Next Track'] = function() Transport.SKIP_FWD() end,
  ['JRiver Previous Track'] = function() Transport.SKIP_REV() end,

  ['Play Path'] = function(p) PlayBrowsePath(p['Browse Path']) end,
  ['Shuffle Path'] = function(p) PlayBrowsePath(p['Browse Path'], { shuffle = true }) end,
  ['Play Playlist'] = function(p)
    PlayPlaylistByName(p['Playlist Name'], p['Shuffle'] == 'Yes')
  end,

  ['Set Shuffle'] = function(p)
    MCWS.Command('Playback/Shuffle',
      MCWS.ZoneParams({ Mode = (p['Mode'] == 'On') and 'Reshuffle' or 'Off' }), 'Set Shuffle')
    PollSoon()
  end,
  ['Set Repeat'] = function(p)
    MCWS.Command('Playback/Repeat',
      MCWS.ZoneParams({ Mode = p['Mode'] or 'Off' }), 'Set Repeat')
    PollSoon()
  end,
  ['Seek'] = function(p)
    local seconds = tonumber(p['Seconds']) or 0
    MCWS.Command('Playback/Position',
      MCWS.ZoneParams({ Position = math.floor(seconds * 1000), Mode = 'ms' }), 'Seek')
    PollSoon()
  end,

  ['Enter Theater View'] = function(p)
    local modes = {
      ['Toggle'] = THEATER_MODE_TOGGLE,
      ['Home'] = THEATER_MODE_HOME,
      ['Playing Now'] = THEATER_MODE_PLAYING_NOW,
      ['Audio'] = THEATER_MODE_AUDIO,
    }
    ShowTheaterView(modes[p['Section']] or THEATER_MODE_AUDIO)
  end,
  ['Leave Theater View'] = function() LeaveTheaterView() end,
  ['Send Key'] = function(p) SendKeys(p['Keys']) end,
  ['Send MCC'] = function(p)
    MCWS.Command('Control/MCC', {
      Command = tonumber(p['Command']) or 0,
      Parameter = tonumber(p['Parameter']) or 0,
      Block = 1,
    }, 'MCC ' .. tostring(p['Command']))
    PollSoon()
  end,
}

function ExecuteCommand(strCommand, tParams)
  dbg('ExecuteCommand: ' .. strCommand)

  local programming = PROGRAMMING[strCommand]
  if programming then
    programming(tParams or {})
    return
  end

  if strCommand ~= 'LUA_ACTION' then
    ReportUnhandled(strCommand .. ' (programming)')
    return
  end

  local action = tParams.ACTION

  if action == 'RefreshCache' then
    ResetBrowseCache()
    MCWS.Command('Browse/Reset', {}, 'Browse/Reset')
    log('Browse cache cleared')

  elseif action == 'TestConnection' then
    MCWS.Request('Alive', {}, 'items', function(err, data)
      if err or not data then
        log('Connection test failed: ' .. tostring(err))
        return
      end
      log(string.format('Connected to %s (%s %s, %s)',
        tostring(data.map.FriendlyName),
        tostring(data.map.ProgramName),
        tostring(data.map.ProgramVersion),
        tostring(data.map.Platform)))
    end)

    MCWS.Request('Playback/Zones', {}, 'items', function(err, data)
      if err or not data then return end
      local count = tonumber(data.map.NumberZones) or 0
      local names = {}
      for i = 0, count - 1 do
        table.insert(names, string.format('%s (ID %s)',
          tostring(data.map['ZoneName' .. i]), tostring(data.map['ZoneID' .. i])))
      end
      log('Zones: ' .. table.concat(names, ', '))
    end)
  end
end

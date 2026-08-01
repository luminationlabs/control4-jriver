-- Offline test harness for driver.lua.
--
-- Loads the driver with the Control4 API stubbed out and drives it with MCWS
-- payloads captured verbatim from a live Media Center 35.0.74 server, so the
-- browse tree walk, response parsing and MCWS request shapes can be checked
-- without a controller or a running MC.
--
--   lua test-driver.lua        (exits non-zero on failure)

-- Resolve paths relative to this script so the harness runs from anywhere.
local HERE = (arg and arg[0] or ''):match('^(.*)[/\\][^/\\]*$') or '.'
package.path = HERE .. '/?.lua;' .. package.path

local pending = {}       -- ticket -> {parse, callback}
local nextTicket = 1
local responses = {}     -- list of { match = {fragments}, body = string }
local requestLog = {}

-- Minimal XML parser matching the shape C4:ParseXml returns for MCWS payloads.
local function parseXml(s)
  local root = { Name = nil, Attributes = {}, ChildNodes = {}, Value = '' }
  local rootTag, rootAttrs = s:match('<(%a+)([^>]-)/?>')
  root.Name = rootTag
  for k, v in (rootAttrs or ''):gmatch('(%w+)="([^"]*)"') do
    root.Attributes[k] = v
  end
  for attrs, value in s:gmatch('<Item([^>]-)>(.-)</Item>') do
    local node = { Name = 'Item', Attributes = {}, Value = value, ChildNodes = {} }
    for k, v in attrs:gmatch('(%w+)="([^"]*)"') do node.Attributes[k] = v end
    table.insert(root.ChildNodes, node)
  end
  return root
end

Properties = {
  ['JRiver Host'] = '192.0.2.10',
  ['JRiver Port'] = '52199',
  ['Zone'] = '0',
  ['Poll Interval'] = '2',
  ['Cache TTL'] = '300',
  ['Take Focus on Key'] = 'Off',
  ['Enter Theater View on Select'] = 'On',
  ['Leave Theater View on Deselect'] = 'On',
  ['Leave Theater View on Listen'] = 'On',
  ['Handle Volume'] = 'Off',
  ['Username'] = '',
  ['Password'] = '',
  ['Debug Mode'] = 'Off',
  ['Driver Version'] = '',
}

VARS, EVENTS = {}, {}
local timers = {}
C4 = {
  AllowExecute = function() end,
  urlSetTimeout = function() end,
  UpdateProperty = function(_, k, v) Properties[k] = v end,
  ParseXml = function(_, s) return parseXml(s) end,
  SetTimer = function(_, ms, fn, rep)
    local t = { Cancel = function() return nil end }
    table.insert(timers, t)
    return t
  end,
  urlGet = function(_, url)
    local ticket = nextTicket
    nextTicket = nextTicket + 1
    table.insert(requestLog, url)
    pending[ticket] = url
    return ticket
  end,
  Base64Encode = function(_, v) return 'B64(' .. tostring(v) .. ')' end,
  AddVariable = function(_, n, v) VARS[n] = v end,
  SetVariable = function(_, n, v) VARS[n] = v end,
  FireEvent = function(_, n) table.insert(EVENTS, n) end,
  GetDeviceID = function() return 100 end,
  GetBoundConsumerDevices = function() return {} end,
  GetDevicesByC4iName = function() return {} end,
  SendToDevice = function() end,
  SendToProxy = function(_, binding, cmd, params)
    SENT = SENT or {}
    table.insert(SENT, { binding = binding, cmd = cmd, params = params })
  end,
}

-- Matches a URL against a route's required fragments, all of which must be
-- present in any order. A fragment prefixed with '$' must appear at the very
-- end of the URL, which is how 'ID=1' is distinguished from 'ID=1000'.
local function matches(url, fragments)
  for _, fragment in ipairs(fragments) do
    local anchored = fragment:match('^%$(.*)$')
    if anchored then
      if url:sub(-#anchored) ~= anchored then return false end
    elseif not url:find(fragment, 1, true) then
      return false
    end
  end
  return true
end

-- Drain queued HTTP requests against the canned response table.
local function drain()
  local guard = 0
  while next(pending) and guard < 50 do
    guard = guard + 1
    local ticket, url = next(pending)
    pending[ticket] = nil
    local body
    for _, route in ipairs(responses) do
      if matches(url, route.match) then body = route.body break end
    end
    ReceivedAsync(ticket, body or '<Response Status="OK"/>', 200, {}, nil)
  end
end

dofile(HERE .. '/driver.lua')

-- Real payloads captured from the live MC 35.0.74 server. Each route lists the
-- URL fragments that must all be present, in any order.
responses = {
  { match = {'Browse/Children', '$ID=-1'}, body = [[<?xml version="1.0" encoding="UTF-8" standalone="yes" ?>
<Response Status="OK">
<Item Name="Audio" Type="2" SchemeID="15901903">1</Item>
<Item Name="Playlists" Type="3" PlaylistID="0">4</Item>
</Response>]] },

  { match = {'Browse/Children', '$ID=1000'}, body = [[<?xml version="1.0" encoding="UTF-8" standalone="yes" ?>
<Response Status="OK">
<Item Name="Example Artist" Type="2">1013</Item>
<Item Name="Various" Type="2">1014</Item>
</Response>]] },

  -- Leaf node: children come back empty, files carry the tracks.
  { match = {'Browse/Children', '$ID=1015'}, body = '<?xml version="1.0" ?>\n<Response Status="OK"/>' },

  { match = {'Browse/Children', '$ID=1'}, body = [[<?xml version="1.0" encoding="UTF-8" standalone="yes" ?>
<Response Status="OK">
<Item Name="Artist" Type="2" SchemeID="11196469">1000</Item>
<Item Name="Album" Type="2" SchemeID="15938897">1001</Item>
<Item Name="Genre" Type="2" SchemeID="10389903">1003</Item>
</Response>]] },

  { match = {'Browse/Files', 'ID=1015'}, body =
    '[{"Key":23,"Name":"First Track","Artist":"Example Artist","Album":"Example Album","Track #":1,"Duration":285.93},' ..
    '{"Key":24,"Name":"Second Track","Artist":"Example Artist","Album":"Example Album","Track #":2,"Duration":249.44}]' },

  { match = {'Playback/Info'}, body = [[<?xml version="1.0" encoding="UTF-8" standalone="yes" ?>
<Response Status="OK">
<Item Name="ZoneID">0</Item>
<Item Name="State">2</Item>
<Item Name="FileKey">27</Item>
<Item Name="PositionMS">45000</Item>
<Item Name="DurationMS">218000</Item>
<Item Name="PlayingNowPosition">3</Item>
<Item Name="PlayingNowTracks">12</Item>
<Item Name="PlayingNowChangeCounter">2</Item>
<Item Name="Artist">Example Artist</Item>
<Item Name="Album">Example Album</Item>
<Item Name="Name">Third Track</Item>
</Response>]] },

  { match = {'UserInterface/Info'}, body = [[<?xml version="1.0" encoding="UTF-8" standalone="yes" ?>
<Response Status="OK">
<Item Name="Mode">3</Item>
<Item Name="InternalMode">-994</Item>
<Item Name="ViewDisplayName">Audio\Artist</Item>
<Item Name="SelectionDisplayName">Example Artist</Item>
</Response>]] },

  { match = {'Authenticate'}, body = '<Response Status="OK">\n<Item Name="Token">TESTTOKEN</Item>\n</Response>' },

  { match = {'Playback/Shuffle'}, body = '<Response Status="OK">\n<Item Name="Mode">Off</Item>\n</Response>' },
  { match = {'Playback/Repeat'}, body = '<Response Status="OK">\n<Item Name="Mode">Playlist</Item>\n</Response>' },

  { match = {'Playback/Playlist'}, body =
    '[{"Key":23,"Name":"First Track","Artist":"Example Artist","Duration":285.93},' ..
    '{"Key":24,"Name":"Second Track","Artist":"Example Artist","Duration":249.44}]' },
}

local failures = 0
local function check(label, cond, detail)
  if cond then
    print('  PASS  ' .. label)
  else
    failures = failures + 1
    print('  FAIL  ' .. label .. (detail and ('  -> ' .. tostring(detail)) or ''))
  end
end

OnDriverLateInit()
drain()

print('\n[1] Config loaded from properties')
check('host', Config.host == '192.0.2.10', Config.host)
check('port', Config.port == 52199, Config.port)
check('zone', Config.zone == '0', Config.zone)

print('\n[2] URL building')
local u = MCWS.Url('Browse/Files', { ID = 1015, Action = 'JSON', Fields = 'Track #' })
check('host/port/path', u:find('http://192.0.2.10:52199/MCWS/v1/Browse/Files', 1, true) ~= nil, u)
check("'Track #' encoded as Track%20%23", u:find('Track%20%23', 1, true) ~= nil, u)

-- Navigators cache artwork by URL, so identical parameters must always yield a
-- byte-identical string. Lua's pairs() order is not stable across tables, so
-- this regresses if MakeQuery ever stops sorting its keys.
local stable = true
local first = ImageListForFile('23')[1]
for _ = 1, 200 do
  if ImageListForFile('23')[1] ~= first then stable = false break end
end
check('artwork URLs are byte-stable across calls', stable, first)

print('\n[3] Item-list parsing')
local parsed = MCWS.ParseItems(responses[1].body)
check('status OK', parsed.status == 'OK', parsed.status)
check('2 items', #parsed.items == 2, #parsed.items)
check('name attr -> Audio', parsed.items[1].name == 'Audio', parsed.items[1].name)
check('element text -> node id 1', parsed.items[1].value == '1', parsed.items[1].value)
check('Type attribute kept', parsed.items[1].attrs.Type == '2', parsed.items[1].attrs.Type)

print('\n[4] Tab resolution walks the tree by name')
local resolved, resolveErr
Browse.ResolveTab('Artists', function(e, id) resolveErr, resolved = e, id end)
drain()
check('Artists -> node 1000', resolved == '1000', resolved or resolveErr)

local playlistsId
Browse.ResolveTab('Playlists', function(e, id) playlistsId = id end)
drain()
check('Playlists -> node 4', playlistsId == '4', playlistsId)

local moreId
Browse.ResolveTab('More', function(e, id) moreId = id end)
drain()
check('More -> Audio node 1', moreId == '1', moreId)

print('\n[5] Node listing: branch vs leaf')
SENT = {}
local nav = Navigator:new('nav1')
nav:ListNode(5001, 'seq1', '1000')
drain()
local branchXml = SENT[#SENT].params.DATA
check('branch lists child nodes', branchXml:find('Example Artist', 1, true) ~= nil)
check('children marked isLink', branchXml:find('<isLink>true</isLink>', 1, true) ~= nil)
check('node artwork uses Browse/Image', branchXml:find('Browse/Image', 1, true) ~= nil)

SENT = {}
nav:ListNode(5001, 'seq2', '1015')
drain()
local leafXml = SENT[#SENT].params.DATA
check('leaf falls through to files', leafXml:find('First Track', 1, true) ~= nil)
check('Play All header present', leafXml:find('Play All', 1, true) ~= nil)
check('track artwork uses File/GetImage', leafXml:find('File/GetImage', 1, true) ~= nil)
check('duration formatted 4:45', leafXml:find('4:45', 1, true) ~= nil)

print('\n[6] Playback + UI state from real payloads')
PollNow()
drain()
check('state playing', PlaybackState.state == 'playing', PlaybackState.state)
check('position 45s', PlaybackState.position == 45, PlaybackState.position)
check('duration 218s', PlaybackState.duration == 218, PlaybackState.duration)
check('queue count 12', PlaybackState.queueCount == 12, PlaybackState.queueCount)
check('ui mode theater', PlaybackState.uiMode == 3, PlaybackState.uiMode)
check('UI Mode property', Properties['UI Mode'] == 'Theater', Properties['UI Mode'])
check('view name captured', PlaybackState.viewName == 'Audio\\Artist', PlaybackState.viewName)
check('shuffle read as off', PlaybackState.shuffleMode == false, PlaybackState.shuffleMode)
check('repeat read as on', PlaybackState.repeatMode == true, PlaybackState.repeatMode)
check('queue populated', #Queue == 2, #Queue)

print('\n[7] Play actions build the right MCWS calls')
requestLog = {}
PlayNode('1015', { shuffle = true })
local shuffleUrl = requestLog[#requestLog]
check('Action=Play', shuffleUrl:find('Action=Play', 1, true) ~= nil, shuffleUrl)
check('Shuffle=1', shuffleUrl:find('Shuffle=1', 1, true) ~= nil, shuffleUrl)
-- Theater View is up at this point in the harness, so MC's own UI should be
-- allowed to follow the navigator rather than being suppressed.
check('NoUI=0 while Theater View is showing', shuffleUrl:find('NoUI=0', 1, true) ~= nil, shuffleUrl)

local savedMode = PlaybackState.uiMode
PlaybackState.uiMode = 0
requestLog = {}
PlayNode('1015', {})
check('NoUI=1 when Theater View is not showing', requestLog[#requestLog]:find('NoUI=1', 1, true) ~= nil, requestLog[#requestLog])
PlaybackState.uiMode = savedMode
requestLog = {}
PlayNode('1015', { shuffle = true })
shuffleUrl = requestLog[#requestLog]
check('zone passed', shuffleUrl:find('Zone=0', 1, true) ~= nil, shuffleUrl)

requestLog = {}
nav:PlayNow(5001, 'seq', { id = '24', parentId = '1015' })
local nowUrl = requestLog[#requestLog]
check('track play keeps node context', nowUrl:find('ID=1015', 1, true) ~= nil, nowUrl)
check('ActiveFile=24', nowUrl:find('ActiveFile=24', 1, true) ~= nil, nowUrl)
check('no ActiveFileOnly (plays on)', nowUrl:find('ActiveFileOnly', 1, true) == nil, nowUrl)

requestLog = {}
nav:AddToQueue(5001, 'seq', { id = '24', parentId = '1015' })
local addUrl = requestLog[#requestLog]
check('PlayMode=Add', addUrl:find('PlayMode=Add', 1, true) ~= nil, addUrl)
check('ActiveFileOnly=1 (single track)', addUrl:find('ActiveFileOnly=1', 1, true) ~= nil, addUrl)

print('\n[8] Shuffle toggle sends the opposite of current state')
requestLog = {}
PlaybackState.shuffleMode = false
nav:ToggleShuffle(5001, 'seq', {})
check('off -> Reshuffle', requestLog[#requestLog]:find('Mode=Reshuffle', 1, true) ~= nil, requestLog[#requestLog])
requestLog = {}
PlaybackState.shuffleMode = true
nav:ToggleShuffle(5001, 'seq', {})
check('on -> Off', requestLog[#requestLog]:find('Mode=Off', 1, true) ~= nil, requestLog[#requestLog])

print('\n[9] Time formatting')
check('0', FormatTime(0) == '0:00', FormatTime(0))
check('285.93 -> 4:45', FormatTime(285.93) == '4:45', FormatTime(285.93))
check('3725 -> 1:02:05', FormatTime(3725) == '1:02:05', FormatTime(3725))
check('nil safe', FormatTime(nil) == '0:00', FormatTime(nil))

print('\n[10] Seek (<< / >>) maps to Playback/Position')
requestLog = {}
nav:SCAN_FWD(5001, 'seq', {})
local fwd = requestLog[1]
check('uses Playback/Position', fwd:find('Playback/Position', 1, true) ~= nil, fwd)
check('relative forward', fwd:find('Relative=1', 1, true) ~= nil, fwd)
check('step in ms', fwd:find('Position=10000', 1, true) ~= nil and fwd:find('Mode=ms', 1, true) ~= nil, fwd)

requestLog = {}
nav:SCAN_REV(5001, 'seq', {})
check('relative back', requestLog[1]:find('Relative=-1', 1, true) ~= nil, requestLog[1])

requestLog = {}
nav:START_SCAN_FWD(5001, 'seq', {})
check('hold seeks immediately', #requestLog == 1, #requestLog)
nav:STOP_SCAN_FWD(5001, 'seq', {})

print('\n[11] Progress interpolates between polls')
PlaybackState.state = 'playing'
PlaybackState.position = 100
PlaybackState.duration = 218
PlaybackState.positionSyncedAt = os.time() - 5
check('advances by elapsed wall clock', EffectivePosition() == 105, EffectivePosition())
PlaybackState.positionSyncedAt = os.time() - 1000
check('clamped to duration', EffectivePosition() == 218, EffectivePosition())
PlaybackState.state = 'paused'
PlaybackState.positionSyncedAt = os.time() - 5
check('paused does not advance', EffectivePosition() == 100, EffectivePosition())

SENT = {}
PlaybackState.state = 'playing'
PlaybackState.positionSyncedAt = os.time() - 5
UpdateProgress()
local prog = SENT[#SENT].params.EVTARGS
check('ProgressChanged carries offset+length', prog:find('<offset>105</offset>', 1, true) ~= nil
  and prog:find('<length>218</length>', 1, true) ~= nil, prog)
check('label counts down remaining', prog:find('1:45 / -1:53', 1, true) ~= nil, prog)

print('\n[12] Unhandled proxy commands are reported once each')
local logged = {}
local realLog = log
log = function(m) table.insert(logged, m) end
ReportUnhandled('MYSTERY_KEY')
ReportUnhandled('MYSTERY_KEY')
ReportUnhandled('OTHER_KEY')
log = realLog
check('each command reported exactly once', #logged == 2, #logged)
check('names the command', logged[1]:find('MYSTERY_KEY', 1, true) ~= nil, logged[1])

print('\n[13] Watch mode: media_player key forwarding')
requestLog = {}
ReceivedFromProxy(5002, 'UP', {})
local upUrl = requestLog[1]
check('UP -> Control/Key Key=Up', upUrl:find('Control/Key', 1, true) ~= nil
  and upUrl:find('Key=Up', 1, true) ~= nil, upUrl)
check('Focus follows property (Off)', upUrl:find('Focus=0', 1, true) ~= nil, upUrl)

requestLog = {}
ReceivedFromProxy(5002, 'CANCEL', {})
check('CANCEL -> Backspace (back, not exit)', requestLog[1]:find('Key=Backspace', 1, true) ~= nil, requestLog[1])

requestLog = {}
ReceivedFromProxy(5002, 'ENTER', {})
check('ENTER -> Enter', requestLog[1]:find('Key=Enter', 1, true) ~= nil, requestLog[1])

requestLog = {}
ReceivedFromProxy(5002, 'START_DOWN', {})
check('hold sends immediately', #requestLog == 1 and requestLog[1]:find('Key=Down', 1, true) ~= nil, #requestLog)
ReceivedFromProxy(5002, 'STOP_DOWN', {})

print('\n[14] Watch mode: Theater View entry and exit')
PlaybackState.uiMode = 0
requestLog = {}
ReceivedFromProxy(5002, 'DEVICE_SELECTED', {})
local sel = table.concat(requestLog, ' ')
check('selection enters Theater View (MCC 22001)', sel:find('Command=22001', 1, true) ~= nil, sel)

-- 22001 Parameter=0 does not toggle back out, so re-sending it when already in
-- Theater View is at best pointless; the driver must check first.
PlaybackState.uiMode = 3
requestLog = {}
ReceivedFromProxy(5002, 'DEVICE_SELECTED', {})
check('no re-entry when already in Theater View',
  table.concat(requestLog, ' '):find('Command=22001', 1, true) == nil, table.concat(requestLog, ' '))

PlaybackState.uiMode = 3
requestLog = {}
ReceivedFromProxy(5002, 'DEVICE_DESELECTED', {})
local desel = table.concat(requestLog, ' ')
check('deselection leaves via MCC 22009, not 22001', desel:find('Command=22009', 1, true) ~= nil
  and desel:find('Command=22001', 1, true) == nil, desel)

requestLog = {}
ReceivedFromProxy(5002, 'GUIDE', {})
check('GUIDE -> Theater View home (Parameter=1)', requestLog[1]:find('Parameter=1', 1, true) ~= nil, requestLog[1])

print('\n[15] Watch mode: transport and volume gating')
requestLog = {}
ReceivedFromProxy(5002, 'SKIP_FWD', {})
check('SKIP_FWD -> Playback/Next', requestLog[1]:find('Playback/Next', 1, true) ~= nil, requestLog[1])

requestLog = {}
ReceivedFromProxy(5002, 'SCAN_FWD', {})
check('SCAN_FWD -> relative seek', requestLog[1]:find('Playback/Position', 1, true) ~= nil
  and requestLog[1]:find('Relative=1', 1, true) ~= nil, requestLog[1])

Config.handleVolume = false
requestLog = {}
ReceivedFromProxy(5002, 'VOL_UP', {})
check('volume ignored while Handle Volume is Off', #requestLog == 0, #requestLog)

Config.handleVolume = true
requestLog = {}
ReceivedFromProxy(5002, 'VOL_UP', {})
check('volume relative when enabled', requestLog[1]:find('Relative=1', 1, true) ~= nil
  and requestLog[1]:find('Playback/Volume', 1, true) ~= nil, requestLog[1])

-- Playback/Mute has no toggle value, so the driver must resolve 1 vs 0 itself.
PlaybackState.muted = false
requestLog = {}
ReceivedFromProxy(5002, 'MUTE_TOGGLE', {})
check('unmuted -> Set=1', requestLog[1]:find('Set=1', 1, true) ~= nil, requestLog[1])
PlaybackState.muted = true
requestLog = {}
ReceivedFromProxy(5002, 'MUTE_TOGGLE', {})
check('muted -> Set=0', requestLog[1]:find('Set=0', 1, true) ~= nil, requestLog[1])
Config.handleVolume = false

print('\n[16] View follows the room automatically')
local function resetView()
  LastViewCommand.action, LastViewCommand.at = nil, 0
  requestLog = {}
end

-- Listen selected while MC sits in Theater View -> back to standard.
PlaybackState.uiMode = 3
resetView()
ReceivedFromProxy(5001, 'DEVICE_SELECTED', {})
check('Listen select leaves Theater View', table.concat(requestLog, ' '):find('Command=22009', 1, true) ~= nil,
  table.concat(requestLog, ' '))

-- Listen selected while already standard -> nothing sent.
PlaybackState.uiMode = 0
resetView()
ReceivedFromProxy(5001, 'DEVICE_SELECTED', {})
check('Listen select is a no-op when already standard',
  table.concat(requestLog, ' '):find('Control/MCC', 1, true) == nil, table.concat(requestLog, ' '))

-- Watch -> Listen fires deselect then select; the UI mode is still stale in
-- between, so the standard-view command must not go out twice.
PlaybackState.uiMode = 3
resetView()
ReceivedFromProxy(5002, 'DEVICE_DESELECTED', {})
ReceivedFromProxy(5001, 'DEVICE_SELECTED', {})
local mccCount = 0
for _, u in ipairs(requestLog) do
  if u:find('Command=22009', 1, true) then mccCount = mccCount + 1 end
end
check('source switch sends standard-view exactly once', mccCount == 1, mccCount)

-- The driver must not fight a user who switches MC to Theater View by hand
-- while Listen is active: view changes are event-driven, never poll-driven.
PlaybackState.uiMode = 0
resetView()
PollNow()
drain()
check('poll alone never issues a view command',
  table.concat(requestLog, ' '):find('Control/MCC', 1, true) == nil, table.concat(requestLog, ' '))

-- Opting out.
Config.leaveTheaterOnListen = false
PlaybackState.uiMode = 3
resetView()
ReceivedFromProxy(5001, 'DEVICE_SELECTED', {})
check('property Off disables the behaviour',
  table.concat(requestLog, ' '):find('Command=22009', 1, true) == nil, table.concat(requestLog, ' '))
Config.leaveTheaterOnListen = true

print('\n[17] Virtual switcher is plumbing, not a source')
requestLog = {}
ReceivedFromProxy(5003, 'ON', {})
ReceivedFromProxy(5003, 'OFF', {})
check('switcher power commands issue no MCWS traffic', #requestLog == 0, #requestLog)

SENT = {}
ReceivedFromProxy(5003, 'SET_INPUT', { INPUT = 1, OUTPUT = 1 })
local names = {}
for _, e in ipairs(SENT) do table.insert(names, e.cmd) end
-- The room's AV path does not complete unless the switch acknowledges the change.
check('SET_INPUT is acknowledged to the proxy',
  table.concat(names, ','):find('INPUT_OUTPUT_CHANGED', 1, true) ~= nil, table.concat(names, ','))

check('hiding the switcher survives a bare C4 API', pcall(HideSwitcherInAllRooms))

print('\n[18] Room transport buttons (no NAVID, binding 5001)')
-- Captured from hardware: physical buttons arrive on the media_service binding
-- with ROOM_ID/DEVICE_ID and no NAVID, so they must dispatch without a session.
local ROOM = { ROOM_ID = 30, DEVICE_ID = 32, BEGIN = 3113798008 }

requestLog = {}
ReceivedFromProxy(5001, 'PAUSE', ROOM)
check('PAUSE reaches MCWS', (requestLog[1] or ''):find('Playback/Pause', 1, true) ~= nil, requestLog[1])

requestLog = {}
ReceivedFromProxy(5001, 'END_PAUSE', { DURATION = 173, ROOM_ID = 30 })
check('END_PAUSE is not a second action', #requestLog == 0, #requestLog)

requestLog = {}
ReceivedFromProxy(5001, 'STOP', ROOM)
check('STOP reaches MCWS', (requestLog[1] or ''):find('Playback/Stop', 1, true) ~= nil, requestLog[1])

requestLog = {}
ReceivedFromProxy(5001, 'PLAY', ROOM)
check('PLAY reaches MCWS', (requestLog[1] or ''):find('Playback/PlayPause', 1, true) ~= nil, requestLog[1])

-- << and >> do arrive on a media_service binding, despite being absent from the
-- MSP documentation entirely.
requestLog = {}
ReceivedFromProxy(5001, 'SCAN_FWD', { ROOM_ID = 30 })
check('SCAN_FWD seeks forward', (requestLog[1] or ''):find('Relative=1', 1, true) ~= nil, requestLog[1])

requestLog = {}
ReceivedFromProxy(5001, 'SCAN_REV', { ROOM_ID = 30 })
check('SCAN_REV seeks back', (requestLog[1] or ''):find('Relative=-1', 1, true) ~= nil, requestLog[1])

requestLog = {}
ReceivedFromProxy(5001, 'SKIP_FWD', ROOM)
check('SKIP_FWD skips track', (requestLog[1] or ''):find('Playback/Next', 1, true) ~= nil, requestLog[1])

-- A room command with no handler must be reported, not silently dropped -- that
-- silence is what hid this whole class of bug.
local logged = {}
local realLog = log
log = function(m) table.insert(logged, m) end
UnhandledCommands = {}
ReceivedFromProxy(5001, 'SOME_UNKNOWN_KEY', { ROOM_ID = 30 })
log = realLog
check('unknown room command is reported', #logged == 1 and logged[1]:find('SOME_UNKNOWN_KEY', 1, true) ~= nil,
  logged[1] or 'nothing logged')

print('\n[19] Tapping an entry in the Now Playing queue')
SENT = {}
UpdateQueue()
local queueXml = SENT[#SENT].params.EVTARGS
check('queue entries carry a default action', queueXml:find('<default_action>PlayQueueItem</default_action>', 1, true) ~= nil)
-- Playing Now is 0-based; the first entry must be index 0, not 1.
check('first entry is index 0', queueXml:find('<queueIndex>0</queueIndex>', 1, true) ~= nil, queueXml:sub(1, 200))
check('second entry is index 1', queueXml:find('<queueIndex>1</queueIndex>', 1, true) ~= nil)

requestLog = {}
nav:PlayQueueItem(5001, 'seq', { queueIndex = '1' })
local jump = requestLog[#requestLog]
check('jumps within the loaded queue', jump:find('Playback/PlayByIndex', 1, true) ~= nil, jump)
check('passes the index through', jump:find('Index=1', 1, true) ~= nil, jump)

requestLog = {}
nav:PlayQueueItem(5001, 'seq', {})
check('a missing index is ignored, not sent as nil', #requestLog == 0, #requestLog)

print('\n[20] Now Playing is pushed to navigators that ask for it')
-- GetDashboard and GetQueue arrive with no NAVID, so they belong on RFP. Leaving
-- the dashboard request unanswered is what stopped the progress bar appearing.
PlaybackState.state = 'playing'
PlaybackState.position = 30
PlaybackState.duration = 218
PlaybackState.positionSyncedAt = os.time()

SENT = {}
ReceivedFromProxy(5001, 'GetDashboard', { ROOM_ID = 30 })
local names = {}
for _, e in ipairs(SENT) do table.insert(names, tostring(e.params and e.params.NAME)) end
check('GetDashboard answers with ProgressChanged',
  table.concat(names, ','):find('ProgressChanged', 1, true) ~= nil, table.concat(names, ','))
check('GetDashboard answers with DashboardChanged',
  table.concat(names, ','):find('DashboardChanged', 1, true) ~= nil, table.concat(names, ','))

SENT = {}
ReceivedFromProxy(5001, 'GetQueue', { ROOM_ID = 30 })
names = {}
for _, e in ipairs(SENT) do table.insert(names, tostring(e.params and e.params.NAME)) end
check('GetQueue answers with QueueChanged',
  table.concat(names, ','):find('QueueChanged', 1, true) ~= nil, table.concat(names, ','))

-- Selecting the device while a track is already playing must still deliver
-- artwork; polling only re-sends media info when the track changes.
SENT = {}
PlaybackState.fileKey = '23'
ReceivedFromProxy(5001, 'DEVICE_SELECTED', { ROOM_ID = 30 })
drain()
local mediaInfo
for _, e in ipairs(SENT) do if e.cmd == 'UPDATE_MEDIA_INFO' then mediaInfo = e.params end end
check('selection pushes media info', mediaInfo ~= nil)
-- UPDATE_MEDIA_INFO is specified as LINE1..LINE4 with a Base64 IMAGEURL. The
-- tutorial's TITLE/ALBUM/ARTIST fields are not in the spec and left the Now
-- Playing screen showing a stock icon.
check('uses the specified LINE fields', mediaInfo and mediaInfo.LINE1 ~= nil, mediaInfo and mediaInfo.LINE1)
check('artwork is Base64 encoded', mediaInfo and mediaInfo.IMAGEURL:find('B64(', 1, true) == 1,
  mediaInfo and mediaInfo.IMAGEURL)
check('artwork points at MC and is Now-Playing sized',
  mediaInfo and mediaInfo.IMAGEURL:find('GetImage', 1, true) ~= nil
  and mediaInfo.IMAGEURL:find('Width=400', 1, true) ~= nil, mediaInfo and mediaInfo.IMAGEURL)
check('declares MERGE so omitted fields are not stale', mediaInfo and mediaInfo.MERGE ~= nil)

print('\n[21] Hiding the switcher is rate limited')
LastSwitcherHide = 0
local hides = 0
local realHide = HideSwitcherInAllRooms
HideSwitcherInAllRooms = function() hides = hides + 1 end
for _ = 1, 50 do OnSystemEvent({}) end
HideSwitcherInAllRooms = realHide
-- System events fire constantly; walking every room each time is what a burst
-- would look like from a navigator's point of view.
check('50 system events cause at most one room sweep', hides <= 1, hides)

print('\n[22] Authentication is wired, not just advertised')
-- The Username/Password properties previously did nothing: URLs read a token
-- that nothing ever obtained.
Config.username, Config.password = '', ''
Auth.token, Auth.obtainedAt = nil, 0
requestLog = {}
MCWS.RefreshToken()
check('no credentials means no auth traffic', #requestLog == 0, #requestLog)
check('no Authorization header when unconfigured', next(MCWS.AuthHeaders()) == nil)

Config.username, Config.password = 'ben', 'secret'
check('Basic header sent when configured',
  (MCWS.AuthHeaders().Authorization or ''):find('Basic B64(ben:secret)', 1, true) ~= nil,
  MCWS.AuthHeaders().Authorization)

requestLog = {}
MCWS.RefreshToken()
drain()
check('token obtained from Authenticate', Auth.token == 'TESTTOKEN', Auth.token)
-- Navigators fetch artwork directly and cannot send headers, so the token has
-- to travel in the URL.
check('artwork URL carries the token',
  (FileImageUrl('23', 140) or ''):find('Token=TESTTOKEN', 1, true) ~= nil, FileImageUrl('23', 140))

requestLog = {}
MCWS.RefreshToken()
check('a fresh token is not re-fetched', #requestLog == 0, #requestLog)
Config.username, Config.password = '', ''
Auth.token, Auth.obtainedAt = nil, 0

print('\n[23] Browse cache is bounded')
Browse.children = {}
for i = 1, MAX_CACHED_NODES + 40 do
  Browse.children['n' .. i] = { ts = i, items = {} }
  PruneCache(Browse.children)
end
local count = 0
for _ in pairs(Browse.children) do count = count + 1 end
-- TTL marks entries stale but never frees them; on a full library the tree can
-- be walked indefinitely.
check('cache stops growing at the ceiling', count <= MAX_CACHED_NODES, count)
check('the newest entry survives', Browse.children['n' .. (MAX_CACHED_NODES + 40)] ~= nil)
check('the oldest entry was evicted', Browse.children['n1'] == nil)

print('\n[24] Now Playing global actions')
SENT = {}
UpdateQueue()
local q = SENT[#SENT].params.EVTARGS
check('NowPlaying packages its actionIds', q:find('<actionIds>Shuffle Repeat</actionIds>', 1, true) ~= nil, q:sub(1,160))

print('\n[25] Action rows and headers carry the right icons')
SENT = {}
nav:ListNode(5001, 'seq', '1015')
drain()
local leaf = SENT[#SENT].params.DATA
local rows = {}
for item in leaf:gmatch('<item>.-</item>') do
  rows[item:match('<title>([^<]*)</title>') or '?'] = item
end

-- These used to fall back to the driver tile, which says nothing about the action.
check('Play All uses a play glyph',
  (rows['Play All'] or ''):find('action_play_', 1, true) ~= nil)
check('Shuffle All uses a shuffle glyph',
  (rows['Shuffle All'] or ''):find('action_shuffle_', 1, true) ~= nil)
check('action rows do not fall back to the driver tile',
  (rows['Play All'] or ''):find('device_', 1, true) == nil)

-- Section dividers should not carry an icon at all.
check('headers carry no image', (rows['Tracks'] or ''):find('<image_list', 1, true) == nil,
  (rows['Tracks'] or ''):sub(1, 120))

-- Tracks keep their real artwork.
check('tracks still use album art',
  (rows['First Track'] or ''):find('File/GetImage', 1, true) ~= nil)

print('\n[26] Play All / Shuffle All above the album level')
-- Browse/Files returns everything beneath a node, so a branch (an artist, a
-- genre) can be played whole just like an album.
SENT = {}
nav:ListNode(5001, 'seq', '1000')          -- Artist category, drilled into
drain()
local branch = SENT[#SENT].params.DATA
check('a drilled-in branch offers Play All', branch:find('<title>Play All</title>', 1, true) ~= nil)
check('a drilled-in branch offers Shuffle All', branch:find('<title>Shuffle All</title>', 1, true) ~= nil)
check('the branch still lists its children', branch:find('Example Artist', 1, true) ~= nil)
check('Play All targets the branch node itself', branch:find('<id>1000</id>', 1, true) ~= nil)

-- At the top of a tab these would mean the entire library rather than the thing
-- just selected, so they are suppressed there.
SENT = {}
nav:ListNode(5001, 'seq', '1000', { isTabRoot = true })
drain()
local root = SENT[#SENT].params.DATA
check('a tab root does not offer Play All', root:find('<title>Play All</title>', 1, true) == nil)
check('a tab root still lists its children', root:find('Example Artist', 1, true) ~= nil)

-- Browsing a tab must go through the tab-root path.
SENT = {}
nav:Browse(5001, 'seq', { tabId = 'Artists' })
drain()
check('tab browse suppresses Play All',
  SENT[#SENT].params.DATA:find('<title>Play All</title>', 1, true) == nil)

-- And albums keep what they already had.
SENT = {}
nav:ListNode(5001, 'seq', '1015')
drain()
check('albums still offer Play All', SENT[#SENT].params.DATA:find('<title>Play All</title>', 1, true) ~= nil)

print('\n[27] Programming: variables and events')
VARS, EVENTS = {}, {}
SetupVariables()
check('variables are declared', VARS['Track'] ~= nil and VARS['Theater View'] ~= nil)
-- Re-declaring must also clear the write cache, or the first publish afterwards
-- is suppressed and Director keeps values that no longer reflect anything.
check('re-declaring clears the write cache', next(VariableCache) == nil)

-- A playing track should be visible to programming without any UI open.
EVENTS = {}
PlaybackState.state, PlaybackState.fileKey = 'stopped', nil
PublishState({ state = 'stopped', fileKey = nil })
PlaybackState.state, PlaybackState.fileKey = 'playing', '27'
PlaybackState.name, PlaybackState.artist = 'Third Track', 'Example Artist'
PublishState({ state = 'stopped', fileKey = nil })
check('track is published', VARS['Track'] == 'Third Track', VARS['Track'])
check('artist is published', VARS['Artist'] == 'Example Artist')
check('playing flag is published', VARS['Playing'] == true)
local ev = table.concat(EVENTS, ',')
check('Playback Started fired', ev:find('Playback Started', 1, true) ~= nil, ev)
check('Track Changed fired', ev:find('Track Changed', 1, true) ~= nil, ev)

-- Rewriting unchanged values every poll would re-trigger programming.
local writes = 0
local realSet = C4.SetVariable
C4.SetVariable = function(_, n, v) writes = writes + 1 end
PublishState({ state = PlaybackState.state, fileKey = PlaybackState.fileKey })
C4.SetVariable = realSet
check('unchanged state writes nothing', writes == 0, writes)

EVENTS = {}
PlaybackState.uiMode = 3
PublishUiState(0)
check('Theater View variable set', VARS['Theater View'] == true)
check('Theater View Entered fired', table.concat(EVENTS, ','):find('Theater View Entered', 1, true) ~= nil)
EVENTS = {}
PlaybackState.uiMode = 0
PublishUiState(3)
check('Theater View Exited fired', table.concat(EVENTS, ','):find('Theater View Exited', 1, true) ~= nil)

EVENTS = {}
Connected = nil
SetConnected(false)
SetConnected(false)
check('connection loss reported once', #EVENTS == 1 and EVENTS[1] == 'Connection Lost', table.concat(EVENTS, ','))
SetConnected(true)
check('connection restored reported', EVENTS[#EVENTS] == 'Connection Restored')

print('\n[28] Programming: commands')
requestLog = {}
ExecuteCommand('JRiver Pause', {})
check('Pause drives MCWS', (requestLog[1] or ''):find('Playback/Pause', 1, true) ~= nil, requestLog[1])

requestLog = {}
ExecuteCommand('Set Repeat', { ['Mode'] = 'Playlist' })
check('Set Repeat passes the mode', (requestLog[1] or ''):find('Mode=Playlist', 1, true) ~= nil, requestLog[1])

requestLog = {}
ExecuteCommand('Seek', { ['Seconds'] = '90' })
check('Seek converts to milliseconds', (requestLog[1] or ''):find('Position=90000', 1, true) ~= nil, requestLog[1])

requestLog = {}
ExecuteCommand('Send MCC', { ['Command'] = '22001', ['Parameter'] = '3' })
check('Send MCC passes both values',
  (requestLog[1] or ''):find('Command=22001', 1, true) ~= nil
  and (requestLog[1] or ''):find('Parameter=3', 1, true) ~= nil, requestLog[1])

-- Play Path addresses nodes by name, which is what a person writing programming
-- knows; the numeric IDs are reassigned by Media Center.
requestLog = {}
ExecuteCommand('Play Path', { ['Browse Path'] = 'Audio\\Artist' })
drain()
local played = requestLog[#requestLog] or ''
check('Play Path resolves a name path to a node',
  played:find('Browse/Files', 1, true) ~= nil and played:find('ID=1000', 1, true) ~= nil, played)

requestLog = {}
ExecuteCommand('Shuffle Path', { ['Browse Path'] = 'Audio/Artist' })
drain()
check('Shuffle Path shuffles, and accepts forward slashes',
  (requestLog[#requestLog] or ''):find('Shuffle=1', 1, true) ~= nil, requestLog[#requestLog])

local logged = {}
local realLog = log
log = function(m) table.insert(logged, m) end
UnhandledCommands = {}
ExecuteCommand('Play Path', { ['Browse Path'] = 'Audio\\Nonexistent' })
drain()
log = realLog
check('an unresolvable path is reported, not silent', #logged > 0, logged[1] or 'nothing logged')

print('\n[29] Events fire in Listen mode, and with nothing selected at all')
-- Composer lists the driver's events under the Theater View device. This checks
-- that the grouping is cosmetic: events come from the poll loop, which has no
-- connection to any proxy.
local function armStateChange()
  VARS, EVENTS = {}, {}
  VariableCache = {}
  PlaybackState.state = 'stopped'
  PlaybackState.fileKey = nil
  Connected = true
end

-- Listen mode: the media_service device is the room's source.
DeviceSelected, PlayerSelected = false, false
ReceivedFromProxy(5001, 'DEVICE_SELECTED', { ROOM_ID = 30 })
drain()
check('Listen mode is what is selected', DeviceSelected == true and PlayerSelected == false)

armStateChange()
PollNow()          -- fixture reports State=2, FileKey=27
drain()
local ev = table.concat(EVENTS, ',')
check('Playback Started fires in Listen mode', ev:find('Playback Started', 1, true) ~= nil, ev)
check('Track Changed fires in Listen mode', ev:find('Track Changed', 1, true) ~= nil, ev)
check('variables publish in Listen mode', VARS['Track'] == 'Third Track', VARS['Track'])

-- Nothing selected anywhere: pure automation, no navigator, no room source.
Navigators = {}
DeviceSelected, PlayerSelected = false, false
armStateChange()
PollNow()
drain()
ev = table.concat(EVENTS, ',')
check('events still fire with nothing selected', ev:find('Track Changed', 1, true) ~= nil, ev)

print('\n[30] Poll rate follows playback, not just selection')
Navigators = {}
DeviceSelected, PlayerSelected = false, false
PlaybackState.state = 'stopped'
check('idle when nothing is playing or selected', CurrentPollInterval() == IDLE_POLL_MS, CurrentPollInterval())
-- Otherwise a track change during unattended playback could be reported up to
-- half a minute late, which defeats using it for programming.
PlaybackState.state = 'playing'
check('full rate while playing unattended',
  CurrentPollInterval() == Config.pollInterval * 1000, CurrentPollInterval())
DeviceSelected = true
PlaybackState.state = 'stopped'
check('full rate while selected but idle',
  CurrentPollInterval() == Config.pollInterval * 1000, CurrentPollInterval())
DeviceSelected = false

print('\n' .. (failures == 0 and 'ALL CHECKS PASSED' or (failures .. ' CHECK(S) FAILED')))
os.exit(failures == 0 and 0 or 1)

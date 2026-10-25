-- Replay Control 0.1.38: native replay transport and per-car observed lap starts.
local sim = ac.getSim()
local settings = ac.storage({
  transparency = 0.8, backgroundOpacity = -1,
  separatorWidth = 8, buttonSize = 32, showDiagnostics = false,
  headerMode = 4, compactLayoutVersion = 0, timelineTransparency = 0.5, timelineOpacity = -1
})
-- Preserve the previous visual alpha when upgrading existing preferences.
if settings.backgroundOpacity < 0 then
  settings.backgroundOpacity = math.max(0, math.min(1, 1 - settings.transparency))
end
if settings.timelineOpacity < 0 then
  settings.timelineOpacity = math.max(0, math.min(1, 1 - settings.timelineTransparency))
end
local buttonWidth, buttonHeight, buttonGap = 64, 32, 8
local fitWindowRequested = settings.compactLayoutVersion < 1
local message = ''
local suppressStatusReport = false
local heldKey = nil
local heldCtrl = false
local keyTime = 0
local pendingStep = nil
local stepTime = 0
local stepPauseRetried = false
local queuedKey = nil
local lapMarkers = {}
local markersByCar = {}
local markerCar = -1
local markerFrames = -1
local markerReplay = nil

local function clamp(v, lo, hi)
  return math.max(lo, math.min(hi, v))
end

local function available()
  return sim.isReplayActive and sim.replayFrames > 0 and sim.replayFrameMs > 0
end

local function seek(frame)
  if not available() or sim.isMakingScreenshot then return end
  local value = clamp(frame, 0, sim.replayFrames - 1)
  ac.setReplayPosition(math.floor(value), value - math.floor(value))
end

-- Use configured native AC bindings, not guessed simulation command names.
local function releaseKey()
  if heldKey then
    local ok = pcall(ac.sendKeyboardButtonEvent, heldKey, false)
    if ok then heldKey = nil end
  end
  if heldCtrl and not heldKey then
    local ok = pcall(ac.sendKeyboardButtonEvent, 0x11, false)
    if ok then heldCtrl = false end
  end
end

local function manualSeek(frame)
  suppressStatusReport = true
  message = ''
  pendingStep = nil
  queuedKey = nil
  releaseKey()
  if not available() or sim.isMakingScreenshot then return end
  seek(frame)
end

local function nativeCommand(command)
  suppressStatusReport = command == 'PREVIOUS_CAR' or command == 'NEXT_CAR'
  if suppressStatusReport then message = '' end
  if not available() or sim.isMakingScreenshot then return false end
  if heldKey or heldCtrl or queuedKey then
    message = 'Please wait for the current key press to finish.'
    return false
  end
  local ok, key = pcall(function ()
    return ac.INIConfig.controlsConfig():get(command, 'KEY', -1)
  end)
  key = ok and tonumber(key) or nil
  if not key or key <= 0 or key > 255 then
    message = 'No keyboard binding for ' .. command .. '. Assign a key in Content Manager.'
    return false
  end
  queuedKey = {key = key}
  message = ''
  return true
end

local function nativePlay(playing)
  pendingStep = nil
  if not available() then return end
  local paused = math.abs(sim.replayPlaybackRate) < 0.0001
  local normalSpeed = math.abs(sim.replayPlaybackRate - 1) < 0.0001
  if (playing and not normalSpeed) or (not playing and not paused) then
    return nativeCommand('PAUSE_REPLAY')
  end
  message = playing and 'Native playback is already running.' or 'Replay is already paused.'
  return true
end

local function nativeStep(delta)
  if not available() or sim.isMakingScreenshot then return end
  if heldKey or heldCtrl or queuedKey then
    message = 'Please wait, then try the frame step again.'
    return
  end
  local base = sim.replayCurrentFrame
  if not nativePlay(false) then return end
  pendingStep = clamp(math.floor(base) + delta, 0, sim.replayFrames - 1)
  stepTime = 0.35
  stepPauseRetried = false
end

local function observeLap(carIndex)
  local car = ac.getCar(carIndex)
  if not car or car.lapTimeMs <= 0 then return end
  local start = sim.replayCurrentFrame - car.lapTimeMs / sim.replayFrameMs
  if start < 0 or start >= sim.replayFrames then return end
  -- Remote replay cars can report lapCount=0 for every lap. Index by position.
  local tolerance = math.max(2, 750 / sim.replayFrameMs)
  for _, marker in ipairs(lapMarkers) do
    if math.abs(marker.frame - start) <= tolerance then return end
  end
  lapMarkers[#lapMarkers + 1] = {frame = start}
  table.sort(lapMarkers, function (a, b) return a.frame < b.frame end)
end

local function focusedReplayCar()
  local index = sim.focusedCar
  if index < 0 then index = sim.closelyFocusedCar end
  if index < 0 then return nil, -1 end
  return ac.getCar(index), index
end

local function updateLapMarkers()
  if not available() then
    lapMarkers = {}
    markersByCar = {}
    markerFrames = -1
    markerReplay = nil
    markerCar = -1
    return
  end
  local replayFilename = ac.getReplayFilename()
  if markerFrames ~= sim.replayFrames or markerReplay ~= replayFilename then
    markersByCar = {}
    markerFrames = sim.replayFrames
    markerReplay = replayFilename
  end
  local car, carIndex = focusedReplayCar()
  markerCar = carIndex
  if not car then lapMarkers = {} return end
  markersByCar[carIndex] = markersByCar[carIndex] or {}
  lapMarkers = markersByCar[carIndex]
  observeLap(carIndex)
end

local function jumpLap(direction)
  suppressStatusReport = false
  local _, carIndex = focusedReplayCar()
  pendingStep = nil
  if carIndex == 0 then
    nativeCommand(direction < 0 and 'PREVIOUS_LAP' or 'NEXT_LAP')
    return
  end
  if carIndex < 0 then message = 'No focused car.' return end
  local current = sim.replayCurrentFrame
  local tolerance = math.max(2, 250 / sim.replayFrameMs)
  local target = nil
  for _, marker in ipairs(lapMarkers) do
    if direction < 0 and marker.frame < current - tolerance then
      target = marker.frame
    elseif direction > 0 and marker.frame > current + tolerance then
      target = marker.frame
      break
    end
  end
  if target then
    manualSeek(target)
    message = 'Jumped to an observed lap start.'
  else
    message = 'No observed lap start in that direction. Scrub or play through more laps.'
  end
end

local function timestamp(frame)
  local hundredths = math.max(0, math.floor(frame * sim.replayFrameMs / 10 + 1e-7))
  return string.format('%d:%02d:%02d.%02d', math.floor(hundredths / 360000),
    math.floor(hundredths / 6000) % 60, math.floor(hundredths / 100) % 60,
    hundredths % 100)
end

local function centeredText(text, large)
  if large then ui.pushFont(ui.Font.Title) end
  ui.textAligned(text, 0.5, vec2(ui.availableSpaceX(), large and 30 or 20), true)
  if large then ui.popFont() end
end

function script.update(dt)
  -- UI delta stays nonzero during native replay pause.
  dt = math.max(0, ac.getDeltaT())
  if heldKey or (heldCtrl and not queuedKey) then
    keyTime = keyTime - math.max(0, dt)
    if keyTime <= 0 then releaseKey() end
  end
  if queuedKey then
    if not available() or not sim.isWindowForeground then
      queuedKey = nil
      releaseKey()
      pendingStep = nil
      message = 'Input cancelled: replay inactive or AC not focused.'
    else
      local request = queuedKey
      if not request.modifierReady then
        local ok, err = true, nil
        if not ac.isKeyPressed(0x11) then
          ok, err = pcall(ac.sendKeyboardButtonEvent, 0x11, true)
          if ok then heldCtrl = true end
        end
        if ok then
          request.modifierReady = true
        else
          queuedKey = nil
          pendingStep = nil
          message = 'Ctrl input failed: ' .. tostring(err)
        end
      else
        queuedKey = nil
        local ok, err = pcall(ac.sendKeyboardButtonEvent, request.key, true)
        if ok then
          heldKey = request.key
          keyTime = 0.05
        else
          pendingStep = nil
          releaseKey()
          message = 'Keyboard input failed: ' .. tostring(err)
        end
      end
    end
  end
  if pendingStep and not queuedKey and not heldKey and not sim.isMakingScreenshot then
    if not available() then
      pendingStep = nil
    else
      stepTime = stepTime - math.max(0, dt)
      if stepTime <= 0 or math.abs(sim.replayPlaybackRate) < 0.0001 then
        if math.abs(sim.replayPlaybackRate) < 0.0001 then
          seek(pendingStep)
          message = 'Frame set; native playback is paused.'
        elseif not stepPauseRetried and math.abs(sim.replayPlaybackRate - 1) < 0.0001 then
          stepPauseRetried = true
          stepTime = 0.35
          if not nativeCommand('PAUSE_REPLAY') then pendingStep = nil end
        else
          message = 'Native pause not confirmed. Pause the replay and try again.'
          pendingStep = nil
        end
        if math.abs(sim.replayPlaybackRate) < 0.0001 then pendingStep = nil end
      end
    end
  end
  updateLapMarkers()
end

function script.windowHide()
  queuedKey = nil
  pendingStep = nil
  releaseKey()
end

local function replayButton(id, icon, tooltip, action)
  ui.pushID(id)
  local labels = {
    begin = 'Start', rewind = 'Rewind', forward = 'Forward',
    ['end'] = 'End', slow = 'Slow-mo',
    frameBack = 'Frame -', frameNext = 'Frame +',
    lapBack = 'Lap -', lapNext = 'Lap +'
  }
  local label = labels[id]
  if id == 'playPause' then
    label = math.abs(sim.replayPlaybackRate - 1) < 0.0001 and 'Pause' or 'Play'
  elseif id:sub(1, 4) == 'jump' then
    label = string.format('%+d s', tonumber(id:sub(5)))
  end
  ui.beginGroup(buttonWidth)
  local clicked = ui.iconButton(icon, vec2(buttonWidth, buttonHeight), nil, nil, -2)
  if ui.itemHovered() then ui.setTooltip(tooltip) end
  ui.textAligned(label or tooltip, 0.5, vec2(buttonWidth, 18))
  if ui.itemHovered() then ui.setTooltip(tooltip) end
  ui.endGroup()
  if clicked then action() end
  ui.popID()
end

local function headerText(carIndex)
  if carIndex < 0 then return 'Replay Control' end
  local carName = ac.getCarName(carIndex)
  local driver = ac.getDriverName(carIndex) or ''
  local team = ac.getDriverTeam(carIndex) or ''
  if settings.headerMode == 1 then return carName end
  if settings.headerMode == 2 then return driver ~= '' and driver or 'Driver unavailable' end
  if settings.headerMode == 3 then return team ~= '' and team or 'Team unavailable' end
  if team ~= '' and driver ~= '' then return team .. ' | ' .. driver end
  return driver ~= '' and driver or (team ~= '' and team or carName)
end

local function fitWindowHeight()
  if not fitWindowRequested then return end
  local height = math.max(220, ui.getCursorY() + 12)
  for _, window in ipairs(ac.getAppWindows()) do
    if window.title == 'Replay Control' then
      local accessor = ac.accessAppWindow(window.name)
      if accessor and accessor:valid() then
        accessor:resize(vec2(window.size.x, height))
        settings.compactLayoutVersion = 1
        fitWindowRequested = false
        return
      end
    end
  end
end

function script.windowMain()
  local windowSize = ui.windowSize()
  -- Extend the drawing clip to the window border, including padded margins.
  ui.pushClipRect(vec2(0, 0), windowSize, false)
  ui.drawRectFilled(vec2(0, 0), windowSize, rgbm(0, 0, 0, settings.backgroundOpacity))
  ui.popClipRect()
  local _, carIndex = focusedReplayCar()
  local headerOrigin = ui.getCursor()
  local headerWidth = ui.availableSpaceX()
  ui.pushID('previousCar')
  if ui.iconButton('icons/jump-1.png', vec2(40, 30), nil, nil, -2) then
    pendingStep = nil
    nativeCommand('PREVIOUS_CAR')
  end
  if ui.itemHovered() then ui.setTooltip('Previous car') end
  ui.popID()
  ui.setCursor(vec2(headerOrigin.x + 48, headerOrigin.y))
  ui.pushFont(ui.Font.Title)
  ui.textAligned(headerText(carIndex), vec2(0.5, 0.5), vec2(headerWidth - 96, 30), true)
  ui.popFont()
  if ui.itemHovered() then ui.setTooltip(headerText(carIndex)) end
  ui.setCursor(vec2(headerOrigin.x + headerWidth - 40, headerOrigin.y))
  ui.pushID('nextCar')
  if ui.iconButton('icons/jump1.png', vec2(40, 30), nil, nil, -2) then
    pendingStep = nil
    nativeCommand('NEXT_CAR')
  end
  if ui.itemHovered() then ui.setTooltip('Next car') end
  ui.popID()
  ui.setCursor(vec2(headerOrigin.x, headerOrigin.y + 38))
  if not available() then
    ui.textWrapped('Open a replay to begin.')
    if ui.button('Start instant replay') then
      if not ac.tryToToggleReplay(true, 30) then
        message = 'Instant replay is unavailable.'
      end
    end
    if message ~= '' then ui.textWrapped(message) end
    return
  end

  local shown = sim.replayCurrentFrame
  local replayCar, replayCarIndex = focusedReplayCar()
  ui.setNextItemWidth(ui.availableSpaceX())
  ui.pushStyleColor(ui.StyleColor.FrameBg, rgbm(0.2, 0.2, 0.2, settings.timelineOpacity))
  ui.pushStyleColor(ui.StyleColor.FrameBgHovered, rgbm(0.2, 0.2, 0.2, settings.timelineOpacity))
  ui.pushStyleColor(ui.StyleColor.FrameBgActive, rgbm(0.2, 0.2, 0.2, settings.timelineOpacity))
  ui.pushStyleColor(ui.StyleColor.SliderGrab, rgbm(0.6, 0.6, 0.6, 1))
  ui.pushStyleColor(ui.StyleColor.SliderGrabActive, rgbm(0.72, 0.72, 0.72, 1))
  ui.pushStyleVar(ui.StyleVar.GrabMinSize, 5)
  local value, changed = ui.slider('##timeline', shown,
    0, math.max(1, sim.replayFrames - 1), '', true)
  ui.popStyleVar()
  ui.popStyleColor(5)
  local barMin, barMax = ui.itemRectMin(), ui.itemRectMax()
  ui.drawRect(barMin, barMax, rgbm(0.35, 0.35, 0.35, 0.9), 0, ui.CornerFlags.All, 1)
  for _, marker in pairs(lapMarkers) do
    local x = barMin.x + 4.5 + (barMax.x - barMin.x - 9)
      * marker.frame / math.max(1, sim.replayFrames - 1)
    ui.drawLine(vec2(x, barMin.y + 2), vec2(x, barMax.y - 2), rgbm(1, 0.8, 0.25, 0.9), 1)
  end
  if changed then manualSeek(value) end

  buttonGap = math.min(settings.separatorWidth, math.max(0, (ui.availableSpaceX() - 7 * 64) / 6))
  buttonHeight = settings.buttonSize
  buttonWidth = math.min(math.max(64, settings.buttonSize * 2),
    (ui.availableSpaceX() - 6 * buttonGap) / 7)
  local rowSize = 7 * buttonWidth + 6 * buttonGap
  ui.offsetCursorY(10)
  local buttonsLeft = ui.getCursorX() + math.max(0, (ui.availableSpaceX() - rowSize) / 2)
  ui.setCursorX(buttonsLeft)
  local showPlay = math.abs(sim.replayPlaybackRate - 1) >= 0.0001
  replayButton('begin', 'icons/begin.png', 'Go to start', function () manualSeek(0) end)
  ui.sameLine(0, buttonGap)
  replayButton('lapBack', 'icons/lap-back.png', 'Previous lap', function () jumpLap(-1) end)
  ui.sameLine(0, buttonGap)
  replayButton('rewind', 'icons/rewind.png', 'Rewind', function () pendingStep = nil nativeCommand('REV') end)
  ui.sameLine(0, buttonGap)
  replayButton('playPause', showPlay and 'icons/play.png' or 'icons/pause.png',
    showPlay and 'Play at 1x' or 'Pause', function () nativePlay(showPlay) end)
  ui.sameLine(0, buttonGap)
  replayButton('forward', 'icons/forward.png', 'Forward', function () pendingStep = nil nativeCommand('FFWD') end)
  ui.sameLine(0, buttonGap)
  replayButton('lapNext', 'icons/lap-next.png', 'Next lap', function () jumpLap(1) end)
  ui.sameLine(0, buttonGap)
  replayButton('end', 'icons/end.png', 'Go to end', function () manualSeek(sim.replayFrames - 1) end)

  ui.setCursorX(buttonsLeft)
  for i, seconds in ipairs({-10, -1}) do
    if i > 1 then ui.sameLine(0, buttonGap) end
    replayButton('jump' .. seconds, 'icons/jump' .. seconds .. '.png',
      string.format('%+d seconds', seconds), function ()
        local base = sim.replayCurrentFrame
        manualSeek(base + seconds * 1000 / sim.replayFrameMs)
      end)
  end
  ui.sameLine(0, buttonGap)
  replayButton('frameBack', 'icons/frame-back.png', 'Previous frame', function () nativeStep(-1) end)
  ui.sameLine(0, buttonGap)
  replayButton('slow', ui.Icons.SlowMotion, 'Slow motion', function () pendingStep = nil nativeCommand('SLOWMO') end)
  ui.sameLine(0, buttonGap)
  replayButton('frameNext', 'icons/frame-next.png', 'Next frame', function () nativeStep(1) end)
  for _, seconds in ipairs({1, 10}) do
    ui.sameLine(0, buttonGap)
    replayButton('jump' .. seconds, 'icons/jump' .. seconds .. '.png',
      string.format('%+d seconds', seconds), function ()
        local base = sim.replayCurrentFrame
        manualSeek(base + seconds * 1000 / sim.replayFrameMs)
      end)
  end
  local rowOrigin = ui.getCursor()
  local rowWidth = ui.availableSpaceX()
  local status = math.abs(sim.replayPlaybackRate) < 0.0001 and 'Paused'
    or string.format('Playback: %.2fx', sim.replayPlaybackRate)
  local knownLap = replayCar and (replayCarIndex == 0 or replayCar.lapCount > 0)
  local lapText = knownLap and ('Recorded lap: ' .. (replayCar.lapCount + 1)) or 'Recorded lap: --'
  ui.pushFont(ui.Font.Title)
  ui.textAligned(timestamp(shown) .. ' / ' .. timestamp(sim.replayFrames - 1),
    vec2(0, 0.5), vec2(rowWidth, 30))
  ui.setCursor(rowOrigin)
  ui.textAligned(status, vec2(0.5, 0.5), vec2(rowWidth, 30))
  ui.setCursor(rowOrigin)
  ui.textAligned(lapText, vec2(1, 0.5), vec2(rowWidth, 30))
  ui.popFont()
  if not suppressStatusReport and (message:find('not') or message:find('failed')
      or message:find('No ') or message:find('cancelled')) then
    ui.textWrapped(message)
  end
  fitWindowHeight()
end

function script.windowSettings()
  ui.header('Appearance')
  local selected, selectionChanged = ui.combo('Header', settings.headerMode, ui.ComboFlags.None,
    {'Car', 'Driver', 'Team', 'Team + driver'})
  if selectionChanged then settings.headerMode = selected end
  local value, changed = ui.slider('##backgroundOpacity', settings.backgroundOpacity * 100,
    0, 100, 'Background opacity: %.0f%%')
  if changed then settings.backgroundOpacity = value / 100 end
  value, changed = ui.slider('##timelineOpacity', settings.timelineOpacity * 100,
    0, 100, 'Timeline fill opacity: %.0f%%')
  if changed then settings.timelineOpacity = value / 100 end
  value, changed = ui.slider('##separatorWidth', settings.separatorWidth,
    0, 32, 'Separator width: %.0f px', true)
  if changed then settings.separatorWidth = value end
  value, changed = ui.slider('##buttonSize', settings.buttonSize,
    24, 48, 'Button size: %.0f px', true)
  if changed then settings.buttonSize = value end
  ui.textWrapped('Separator width controls the space between buttons. Button width fits the available window. Changes are saved automatically.')
  if ui.button('Reset appearance') then
    settings.backgroundOpacity = 0.2
    settings.timelineOpacity = 0.5
    settings.separatorWidth = 8
    settings.buttonSize = 32
    settings.headerMode = 4
    fitWindowRequested = true
  end
  if ui.button('Fit window height') then fitWindowRequested = true end
  ui.separator()
  ui.header('Keyboard bindings (read from AC)')
  ui.textWrapped('These keys are read from your active AC controls.ini. Change them in Content Manager: Settings > Assetto Corsa > Controls > System > Replay. Ctrl is added automatically.')
  local ok, bindings = pcall(ac.INIConfig.controlsConfig)
  if ok and bindings then
    for _, entry in ipairs({{'PREVIOUS_CAR', 'Previous car'}, {'NEXT_CAR', 'Next car'}, {'PAUSE_REPLAY', 'Play / Pause'}, {'PREVIOUS_LAP', 'Previous lap'},
        {'NEXT_LAP', 'Next lap'}, {'REV', 'Rewind'}, {'FFWD', 'Forward'}, {'SLOWMO', 'Slow motion'}}) do
      local key = tonumber(bindings:get(entry[1], 'KEY', -1)) or -1
      local specialKeys = {[32] = 'Space', [13] = 'Enter', [9] = 'Tab', [8] = 'Backspace',
        [37] = 'Left', [38] = 'Up', [39] = 'Right', [40] = 'Down', [96] = 'Numpad 0',
        [97] = 'Numpad 1', [98] = 'Numpad 2', [99] = 'Numpad 3', [100] = 'Numpad 4',
        [101] = 'Numpad 5', [102] = 'Numpad 6', [103] = 'Numpad 7', [104] = 'Numpad 8', [105] = 'Numpad 9'}
      local label = specialKeys[key]
      if not label and ((key >= 48 and key <= 57) or (key >= 65 and key <= 90)) then label = string.char(key) end
      if not label and key >= 112 and key <= 135 then label = 'F' .. (key - 111) end
      label = label or (key > 0 and string.format('0x%02X', key) or 'Not assigned')
      ui.text(entry[2] .. ': ' .. (key > 0 and 'Ctrl + ' or '') .. label)
    end
  else
    ui.text('Keyboard bindings unavailable.')
  end
  ui.separator()
  if ui.checkbox('Show diagnostics', settings.showDiagnostics) then
    settings.showDiagnostics = not settings.showDiagnostics
  end
  if settings.showDiagnostics then
    local replayCar, replayCarIndex = focusedReplayCar()
    ui.text(string.format('Car index: %d | Known lap starts: %d', replayCarIndex, #lapMarkers))
    ui.text(string.format('Replay frame: %d | Playback: %.2fx', sim.replayCurrentFrame, sim.replayPlaybackRate))
    if replayCar then
      ui.text(string.format('Reported completed laps: %d | Lap time: %d ms', replayCar.lapCount, replayCar.lapTimeMs))
    end
    if message ~= '' then ui.textWrapped(message) end
  end
end


ac.onRelease(function () queuedKey = nil releaseKey() end)


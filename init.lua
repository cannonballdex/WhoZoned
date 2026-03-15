-- WhoZoned.lua by Cannonballdex
-- Tracks players entering and leaving a zone
-- Adds GM enter/leave alerts, stores GM-marked players in a SQLite database,
-- and keeps persistent zone history in the GUI.

local mq = require('mq')
local ImGui = require('ImGui')
local lfs = require('lfs')
local PackageMan = require('mq.PackageMan')
local sqlite3 = PackageMan.Require('lsqlite3')

local SCRIPT_NAME = 'WhoZoned'

local state = {
    running = true,
    showGUI = true,
    scanIntervalMs = 3000,
    currentTracked = {},
    eventLog = {},
    maxLogEntries = 500,
    zoneShortName = '',
    dbDir = string.format('%s/WhoZoned', mq.configDir),
    dbPath = string.format('%s/WhoZoned/WhoZoned_gms.db', mq.configDir),
    historyRows = {},
    historyLimit = 200,
    historyNeedsRefresh = true,
}

local function nowString()
    return os.date('%Y-%m-%d %H:%M:%S')
end

local function safeString(v)
    if v == nil then
        return ''
    end
    return tostring(v)
end

local function helpTooltip(text)
    if ImGui.IsItemHovered() then
        ImGui.SetTooltip(text)
    end
end

local function ensureDBDir()
    local attr = lfs.attributes(state.dbDir)
    if not attr then
        local ok, err = lfs.mkdir(state.dbDir)
        if not ok then
            print('WhoZoned: failed to create directory: ' .. tostring(err))
        end
    end
end

local function openDB()
    ensureDBDir()

    local db = sqlite3.open(state.dbPath)
    if not db then
        print('WhoZoned: failed to open database')
        return nil
    end

    local rc1 = db:exec([[
        CREATE TABLE IF NOT EXISTS gm_players (
            player_name TEXT PRIMARY KEY,
            first_seen TEXT NOT NULL,
            last_seen TEXT NOT NULL
        );
    ]])

    if rc1 ~= sqlite3.OK then
        print('WhoZoned: failed to initialize GM database table')
        db:close()
        return nil
    end

    local rc2 = db:exec([[
        CREATE TABLE IF NOT EXISTS zone_events (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            zone_short TEXT NOT NULL,
            event_time TEXT NOT NULL,
            event_type TEXT NOT NULL,
            player_name TEXT NOT NULL,
            class_short TEXT,
            level INTEGER,
            guild_name TEXT,
            distance REAL,
            is_gm INTEGER NOT NULL DEFAULT 0
        );
    ]])

    if rc2 ~= sqlite3.OK then
        print('WhoZoned: failed to initialize zone history table')
        db:close()
        return nil
    end

    db:exec('CREATE INDEX IF NOT EXISTS idx_zone_events_zone_time ON zone_events(zone_short, event_time DESC);')
    db:exec('CREATE INDEX IF NOT EXISTS idx_zone_events_time ON zone_events(event_time DESC);')
    db:exec('CREATE INDEX IF NOT EXISTS idx_zone_events_player ON zone_events(player_name);')

    return db
end

local function saveGMToDB(info)
    if not info or not info.isGM or info.name == '' then
        return
    end

    local db = openDB()
    if not db then
        return
    end

    local ts = nowString()

    local insertStmt = db:prepare([[
        INSERT OR IGNORE INTO gm_players (player_name, first_seen, last_seen)
        VALUES (?, ?, ?);
    ]])

    if not insertStmt then
        print('WhoZoned: failed to prepare GM insert statement')
        db:close()
        return
    end

    insertStmt:bind_values(info.name, ts, ts)
    insertStmt:step()
    insertStmt:finalize()

    local updateStmt = db:prepare([[
        UPDATE gm_players
        SET last_seen = ?
        WHERE player_name = ?;
    ]])

    if not updateStmt then
        print('WhoZoned: failed to prepare GM update statement')
        db:close()
        return
    end

    updateStmt:bind_values(ts, info.name)
    updateStmt:step()
    updateStmt:finalize()

    db:close()
end

local function saveEventToDB(entry)
    if not entry or safeString(entry.name) == '' then
        return
    end

    local db = openDB()
    if not db then
        return
    end

    local stmt = db:prepare([[
        INSERT INTO zone_events (
            zone_short,
            event_time,
            event_type,
            player_name,
            class_short,
            level,
            guild_name,
            distance,
            is_gm
        )
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
    ]])

    if not stmt then
        print('WhoZoned: failed to prepare event insert statement')
        db:close()
        return
    end

    stmt:bind_values(
        safeString(entry.zoneShort),
        safeString(entry.time),
        safeString(entry.eventType),
        safeString(entry.name),
        safeString(entry.class),
        tonumber(entry.level) or 0,
        safeString(entry.guild),
        tonumber(entry.distance) or 0,
        entry.isGM and 1 or 0
    )

    stmt:step()
    stmt:finalize()
    db:close()
end

local function loadZoneHistoryRows(zoneShort, limit)
    zoneShort = safeString(zoneShort)
    limit = tonumber(limit) or state.historyLimit

    local db = openDB()
    if not db then
        state.historyRows = {}
        return
    end

    local stmt = db:prepare([[
        SELECT id, event_time, event_type, player_name, level, class_short, guild_name, distance, is_gm
        FROM zone_events
        WHERE zone_short = ?
        ORDER BY event_time DESC
        LIMIT ?;
    ]])

    if not stmt then
        print('WhoZoned: failed to load zone history rows')
        db:close()
        state.historyRows = {}
        return
    end

    stmt:bind_values(zoneShort, limit)

    local rows = {}
    for row in stmt:nrows() do
        table.insert(rows, {
            id = tonumber(row.id) or 0,
            time = safeString(row.event_time),
            eventType = safeString(row.event_type),
            name = safeString(row.player_name),
            level = tonumber(row.level) or 0,
            class = safeString(row.class_short),
            guild = safeString(row.guild_name),
            distance = tonumber(row.distance) or 0,
            isGM = tonumber(row.is_gm) == 1,
        })
    end

    stmt:finalize()
    db:close()

    state.historyRows = rows
    state.historyNeedsRefresh = false
end

local function printKnownGMs()
    local db = openDB()
    if not db then
        return
    end

    local stmt = db:prepare([[
        SELECT player_name, first_seen, last_seen
        FROM gm_players
        ORDER BY last_seen DESC;
    ]])

    if not stmt then
        print('WhoZoned: failed to query GM database')
        db:close()
        return
    end

    print('--- Known GMs ---')
    local foundAny = false

    for row in stmt:nrows() do
        foundAny = true
        print(string.format(
            '%s | first seen: %s | last seen: %s',
            safeString(row.player_name),
            safeString(row.first_seen),
            safeString(row.last_seen)
        ))
    end

    if not foundAny then
        print('No GMs saved yet.')
    end

    stmt:finalize()
    db:close()
end

local function printZoneHistory(zoneShort, limit)
    zoneShort = safeString(zoneShort)
    if zoneShort == '' then
        zoneShort = safeString(state.zoneShortName)
    end

    limit = tonumber(limit) or 50

    local db = openDB()
    if not db then
        return
    end

    local stmt = db:prepare([[
        SELECT event_time, event_type, player_name, level, class_short, guild_name, distance, is_gm
        FROM zone_events
        WHERE zone_short = ?
        ORDER BY event_time DESC
        LIMIT ?;
    ]])

    if not stmt then
        print('WhoZoned: failed to query zone history')
        db:close()
        return
    end

    stmt:bind_values(zoneShort, limit)

    print(string.format('--- Zone History: %s (latest %d) ---', zoneShort, limit))
    local foundAny = false

    for row in stmt:nrows() do
        foundAny = true
        print(string.format(
            '[%s] %s %s%s (%d %s) <%s> %.1f',
            safeString(row.event_time),
            safeString(row.event_type),
            tonumber(row.is_gm) == 1 and '[GM] ' or '',
            safeString(row.player_name),
            tonumber(row.level) or 0,
            safeString(row.class_short) ~= '' and safeString(row.class_short) or 'UNK',
            safeString(row.guild_name) ~= '' and safeString(row.guild_name) or 'NoGuild',
            tonumber(row.distance) or 0
        ))
    end

    if not foundAny then
        print('No history found for zone: ' .. zoneShort)
    end

    stmt:finalize()
    db:close()
end

local function printRecentHistory(limit)
    limit = tonumber(limit) or 50

    local db = openDB()
    if not db then
        return
    end

    local stmt = db:prepare([[
        SELECT zone_short, event_time, event_type, player_name, level, class_short, guild_name, distance, is_gm
        FROM zone_events
        ORDER BY event_time DESC
        LIMIT ?;
    ]])

    if not stmt then
        print('WhoZoned: failed to query recent history')
        db:close()
        return
    end

    stmt:bind_values(limit)

    print(string.format('--- Recent Zone History (latest %d) ---', limit))
    local foundAny = false

    for row in stmt:nrows() do
        foundAny = true
        print(string.format(
            '[%s] [%s] %s %s%s (%d %s) <%s> %.1f',
            safeString(row.event_time),
            safeString(row.zone_short),
            safeString(row.event_type),
            tonumber(row.is_gm) == 1 and '[GM] ' or '',
            safeString(row.player_name),
            tonumber(row.level) or 0,
            safeString(row.class_short) ~= '' and safeString(row.class_short) or 'UNK',
            safeString(row.guild_name) ~= '' and safeString(row.guild_name) or 'NoGuild',
            tonumber(row.distance) or 0
        ))
    end

    if not foundAny then
        print('No recent history found.')
    end

    stmt:finalize()
    db:close()
end

local function addLog(eventType, info)
    local entry = {
        time = nowString(),
        zoneShort = safeString(state.zoneShortName),
        eventType = eventType,
        name = info.name or '',
        class = info.class or '',
        level = info.level or 0,
        guild = info.guild or '',
        distance = info.distance or 0,
        isGM = info.isGM or false,
    }

    table.insert(state.eventLog, 1, entry)

    if #state.eventLog > state.maxLogEntries then
        table.remove(state.eventLog)
    end

    saveEventToDB(entry)
    state.historyNeedsRefresh = true

    print(string.format(
        '[%s] [%s] %s %s%s (%d %s)',
        entry.time,
        entry.zoneShort,
        entry.eventType,
        entry.isGM and '[GM] ' or '',
        entry.name,
        entry.level,
        entry.class ~= '' and entry.class or 'UNK'
    ))
end

local function showHelp()
    print('--- WhoZoned Commands ---')
    print('/wz help           - show this help menu')
    print('/wz show           - show the GUI window')
    print('/wz hide           - hide the GUI window')
    print('/wz toggle         - toggle the GUI window')
    print('/wz clear          - clear player log and rebuild baseline')
    print('/wz test           - add a test log entry')
    print('/wz gmlist         - list saved GMs from database')
    print('/wz history        - show saved history for the current zone')
    print('/wz history guktop - show saved history for a specific zone')
    print('/wz recent         - show recent saved history across all zones')
    print('/wz quit           - stop the script')
end

local function buildInfo(spawn)
    local classShort = ''
    local classObj = spawn.Class
    if classObj and classObj() then
        classShort = safeString(classObj.ShortName())
    end

    return {
        name = safeString(spawn.Name()),
        class = classShort,
        level = tonumber(spawn.Level()) or 0,
        guild = safeString(spawn.Guild()),
        distance = tonumber(spawn.Distance()) or 0,
        isGM = spawn.GM() or false,
    }
end

local function shouldTrack(info)
    local meName = safeString(mq.TLO.Me.Name())

    if info.name == '' then
        return false
    end

    if info.name == meName then
        return false
    end

    return true
end

local function getPlayerSpawns()
    return mq.getFilteredSpawns(function(spawn)
        if not spawn or not spawn() then
            return false
        end

        local spawnType = safeString(spawn.Type())
        if spawnType ~= 'PC' then
            return false
        end

        local name = safeString(spawn.Name())
        if name == '' then
            return false
        end

        return true
    end)
end

local function rebuildBaseline()
    local newTracked = {}
    local spawns = getPlayerSpawns()

    for _, spawn in ipairs(spawns) do
        local info = buildInfo(spawn)
        if shouldTrack(info) then
            newTracked[info.name] = info
            if info.isGM then
                saveGMToDB(info)
            end
        end
    end

    state.currentTracked = newTracked
end

local function scanPlayers()
    local nowTracked = {}
    local spawns = getPlayerSpawns()

    for _, spawn in ipairs(spawns) do
        local info = buildInfo(spawn)

        if shouldTrack(info) then
            nowTracked[info.name] = info

            if info.isGM then
                saveGMToDB(info)
            end

            if not state.currentTracked[info.name] then
                if info.isGM then
                    addLog('GM ENTERED', info)
                    print(string.format('*** GM ALERT: %s entered the zone! ***', info.name))
                else
                    addLog('ENTERED', info)
                end
            end
        end
    end

    for name, info in pairs(state.currentTracked) do
        if not nowTracked[name] then
            if info.isGM then
                addLog('GM LEFT', info)
            else
                addLog('LEFT', info)
            end
        end
    end

    state.currentTracked = nowTracked
end

local function zoneCheck()
    local z = safeString(mq.TLO.Zone.ShortName())

    if z ~= state.zoneShortName then
        state.zoneShortName = z
        state.currentTracked = {}
        state.eventLog = {}
        rebuildBaseline()
        state.historyNeedsRefresh = true
        print('Zone changed -> baseline reset')
    end
end

local function drawCurrentPlayers()
    local count = 0
    for _ in pairs(state.currentTracked) do
        count = count + 1
    end

    ImGui.Text('Tracked Players: ' .. count)
    helpTooltip('All players currently detected in the zone. GMs are marked with [GM].')
    ImGui.Separator()

    ImGui.BeginChild('players', 0, 180, ImGuiChildFlags.Borders)

    local tableFlags = bit32.bor(
        ImGuiTableFlags.RowBg,
        ImGuiTableFlags.Borders,
        ImGuiTableFlags.Resizable,
        ImGuiTableFlags.ScrollY,
        ImGuiTableFlags.Sortable
    )

    if ImGui.BeginTable('PlayerTable', 5, tableFlags) then
        ImGui.TableSetupColumn('Name', ImGuiTableColumnFlags.DefaultSort, 0, 1)
        ImGui.TableSetupColumn('Level', ImGuiTableColumnFlags.None, 0, 2)
        ImGui.TableSetupColumn('Class', ImGuiTableColumnFlags.None, 0, 3)
        ImGui.TableSetupColumn('Guild', ImGuiTableColumnFlags.None, 0, 4)
        ImGui.TableSetupColumn('Distance', ImGuiTableColumnFlags.None, 0, 5)

        ImGui.TableHeadersRow()

        local rows = {}
        for _, p in pairs(state.currentTracked) do
            table.insert(rows, p)
        end

        local sortSpecs = ImGui.TableGetSortSpecs()
        if sortSpecs and sortSpecs.SpecsCount > 0 then
            local spec = sortSpecs:Specs(1)

            table.sort(rows, function(a, b)
                local aVal, bVal

                if spec.ColumnUserID == 1 then
                    aVal = string.lower((a.isGM and '[GM] ' or '') .. safeString(a.name))
                    bVal = string.lower((b.isGM and '[GM] ' or '') .. safeString(b.name))
                elseif spec.ColumnUserID == 2 then
                    aVal = tonumber(a.level) or 0
                    bVal = tonumber(b.level) or 0
                elseif spec.ColumnUserID == 3 then
                    aVal = string.lower(safeString(a.class ~= '' and a.class or 'UNK'))
                    bVal = string.lower(safeString(b.class ~= '' and b.class or 'UNK'))
                elseif spec.ColumnUserID == 4 then
                    aVal = string.lower(safeString(a.guild ~= '' and a.guild or 'NoGuild'))
                    bVal = string.lower(safeString(b.guild ~= '' and b.guild or 'NoGuild'))
                elseif spec.ColumnUserID == 5 then
                    aVal = tonumber(a.distance) or 0
                    bVal = tonumber(b.distance) or 0
                else
                    aVal = string.lower(safeString(a.name))
                    bVal = string.lower(safeString(b.name))
                end

                if aVal == bVal then
                    return string.lower(safeString(a.name)) < string.lower(safeString(b.name))
                end

                if spec.SortDirection == ImGuiSortDirection.Ascending then
                    return aVal < bVal
                else
                    return aVal > bVal
                end
            end)

            sortSpecs.SpecsDirty = false
        else
            table.sort(rows, function(a, b)
                return string.lower(safeString(a.name)) < string.lower(safeString(b.name))
            end)
        end

        for _, p in ipairs(rows) do
            ImGui.TableNextRow()

            ImGui.TableSetColumnIndex(0)
            ImGui.Text((p.isGM and '[GM] ' or '') .. p.name)

            ImGui.TableSetColumnIndex(1)
            ImGui.Text(tostring(p.level))

            ImGui.TableSetColumnIndex(2)
            ImGui.Text(p.class ~= '' and p.class or 'UNK')

            ImGui.TableSetColumnIndex(3)
            ImGui.Text(p.guild ~= '' and p.guild or 'NoGuild')

            ImGui.TableSetColumnIndex(4)
            ImGui.Text(string.format('%.1f', p.distance))
        end

        ImGui.EndTable()
    end

    ImGui.EndChild()
end

local function drawEventLog()
    ImGui.Text('Event Log')
    helpTooltip('History of players entering and leaving the zone while this script is running.')
    ImGui.Separator()

    ImGui.BeginChild('log', 0, 250, ImGuiChildFlags.Borders)

    if #state.eventLog == 0 then
        ImGui.Text('No events yet.')
    else
        for _, e in ipairs(state.eventLog) do
            ImGui.Text(string.format(
                '[%s] %s %s%s (%d %s)',
                e.time,
                e.eventType,
                e.isGM and '[GM] ' or '',
                e.name,
                e.level,
                e.class ~= '' and e.class or 'UNK'
            ))
        end
    end

    ImGui.EndChild()
end

local function drawPersistentHistory()
    if state.historyNeedsRefresh then
        loadZoneHistoryRows(state.zoneShortName, state.historyLimit)
    end

    ImGui.Text('Saved Zone History')
    helpTooltip('Persistent history loaded from the database for the current zone.')
    ImGui.SameLine()

    if ImGui.SmallButton('Refresh History') then
        loadZoneHistoryRows(state.zoneShortName, state.historyLimit)
    end
    helpTooltip('Reload saved zone history from the database.')

    ImGui.SameLine()
    ImGui.Text(string.format('(%d rows)', #state.historyRows))

    ImGui.Separator()

    ImGui.BeginChild('history', 0, 260, ImGuiChildFlags.Borders)

    local tableFlags = bit32.bor(
        ImGuiTableFlags.RowBg,
        ImGuiTableFlags.Borders,
        ImGuiTableFlags.Resizable,
        ImGuiTableFlags.ScrollY,
        ImGuiTableFlags.Sortable
    )

    if ImGui.BeginTable('HistoryTable', 7, tableFlags) then
        ImGui.TableSetupColumn('Time', ImGuiTableColumnFlags.DefaultSort, 0, 1)
        ImGui.TableSetupColumn('Event', ImGuiTableColumnFlags.None, 0, 2)
        ImGui.TableSetupColumn('Name', ImGuiTableColumnFlags.None, 0, 3)
        ImGui.TableSetupColumn('Level', ImGuiTableColumnFlags.None, 0, 4)
        ImGui.TableSetupColumn('Class', ImGuiTableColumnFlags.None, 0, 5)
        ImGui.TableSetupColumn('Guild', ImGuiTableColumnFlags.None, 0, 6)
        ImGui.TableSetupColumn('Distance', ImGuiTableColumnFlags.None, 0, 7)

        ImGui.TableHeadersRow()

        local rows = {}
        for _, row in ipairs(state.historyRows) do
            rows[#rows + 1] = row
        end

        local sortSpecs = ImGui.TableGetSortSpecs()
        if sortSpecs and sortSpecs.SpecsCount > 0 then
            local spec = sortSpecs:Specs(1)

            table.sort(rows, function(a, b)
                local aVal, bVal

                if spec.ColumnUserID == 1 then
                    aVal = safeString(a.time)
                    bVal = safeString(b.time)
                elseif spec.ColumnUserID == 2 then
                    aVal = string.lower(safeString(a.eventType))
                    bVal = string.lower(safeString(b.eventType))
                elseif spec.ColumnUserID == 3 then
                    aVal = string.lower((a.isGM and '[GM] ' or '') .. safeString(a.name))
                    bVal = string.lower((b.isGM and '[GM] ' or '') .. safeString(b.name))
                elseif spec.ColumnUserID == 4 then
                    aVal = tonumber(a.level) or 0
                    bVal = tonumber(b.level) or 0
                elseif spec.ColumnUserID == 5 then
                    aVal = string.lower(safeString(a.class ~= '' and a.class or 'UNK'))
                    bVal = string.lower(safeString(b.class ~= '' and b.class or 'UNK'))
                elseif spec.ColumnUserID == 6 then
                    aVal = string.lower(safeString(a.guild ~= '' and a.guild or 'NoGuild'))
                    bVal = string.lower(safeString(b.guild ~= '' and b.guild or 'NoGuild'))
                elseif spec.ColumnUserID == 7 then
                    aVal = tonumber(a.distance) or 0
                    bVal = tonumber(b.distance) or 0
                else
                    aVal = safeString(a.time)
                    bVal = safeString(b.time)
                end

                if aVal == bVal then
                    return (tonumber(a.id) or 0) > (tonumber(b.id) or 0)
                end

                if spec.SortDirection == ImGuiSortDirection.Ascending then
                    return aVal < bVal
                else
                    return aVal > bVal
                end
            end)

            sortSpecs.SpecsDirty = false
        else
            table.sort(rows, function(a, b)
                return (tonumber(a.id) or 0) > (tonumber(b.id) or 0)
            end)
        end

        for _, row in ipairs(rows) do
            ImGui.TableNextRow()

            ImGui.TableSetColumnIndex(0)
            ImGui.Text(row.time)

            ImGui.TableSetColumnIndex(1)
            ImGui.Text(row.eventType)

            ImGui.TableSetColumnIndex(2)
            ImGui.Text((row.isGM and '[GM] ' or '') .. row.name)

            ImGui.TableSetColumnIndex(3)
            ImGui.Text(tostring(row.level))

            ImGui.TableSetColumnIndex(4)
            ImGui.Text(row.class ~= '' and row.class or 'UNK')

            ImGui.TableSetColumnIndex(5)
            ImGui.Text(row.guild ~= '' and row.guild or 'NoGuild')

            ImGui.TableSetColumnIndex(6)
            ImGui.Text(string.format('%.1f', row.distance))
        end

        ImGui.EndTable()
    end

    ImGui.EndChild()
end

local function renderGUI()
    if not state.showGUI then
        return
    end

    local open, show = ImGui.Begin('WhoZoned by Cannonballdex', true)

    if not open then
        state.running = false
        state.showGUI = false
        ImGui.End()
        return
    end

    if show then
        ImGui.Text('Zone: ' .. safeString(mq.TLO.Zone.ShortName()))
        ImGui.Text('DB: ' .. state.dbPath)
        ImGui.Separator()

        if ImGui.Button('Clear Log') then
            state.eventLog = {}
        end
        helpTooltip('Clears the event log shown below. This does not reset the tracked player baseline or database history.')

        ImGui.SameLine()
        if ImGui.Button('Rebuild Baseline') then
            state.currentTracked = {}
            rebuildBaseline()
            print('WhoZoned: baseline rebuilt')
        end
        helpTooltip('Rebuilds the baseline for the current zone. Players currently present will not trigger ENTER events until they leave and return.')

        ImGui.SameLine()
        if ImGui.Button('List Known GMs') then
            printKnownGMs()
        end
        helpTooltip('Prints all saved GM-marked player names from the database to the chat window.')

        ImGui.SameLine()
        if ImGui.Button('Zone History') then
            printZoneHistory(state.zoneShortName, 50)
        end
        helpTooltip('Prints saved history for the current zone from the database.')

        ImGui.Separator()
        drawCurrentPlayers()

        ImGui.Separator()
        drawEventLog()

        ImGui.Separator()
        drawPersistentHistory()
    end

    ImGui.End()
end

local function cmd(...)
    local args = { ... }
    local a = (args[1] or ''):lower()
    local b = args[2]
    local c = args[3]

    if a == 'help' then
        showHelp()
    elseif a == 'show' then
        state.showGUI = true
    elseif a == 'hide' then
        state.showGUI = false
    elseif a == 'toggle' then
        state.showGUI = not state.showGUI
    elseif a == 'clear' then
        state.eventLog = {}
        state.currentTracked = {}
        rebuildBaseline()
        print('WhoZoned: cleared')
    elseif a == 'test' then
        addLog('TEST', {
            name = 'TestPlayer',
            class = 'WAR',
            level = 60,
            guild = 'TestGuild',
            distance = 0,
            isGM = false,
        })
    elseif a == 'gmlist' then
        printKnownGMs()
    elseif a == 'history' then
        if b and safeString(b) ~= '' then
            printZoneHistory(b, tonumber(c) or 50)
        else
            printZoneHistory(state.zoneShortName, 50)
        end
    elseif a == 'recent' then
        printRecentHistory(tonumber(b) or 50)
    elseif a == 'quit' then
        state.running = false
    else
        showHelp()
    end
end

ensureDBDir()
do
    local db = openDB()
    if db then
        db:close()
    end
end

mq.bind('/wz', cmd)
mq.imgui.init(SCRIPT_NAME, renderGUI)

state.zoneShortName = safeString(mq.TLO.Zone.ShortName())
rebuildBaseline()
state.historyNeedsRefresh = true

print('WhoZoned running')
print('WhoZoned database: ' .. state.dbPath)
showHelp()

while state.running do
    zoneCheck()
    scanPlayers()
    mq.delay(state.scanIntervalMs)
end

mq.unbind('/wz')
mq.imgui.destroy(SCRIPT_NAME)

print('WhoZoned stopped')
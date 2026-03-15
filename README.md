# WhoZoned

**WhoZoned** is a MacroQuest Lua script that tracks players entering and leaving your current EverQuest zone.

It provides:

- Real-time **zone entry/exit tracking**
- **GM detection and alerts**
- **Persistent zone history** stored in SQLite
- **Saved GM player list**
- A sortable **ImGui interface**
- Command-line history queries

The script continuously scans the zone for player spawns and logs when players enter or leave.

---

# Features

## Player Zone Tracking

WhoZoned watches all **PC spawns** in the current zone and records when players:

- Enter the zone
- Leave the zone

Each event records:

- Player name
- Level
- Class
- Guild
- Distance
- Timestamp
- Zone name

---

## GM Detection

If a spawn is flagged as a **GM**, the script:

- Displays a **GM ALERT** in chat
- Marks the player as `[GM]` in logs and GUI
- Saves the player to the **GM database**

The database records:

- First time seen
- Last time seen

---

## Persistent Zone History

Every entry/exit event is saved to a **SQLite database** so history persists across sessions.

You can:

- View history in the GUI
- Query it via commands
- Review activity from previous play sessions

---

# Graphical Interface (ImGui)

The GUI displays three main sections.

---

## Current Players

Shows all players currently detected in the zone.

Columns:

- Name
- Level
- Class
- Guild
- Distance

Features:

- Sortable columns
- GM players marked with `[GM]`

---

## Event Log

Shows **live events** while the script is running.

Example:


[2026-03-10 21:12:31] ENTERED PlayerName (60 WAR)
[2026-03-10 21:14:02] GM ENTERED [GM] GuideExample (65 CLR)


---

## Saved Zone History

Displays events stored in the database for the current zone.

Features:

- Sortable table
- Persistent between sessions
- Refreshable

---

# Installation

## Requirements

You must have:

- MacroQuest
- Lua plugin enabled
- ImGui support
- PackageMan installed

The script automatically installs the required SQLite module:


lsqlite3


---

## Install Steps

1. Place the script in your MacroQuest Lua folder:


mq/lua/WhoZoned.lua


2. Start the script:


/lua run WhoZoned


3. The GUI window will open automatically.

---

# Commands

All commands use the `/wz` prefix.

---

## Help


/wz help


Shows command list.

---

## GUI Controls

Show the window:


/wz show


Hide the window:


/wz hide


Toggle the window:


/wz toggle


---

## Script Controls

Reset the player tracking baseline:


/wz clear


Add a test log entry:


/wz test


Stop the script:


/wz quit


---

## GM Database

Print all known GM players:


/wz gmlist


Example output:


--- Known GMs ---
GuideExample | first seen: 2026-03-10 21:14:02 | last seen: 2026-03-10 21:14:02


---

## Zone History

Show history for the **current zone**:


/wz history


Show history for a **specific zone**:


/wz history guktop


Limit results:


/wz history guktop 100


---

## Recent Activity (All Zones)

Show latest events across every zone:


/wz recent


Example:


[2026-03-10 21:14:02] [guktop] ENTERED PlayerName (60 WAR)


---

# Database

WhoZoned stores data using **SQLite**.

Database location:


MacroQuest/config/WhoZoned/WhoZoned_gms.db


Two tables are created automatically.

---

## gm_players

Stores known GM characters.

| Column | Description |
|------|-------------|
| player_name | GM character name |
| first_seen | First detection timestamp |
| last_seen | Most recent detection |

---

## zone_events

Stores all entry/exit events.

| Column | Description |
|------|-------------|
| id | Unique ID |
| zone_short | Zone short name |
| event_time | Timestamp |
| event_type | ENTERED / LEFT / GM ENTERED / GM LEFT |
| player_name | Character name |
| class_short | Class abbreviation |
| level | Character level |
| guild_name | Guild name |
| distance | Distance from you |
| is_gm | GM flag |

---

# How It Works

Every **3 seconds** the script:

1. Scans all PC spawns in the zone
2. Builds a list of currently present players
3. Compares with the previous scan
4. Detects:

- new players → **ENTERED**
- missing players → **LEFT**

If a GM flag is present:

- event becomes **GM ENTERED** or **GM LEFT**
- player is stored in the GM database

---

# Performance

The script is lightweight:

- Scan interval: **3000 ms**
- Uses spawn filtering
- SQLite writes are small and indexed
- GUI refresh only when needed

---

# Notes

- You are **never tracked yourself**.
- Baselines reset automatically when zoning.
- The GUI log only shows events **since the script started**.
- The database stores **permanent history**.

---

# Author

**Cannonballdex**

WhoZoned was designed to provide simple, persistent visibility into zone activity and GM presence.

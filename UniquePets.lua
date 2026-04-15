addon.name    = 'UniquePets'
addon.author  = 'Mazu'
addon.version = '2.6.1'

require('common')
local breader  = require('bitreader')
local struct   = require('struct')
local bit      = require('bit')
local imgui    = require('imgui')
local settings = require('settings')

------------------------------------------------------------
-- Default Settings
------------------------------------------------------------

local default_settings = T{
    local_player = T{},
    players = T{},
    
    -- Animation Patching (Default)
    is_patching = 0,
    anim_value = 0,
    anim_to_patch = 0,

    -- Advanced Animation Patching
    advanced_patching = 0,
    pet_overrides = {
        local_player = T{},
        players = T{},
    },
	
    -- Model Sync (per-pet idle/heal model swaps)
    model_sync_enabled = false,
    pet_model_sync = T{},

}

local config = settings.load(default_settings)

-- UI Buffers (Initialized empty, synced in settings_update)
local ui_buffers = {
    anim_val_input      = { tostring(config.anim_value or 0) },
    anim_to_patch_input = { tostring(config.anim_to_patch or 0) },
}

-- Per-pet model sync UI buffers: { petName = { idle = {'60'}, heal = {'2203'} } }
local ui_model_sync_bufs = {}

-- Forward declaration (populated later)
local model_sync

local function settings_update(s)
    if (s ~= nil and type(s) == 'table') then
        config = s
        ui_buffers.anim_val_input[1] = tostring(config.anim_value or 0)
        ui_buffers.anim_to_patch_input[1] = tostring(config.anim_to_patch or 0)
        ui_model_sync_bufs = {}
        if (model_sync) then
            model_sync.enabled = config.model_sync_enabled or false
        end
    end
end

settings.register('settings', 'settings_update', settings_update)

------------------------------------------------------------
-- Runtime State
------------------------------------------------------------

local show_ui = false
local local_player_name = nil

local remotePets = {
    byPetActIndex = {},
}

-- Pets whose models were actually patched (keyed by ServerId)
local patchedPets = {
    -- [serverId] = { pet=string, owner=string, is_local=bool }
}

-- Debug mode
local debug_mode = false

------------------------------------------------------------
-- Misc
------------------------------------------------------------

local bool_labels = { 'False', 'True' }

------------------------------------------------------------
-- UI Edit Buffers
------------------------------------------------------------

local ui_local_models  = {}
local ui_remote_models = {}

local ui_override_add = {
    local_player = {},
    players = {},
}

------------------------------------------------------------
-- Settings Save
------------------------------------------------------------

local function safe_settings_save()
    if (type(config) ~= 'table') then return end
    if (type(config.local_player) ~= 'table') then return end
    if (type(config.players) ~= 'table') then return end
    settings.save()
end

------------------------------------------------------------
-- Export / Import Helpers
------------------------------------------------------------
local function get_addon_path()
    return string.format('%saddons/%s/', AshitaCore:GetInstallPath(), addon.name)
end

local function serialize_table(tbl, indent)
    indent = indent or 0
    local pad = string.rep(' ', indent)
    local out = '{\n'

    for k, v in pairs(tbl) do

        out = out .. pad .. '    [' .. string.format('%q', k) .. '] = '

        if (type(v) == 'table') then
            out = out .. serialize_table(v, indent + 4)
        else
            out = out .. tostring(v)
        end

        out = out .. ',\n'
    end

    out = out .. pad .. '}'
    return out
end

local function write_export(filename, data)
    local f = io.open(get_addon_path() .. filename, 'w')
    if (not f) then return false end

    f:write('return ')
    f:write(serialize_table(data))
    f:close()
    return true
end

local function load_import(filename)
    local chunk = loadfile(get_addon_path() .. filename)
    if (not chunk) then return nil end

    local ok, data = pcall(chunk)
    if (not ok or type(data) ~= 'table') then
        return nil
    end

    return data
end

local function validate_single_player_import(data)
    if (type(data.players) ~= 'table') then
        return nil
    end

    local players = T(data.players)
    local pname = next(players)
    if (pname == nil or next(players, pname) ~= nil) then
        return nil
    end

    local entry = players[pname]
    if (type(entry) ~= 'table') then
        return nil
    end

    -- Old format (pet = model number directly)
    if (next(entry) and type(entry[next(entry)]) == 'number') then
        return pname, T(entry), T{}
    end

    return pname,
           T(entry.models or {}),
           T(entry.overrides or {})
end



------------------------------------------------------------
-- Helpers
------------------------------------------------------------

local function get_local_pet_server_id()
    local p = GetPlayerEntity()
    if (p == nil or p.PetTargetIndex == nil) then
        return nil
    end

    local pet = GetEntity(p.PetTargetIndex)
    return pet and pet.ServerId or nil
end

local function get_entity_name(actIndex)
    local e = GetEntity(actIndex)
    return e and e.Name or nil
end

local function get_actor_name(serverId)
    for x = 0, 2302 do
        local e = GetEntity(x)
        if (e and e.ServerId == serverId) then
            return e.Name
        end
    end
    return 'Unknown'
end

local function get_action_name(cmd_no)
    local names = {
        [0]  = 'None',
        [1]  = 'Attack',
        [2]  = 'R.Attack (F)',
        [3]  = 'WS (F)',
        [4]  = 'Magic (F)',
        [5]  = 'Item (F)',
        [6]  = 'JA (F)',
        [7]  = 'Mon/WS (S)',
        [8]  = 'Magic (S)',
        [9]  = 'Item (S)',
        [10] = 'JA (S)',
        [11] = 'MonSkill (F)',
        [12] = 'R.Attack (S)',
        [13] = 'PetAbility',
        [14] = 'Dancer',
        [15] = 'RuneFencer'
    }
    return names[cmd_no] or ('%d:Unknown'):format(cmd_no)
end

local function to_int(v)
    local n = tonumber(v)
    return n and math.floor(n) or nil
end

local function wildcard_to_pattern(wild)
    -- Escape Lua pattern magic chars except *
    wild = wild:gsub("([%%%^%$%(%)%.%[%]%+%-%?])", "%%%1")
    -- Convert * to .*
    wild = wild:gsub("%*", ".*")
    -- Anchor match to full string
    return "^" .. wild .. "$"
end

local function find_with_wildcards(tbl, entityName)
    if (not tbl) then return nil end

    -- 1. Exact match first (fast path)
    if (tbl[entityName] ~= nil) then
        return tbl[entityName]
    end

    -- 2. Wildcard matches
    for k, v in pairs(tbl) do
        if (type(k) == 'string' and k:find("%*")) then
            local pattern = wildcard_to_pattern(k)
            if (entityName:match(pattern)) then
                return v
            end
        end
    end

    return nil
end

local function get_pet_sync(petName)
    if (not config.pet_model_sync) then return nil end
    return find_with_wildcards(config.pet_model_sync, petName)
end

local function get_pet_rules(petInfo)
    local overrides = config.pet_overrides
    if (not overrides) then return nil end

    local rules = nil
    if (petInfo.is_local) then
        rules = find_with_wildcards(overrides.local_player, petInfo.pet)
    else
        local p = overrides.players and overrides.players[petInfo.owner]
        if (p) then
            rules = find_with_wildcards(p, petInfo.pet)
        end
    end
    return rules
end

local function find_matching_rule(rules, cmd_arg, cmd_no)
    if (not rules) then return nil end
    for _, rule in ipairs(rules) do
        if (rule.match == 'action') then
            if (rule.from == cmd_no) then return rule end
        else
            if (rule.from == cmd_arg) then return rule end
        end
    end
    return nil
end

------------------------------------------------------------
-- Heal Sync State
------------------------------------------------------------

model_sync = {
    enabled = config.model_sync_enabled or false,
    forced_state = nil,
}

------------------------------------------------------------
-- Pet Entity Helpers
------------------------------------------------------------

local function get_pet_entity()
    local p = GetPlayerEntity()
    if (p == nil or p.PetTargetIndex == nil or p.PetTargetIndex == 0) then
        return nil, nil
    end
    local pet = GetEntity(p.PetTargetIndex)
    if (not pet) then return nil, nil end
    return pet, p.PetTargetIndex
end

-- Cache the last raw 0x000E packet for each patched pet (keyed by serverId)
local lastPetPacket = {}

local function replay_pet_packet_with_model(serverId, modelId)
    local cached = lastPetPacket[serverId]
    if (not cached) then
        print('[UniquePets] No cached packet for serverId ' .. tostring(serverId))
        return false
    end

    local pkt = {}
    for i = 1, #cached do
        pkt[i] = cached[i]
    end

    -- Force the MODEL flag (0x10) in SendFlg at offset 0x0A so the client processes model data
    local sendFlg = pkt[0x0A + 1] or 0
    pkt[0x0A + 1] = bit.bor(sendFlg, 0x10)

    pkt[0x32 + 1] = bit.band(bit.rshift(modelId, 8), 0xFF)
    pkt[0x33 + 1] = bit.band(modelId, 0xFF)

    print(string.format('[UniquePets] Replaying cached packet (%d bytes, sendFlg 0x%02X->0x%02X) with model %d',
        #pkt, sendFlg, pkt[0x0A + 1], modelId))
    AshitaCore:GetPacketManager():AddIncomingPacket(0x0E, pkt)
    return true
end

------------------------------------------------------------
-- Commands
------------------------------------------------------------

addon.commands = { '/uniquepets', '/upets' }

ashita.events.register('command', 'upets_command', function (e)
    local a = e.command:args()
    if (#a == 0) then return end

    -- Intercept /heal to swap pet model BEFORE healing starts
    -- (ModelUpdateFlags doesn't work during healing status, so we must swap while standing)
    if (a[1] == '/heal' and model_sync.enabled) then
        local me = GetPlayerEntity()
        if (me) then
            local myStatus = me.Status
            local pet, petIdx = get_pet_entity()
            if (pet and petIdx and patchedPets[pet.ServerId]) then
                local petSync = get_pet_sync(pet.Name)
                local healModel = petSync and petSync.heal_model
                if (healModel and healModel > 0 and myStatus ~= 33
                    and model_sync.forced_state ~= 'heal') then
                    pet.Look.Hair = healModel
                    pet.ModelUpdateFlags = 0x10
                    model_sync.forced_state = 'heal'
                    model_sync.swap_time = os.clock()
                end
            end
        end
    end

    if (a[1] == '/uniquepets' or a[1] == '/upets') then
        e.blocked = true

        if (#a == 1) then
            show_ui = not show_ui
            return
        end

        local sub = a[2]:lower()

        if (sub == 'petdebug') then
            local pet, idx = get_pet_entity()
            if (not pet) then
                print('[UniquePets] No pet found.')
                return
            end
            local entMgr = AshitaCore:GetMemoryManager():GetEntity()
            local flags = entMgr:GetSpawnFlags(idx)
            local status = entMgr:GetStatus(idx)
            local statusServer = entMgr:GetStatusServer(idx)
            print(string.format('[UniquePets] Pet: %s  Index: %d  ServerId: %d',
                pet.Name or '?', idx, pet.ServerId or 0))
            print(string.format('[UniquePets]   SpawnFlags: 0x%04X  Status: %d  StatusServer: %d',
                flags, status, statusServer))
            print(string.format('[UniquePets]   Is Player: %s  Is NPC: %s  Is Mob: %s',
                (bit.band(flags, 0x0001) ~= 0) and 'Y' or 'N',
                (bit.band(flags, 0x0002) ~= 0) and 'Y' or 'N',
                (bit.band(flags, 0x0010) ~= 0) and 'Y' or 'N'))
            print('[UniquePets]   Note: TrustFlag is NOT set on TYPE_PET entities (server confirmed)')
            return
        end

        if (sub == 'petsit') then
            local pet, idx = get_pet_entity()
            if (not pet) then
                print('[UniquePets] No pet found.')
                return
            end
            local animVal = 33
            if (a[3]) then animVal = tonumber(a[3]) or 33 end
            print(string.format('[UniquePets] Forcing pet %s (idx %d) status to %d...',
                pet.Name or '?', idx, animVal))

            local entMgr = AshitaCore:GetMemoryManager():GetEntity()
            entMgr:SetStatus(idx, animVal)
            entMgr:SetStatusServer(idx, animVal)
            inject_entity_packet(idx, animVal)
            print('[UniquePets]   Done. Try values: 33=heal, 47=sit, 0=normal')
            return
        end

        if (sub == 'petanim') then
            local pet, idx = get_pet_entity()
            if (not pet) then
                print('[UniquePets] No pet found.')
                return
            end
            local field = a[3] and a[3]:lower() or 'play'
            local val = tonumber(a[4]) or 0
            local entMgr = AshitaCore:GetMemoryManager():GetEntity()
            if (field == 'play') then
                entMgr:SetAnimationPlay(idx, val)
                print(string.format('[UniquePets] SetAnimationPlay(%d, %d)', idx, val))
            elseif (field == 'step') then
                entMgr:SetAnimationStep(idx, val)
                print(string.format('[UniquePets] SetAnimationStep(%d, %d)', idx, val))
            elseif (field == 'sub') then
                -- animationsub via packet injection at offset 0x2A
                local pkt = {}
                for i = 1, 0x38 do pkt[i] = 0 end
                local size_words = 0x0E
                local header = bit.bor(0x0E, bit.lshift(size_words, 9))
                pkt[0x00 + 1] = bit.band(header, 0xFF)
                pkt[0x01 + 1] = bit.band(bit.rshift(header, 8), 0xFF)
                local sid = pet.ServerId
                pkt[0x04 + 1] = bit.band(sid, 0xFF)
                pkt[0x05 + 1] = bit.band(bit.rshift(sid, 8), 0xFF)
                pkt[0x06 + 1] = bit.band(bit.rshift(sid, 16), 0xFF)
                pkt[0x07 + 1] = bit.band(bit.rshift(sid, 24), 0xFF)
                pkt[0x08 + 1] = bit.band(idx, 0xFF)
                pkt[0x09 + 1] = bit.band(bit.rshift(idx, 8), 0xFF)
                pkt[0x0A + 1] = 0x04 -- UPDATE_HP
                pkt[0x1E + 1] = entMgr:GetHPPercent(idx)
                pkt[0x1F + 1] = entMgr:GetStatusServer(idx)
                pkt[0x2A + 1] = val
                AshitaCore:GetPacketManager():AddIncomingPacket(0x0E, pkt)
                print(string.format('[UniquePets] Injected animationsub=%d via packet', val))
            else
                print('[UniquePets] Usage: /upets petanim play|step|sub <value>')
            end
            return
        end

        if (sub == 'petlook') then
            local pet, idx = get_pet_entity()
            if (not pet) then
                print('[UniquePets] No pet found.')
                return
            end
            local entMgr = AshitaCore:GetMemoryManager():GetEntity()
            print(string.format('[UniquePets] Pet %s (idx %d) Look data:', pet.Name or '?', idx))
            print(string.format('  Hair: %d (0x%04X)  Head: %d (0x%04X)',
                pet.Look.Hair, pet.Look.Hair, pet.Look.Head, pet.Look.Head))
            print(string.format('  Body: %d (0x%04X)  Hands: %d (0x%04X)',
                pet.Look.Body, pet.Look.Body, pet.Look.Hands, pet.Look.Hands))
            print(string.format('  Legs: %d (0x%04X)  Feet: %d (0x%04X)',
                pet.Look.Legs, pet.Look.Legs, pet.Look.Feet, pet.Look.Feet))
            print(string.format('  Main: %d (0x%04X)  Sub: %d (0x%04X)  Ranged: %d (0x%04X)',
                pet.Look.Main, pet.Look.Main, pet.Look.Sub, pet.Look.Sub,
                pet.Look.Ranged, pet.Look.Ranged))
            print(string.format('  ModelUpdateFlags: %d (0x%04X)',
                pet.ModelUpdateFlags, pet.ModelUpdateFlags))
            return
        end

        if (sub == 'petmodel') then
            local pet, idx = get_pet_entity()
            if (not pet) then
                print('[UniquePets] No pet found.')
                return
            end
            local modelId = tonumber(a[3])
            if (not modelId) then
                print('[UniquePets] Usage: /upets petmodel <model_id>')
                return
            end
            print(string.format('[UniquePets] Setting pet model to %d via direct memory write...',
                modelId))
            print(string.format('[UniquePets]   Before: Look.Hair=%d Look.Head=%d Look.Body=%d',
                pet.Look.Hair, pet.Look.Head, pet.Look.Body))
            pet.Look.Hair = modelId
            pet.ModelUpdateFlags = 0x10
            print(string.format('[UniquePets]   After Hair: Look.Hair=%d  ModelUpdateFlags=0x10',
                pet.Look.Hair))
            return
        end

        if (sub == 'petdump') then
            local pet, idx = get_pet_entity()
            if (not pet) then
                print('[UniquePets] No pet found.')
                return
            end
            local entMgr = AshitaCore:GetMemoryManager():GetEntity()
            print(string.format('[UniquePets] Pet %s (idx %d):', pet.Name or '?', idx))
            print(string.format('  Status: %d  StatusServer: %d',
                entMgr:GetStatus(idx), entMgr:GetStatusServer(idx)))
            print(string.format('  AnimationPlay: %d  AnimationStep: %d',
                entMgr:GetAnimationPlay(idx), entMgr:GetAnimationStep(idx)))
            print(string.format('  SpawnFlags: 0x%04X  HPP: %d%%',
                entMgr:GetSpawnFlags(idx), entMgr:GetHPPercent(idx)))
            return
        end

        if (sub == 'petunsit') then
            local pet, idx = get_pet_entity()
            if (not pet) then
                print('[UniquePets] No pet found.')
                return
            end
            local entMgr = AshitaCore:GetMemoryManager():GetEntity()
            entMgr:SetStatus(idx, 0)
            entMgr:SetStatusServer(idx, 0)
            inject_entity_packet(idx, 0)
            model_sync.forced_state = nil
            print('[UniquePets] Pet reset to status 0.')
            return
        end

        if (sub == 'debug') then
            debug_mode = not debug_mode
            print(string.format('[UniquePets] Debug: %s', debug_mode and 'ON' or 'OFF'))
            return
        end

        if (sub == 'healsync' or sub == 'modelsync') then
            -- /upets modelsync  — toggles model sync on/off
            -- idle/heal models are now configured per-pet in the UI
            model_sync.enabled = not model_sync.enabled
            config.model_sync_enabled = model_sync.enabled
            safe_settings_save()
            print(string.format('[UniquePets] Model sync: %s', model_sync.enabled and 'ON' or 'OFF'))
            print('[UniquePets]   Configure per-pet idle/heal models in the UI (/upets)')
            return
        end

        show_ui = not show_ui
    end
end)

------------------------------------------------------------
-- Model Patching (0x000D / 0x000E)
------------------------------------------------------------

ashita.events.register('packet_in', 'upets_model_packet', function (e)

    -- Track pet ownership
    if (e.id == 0x000D) then
        local ownerAct = struct.unpack('H', e.data, 0x09)
        local petAct   = struct.unpack('H', e.data, 0x3D)
        if (petAct ~= 0) then
            remotePets.byPetActIndex[petAct] = ownerAct
        end
        return
    end

    if (e.id ~= 0x000E) then return end

    local actIndex = struct.unpack('H', e.data, 0x09)
    local ent = GetEntity(actIndex)
    if (not ent or not ent.Name) then return end

    local entityName = ent.Name
    local entSid     = struct.unpack('L', e.data, 0x05)
    local subKind = bit.band(struct.unpack('H', e.data, 0x31), 0x07)

    -- Model patching (subKind 0 only -- standard model format)
    if (subKind == 0) then
    -- Local pet
    local petSid = get_local_pet_server_id()
    if (petSid and entSid == petSid) then
		local model = find_with_wildcards(config.local_player, entityName)
		if (model) then
			ashita.bits.pack_be(e.data_modified_raw, model, 0x32, 0, 16)		
			patchedPets[entSid] = {
				pet      = entityName,
				owner    = local_player_name,
				is_local = true,
			}			
		end
        else
    -- Remote pet
    local ownerAct = remotePets.byPetActIndex[actIndex]
            if (ownerAct) then
    local ownerName = get_entity_name(ownerAct)
                if (ownerName) then
    local playerCfg = find_with_wildcards(config.players, ownerName)
                    if (playerCfg) then
	local model = find_with_wildcards(playerCfg, entityName)
	if (model) then
		ashita.bits.pack_be(e.data_modified_raw, model, 0x32, 0, 16)
		patchedPets[entSid] = {
			pet      = entityName,
			owner    = ownerName,
			is_local = false,
		}
	end
                    end
                end
            end
        end
    end

    -- Model sync: override model bytes in packets when idle or heal model is active
    if (model_sync.enabled and model_sync.forced_state and patchedPets[entSid] and subKind == 0) then
        local petInfo = patchedPets[entSid]
        local petSync = petInfo and get_pet_sync(petInfo.pet)
        if (petSync) then
            local override_model = nil
            if (model_sync.forced_state == 'heal' and petSync.heal_model and petSync.heal_model > 0) then
                override_model = petSync.heal_model
            elseif (model_sync.forced_state == 'idle' and petSync.idle_model and petSync.idle_model > 0) then
                override_model = petSync.idle_model
            end
            if (override_model) then
                ashita.bits.pack_be(e.data_modified_raw, override_model, 0x32, 0, 16)
            end
        end
    end

    -- Cache the final packet bytes for patched pets so we can replay with different models
    if (patchedPets[entSid] and subKind == 0) then
        local cached = {}
        for i = 1, e.size do
            cached[i] = struct.unpack('B', e.data_modified, i)
        end
        lastPetPacket[entSid] = cached
    end

end)

------------------------------------------------------------
-- Animation Patching (0x0028)
------------------------------------------------------------
ashita.events.register('packet_in', 'upets_animation_packet', function (e)
    if (e.id ~= 0x0028) then return end

	-- Initialize Packet Reading 
	-- We need to consume/read the packet and log data as we go
	-- Credit: Thorny
		local subkind
		local bitData
		local bitOffset
		local actionPacket = T{}

		local function UnpackBits(length)
			local value = ashita.bits.unpack_be(bitData, 0, bitOffset, length)
			bitOffset = bitOffset + length
			return value
		end

		bitData = e.data_raw
		bitOffset = 40

		local serverId = UnpackBits(32)
		local targetCount = UnpackBits(6)  -- trg_sum
		UnpackBits(4)  -- res_sum
		local cmd_no = UnpackBits(4)
		local cmd_arg = UnpackBits(32)
		local cmd_argOffset = bitOffset-32
		local recast = UnpackBits(32);
	-- END Initialize Packet Reading

    -- Only pets whose models were patched
    if (not patchedPets[serverId]) then return end

	local petInfo = patchedPets[serverId]
	if (not petInfo) then return end

    if (debug_mode) then
        print(string.format('[UniquePets] Action: cmd_no=%d (%s) cmd_arg=%d targets=%d pet=%s',
            cmd_no, get_action_name(cmd_no), cmd_arg, targetCount, petInfo.pet or '?'))
    end

    -- Advanced per-pet override: match rules by cmd_arg (works regardless of global patching)
    if (config.advanced_patching == 1) then
        local rules = get_pet_rules(petInfo)
        local rule = find_matching_rule(rules, cmd_arg, cmd_no)

        if (rule) then
            if (debug_mode) then
                print(string.format('[UniquePets] MATCHED rule: match=%s from=%d to=%d action_id=%s',
                    tostring(rule.match or 'anim'), rule.from, rule.to, tostring(rule.action_id or rule.spell_id)))
            end
            local target_anim = rule.to
            local action_id = rule.action_id or rule.spell_id

            if (target_anim == 1) then
                ashita.bits.pack_be(e.data_modified_raw, 812348513, 0, cmd_argOffset, 32)
            elseif (action_id) then
                ashita.bits.pack_be(e.data_modified_raw, action_id, 0, cmd_argOffset, 32)
            end

            -- Spells and monster skills need per-target Animation injection
            if (target_anim == 4 or target_anim == 7 or target_anim == 11) then
                local anim_inject = action_id or 1

                actionPacket.Targets = T{}
                for i = 1, targetCount do
                    local target = T{}
                    target.Id = UnpackBits(32)
                    local actionCount = UnpackBits(4)
                    target.Actions = T{}
                    for j = 1, actionCount do
                        local action = {}
                        action.Reaction = UnpackBits(5)
                        action.Animation = UnpackBits(12)

                        subkind = bitOffset - 12
                        ashita.bits.pack_be(e.data_modified_raw, anim_inject, 0, subkind, 12)

                        action.SpecialEffect = UnpackBits(7)
                        action.Knockback = UnpackBits(3)
                        action.Param = UnpackBits(17)
                        action.Message = UnpackBits(10)
                        action.Flags = UnpackBits(31)

                        local hasAdditionalEffect = (UnpackBits(1) == 1)
                        if hasAdditionalEffect then
                            UnpackBits(10)
                            UnpackBits(17)
                            UnpackBits(10)
                        end

                        local hasSpikesEffect = (UnpackBits(1) == 1)
                        if hasSpikesEffect then
                            UnpackBits(10)
                            UnpackBits(14)
                            UnpackBits(10)
                        end

                        target.Actions:append(action)
                    end
                    actionPacket.Targets:append(target)
                end
            end

            ashita.bits.pack_be(e.data_modified_raw, target_anim, 82, 4)
            return
        end
    end

    -- Global fallback patching (requires is_patching)
    if (config.is_patching == 0) then return end

    local anim_name = get_action_name(cmd_no)
	local matches_target = 13
	if (config.anim_to_patch ~= 0) then
		matches_target = config.anim_to_patch
	end
	
    if (string.find(anim_name, 'Unknown') or cmd_no == matches_target) then
        if (config.anim_value == 1) then
				ashita.bits.pack_be(e.data_modified_raw, 812348513, 0, cmd_argOffset, 32)
			end
        ashita.bits.pack_be(e.data_modified_raw, config.anim_value, 82, 4)
    end
end)


------------------------------------------------------------
-- UI
------------------------------------------------------------

local ui_player = { '' }
local ui_pet    = { '' }
local ui_model  = { '' }
ashita.events.register('d3d_present', 'upets_ui', function ()

    -- Model sync: per-pet idle/combat/heal model transitions
    if (model_sync.enabled) then
        local me = GetPlayerEntity()
        if (me) then
            local myStatus = me.Status
            local pet, petIdx = get_pet_entity()

            if (pet and petIdx and patchedPets[pet.ServerId]) then
                local petInfo = patchedPets[pet.ServerId]
                local petSync = get_pet_sync(petInfo.pet)
                local idleModel = petSync and petSync.idle_model
                local healModel = petSync and petSync.heal_model

                if (idleModel or healModel) then
                    local combatModel = find_with_wildcards(
                        petInfo.is_local and config.local_player or
                        (config.players[petInfo.owner] or {}),
                        petInfo.pet)

                    local desired_state
                    if (myStatus == 33) then
                        desired_state = (healModel and healModel > 0) and 'heal' or nil
                    elseif (myStatus == 1) then
                        desired_state = 'combat'
                    else
                        desired_state = (idleModel and idleModel > 0) and 'idle' or nil
                    end

                    if (model_sync.swap_time and (os.clock() - model_sync.swap_time) < 3.0) then
                        desired_state = 'heal'
                    elseif (model_sync.swap_time) then
                        model_sync.swap_time = nil
                    end

                    local desired_model
                    if (desired_state == 'heal') then
                        desired_model = healModel
                    elseif (desired_state == 'idle') then
                        desired_model = idleModel
                    elseif (desired_state == 'combat' and combatModel) then
                        desired_model = combatModel
                    end

                    if (desired_model) then
                        if (model_sync.forced_state ~= desired_state) then
                            pet.Look.Hair = desired_model
                            pet.ModelUpdateFlags = 0x10
                            model_sync.forced_state = desired_state
                        elseif (pet.Look.Hair ~= desired_model) then
                            pet.Look.Hair = desired_model
                        end
                    end
                end
            elseif (model_sync.forced_state) then
                model_sync.forced_state = nil
            end
        end
    end

    if (not show_ui) then return end

    if (not local_player_name) then
        local me = GetPlayerEntity()
        if (me and me.Name) then
            local_player_name = me.Name
        end
    end

    imgui.SetNextWindowSize({ 620, 440 }, ImGuiCond_FirstUseEver)

    local open = { show_ui }
    if (not imgui.Begin('Unique Pets', open)) then
        show_ui = open[1]
        imgui.End()
        return
    end
    show_ui = open[1]

    if (imgui.BeginTabBar('upets_tabs')) then

        ----------------------------------------------------
        -- Your Pets
        ----------------------------------------------------
        if (imgui.BeginTabItem('Your Pets')) then
            for pet, model in pairs(config.local_player) do

                ui_local_models[pet] = ui_local_models[pet] or { tostring(model) }
				
                if (imgui.SmallButton('X##local_' .. pet)) then
                    config.local_player[pet] = nil
                    ui_local_models[pet] = nil
                    safe_settings_save()
                    break
                end
				
                imgui.SameLine()
				
                imgui.Text(pet)
                imgui.SameLine(200)
                imgui.SetNextItemWidth(80)
                imgui.InputText('##lm_' .. pet, ui_local_models[pet], 16)
				imgui.SameLine()
                if (imgui.SmallButton('Apply Model##lm_' .. pet)) then
                    local m = to_int(ui_local_models[pet][1])
                    if (m ~= nil) then
                        config.local_player[pet] = m
                        safe_settings_save()
                    end
                end

                if (model_sync.enabled) then
                    imgui.SameLine()
                    config.pet_model_sync = config.pet_model_sync or T{}
                    local pms = config.pet_model_sync[pet] or {}
                    ui_model_sync_bufs[pet] = ui_model_sync_bufs[pet] or {
                        idle = { tostring(pms.idle_model or '') },
                        heal = { tostring(pms.heal_model or '') },
                    }
                    local syncBuf = ui_model_sync_bufs[pet]
                    imgui.TextColored({ 0.5, 0.8, 1, 1 }, 'Idle:')
                    imgui.SameLine()
                    imgui.SetNextItemWidth(50)
                    imgui.InputText('##idle_' .. pet, syncBuf.idle, 16)
                    imgui.SameLine()
                    imgui.TextColored({ 0.5, 0.8, 1, 1 }, 'Heal:')
                    imgui.SameLine()
                    imgui.SetNextItemWidth(50)
                    imgui.InputText('##heal_' .. pet, syncBuf.heal, 16)
                    imgui.SameLine()
                    if (imgui.SmallButton('Set##sync_' .. pet)) then
                        local idleVal = to_int(syncBuf.idle[1])
                        local healVal = to_int(syncBuf.heal[1])
                        if (idleVal or healVal) then
                            config.pet_model_sync[pet] = {
                                idle_model = idleVal or 0,
                                heal_model = healVal or 0,
                            }
                        else
                            config.pet_model_sync[pet] = nil
                            ui_model_sync_bufs[pet] = nil
                        end
                        safe_settings_save()
                    end
                end

				if (config.advanced_patching == 1) then
                    config.pet_overrides = config.pet_overrides or T{}
                    config.pet_overrides.local_player = config.pet_overrides.local_player or T{}
                    local rules = config.pet_overrides.local_player[pet]

                    if (rules and #rules > 0) then
                        if (imgui.TreeNode('Rules##lr_' .. pet)) then
                            local del_idx = nil
                            if (imgui.BeginTable('lrules_' .. pet, 5,
                                    ImGuiTableFlags_Borders + ImGuiTableFlags_RowBg)) then
                                imgui.TableSetupColumn('', ImGuiTableColumnFlags_WidthFixed, 20)
                                imgui.TableSetupColumn('Match', ImGuiTableColumnFlags_WidthFixed, 50)
                                imgui.TableSetupColumn('From', ImGuiTableColumnFlags_WidthFixed, 70)
                                imgui.TableSetupColumn('To Action', ImGuiTableColumnFlags_WidthFixed, 120)
                                imgui.TableSetupColumn('Action ID', ImGuiTableColumnFlags_WidthFixed, 60)
                                imgui.TableHeadersRow()

                                for ri, rule in ipairs(rules) do
                                    imgui.TableNextRow()
                                    imgui.TableNextColumn()
                                    if (imgui.SmallButton('X##lrd_' .. pet .. '_' .. ri)) then
                                        del_idx = ri
                                    end
                                    imgui.TableNextColumn()
                                    local mtype = rule.match == 'action' and 'Action' or 'Anim'
                                    imgui.Text(mtype)
                                    imgui.TableNextColumn()
                                    if (rule.match == 'action') then
                                        imgui.Text(tostring(rule.from or 0) .. ' ' .. get_action_name(rule.from or 0))
                                    else
                                        imgui.Text(tostring(rule.from or 0))
                                    end
                                    imgui.TableNextColumn()
                                    imgui.Text(tostring(rule.to or 0) .. ' ' .. get_action_name(rule.to or 0))
                                    imgui.TableNextColumn()
                                    local aid = rule.action_id or rule.spell_id
                                    imgui.Text(aid and tostring(aid) or '-')
                                end

                                imgui.EndTable()
                            end

                                if (del_idx) then
                                    table.remove(rules, del_idx)
                                    safe_settings_save()
                                end

                                imgui.TreePop()
                            end
                        end

                    ui_override_add.local_player[pet] =
                        ui_override_add.local_player[pet] or { { '' }, { '' }, { '' }, 0 }
                    local bufs = ui_override_add.local_player[pet]
                    if (type(bufs[4]) ~= 'number') then bufs[4] = 0 end

                    local match_labels = { 'Anim', 'Action' }
					imgui.SetNextItemWidth(60)
                    if (imgui.BeginCombo('##lra_match_' .. pet, match_labels[bufs[4] + 1])) then
                        for mi = 0, 1 do
                            if (imgui.Selectable(match_labels[mi + 1], bufs[4] == mi)) then
                                bufs[4] = mi
                            end
                        end
                        imgui.EndCombo()
                    end
                    imgui.SameLine()
                    imgui.SetNextItemWidth(60)
                    imgui.InputText('##lra_from_' .. pet, bufs[1], 8, ImGuiInputTextFlags_CharsDecimal)
                    imgui.SameLine()
                    imgui.SetNextItemWidth(40)
                    imgui.InputText('##lra_to_' .. pet, bufs[2], 8, ImGuiInputTextFlags_CharsDecimal)
                    imgui.SameLine()
                    imgui.SetNextItemWidth(50)
                    imgui.InputText('##lra_sp_' .. pet, bufs[3], 8, ImGuiInputTextFlags_CharsDecimal)
                    imgui.SameLine()
                    if (imgui.SmallButton('+##lra_' .. pet)) then
                        local from_v = to_int(bufs[1][1])
                        local to_v = to_int(bufs[2][1])
                        if (from_v and to_v) then
                            config.pet_overrides.local_player[pet] =
                                config.pet_overrides.local_player[pet] or {}
                            local new_rule = { from = from_v, to = to_v }
                            if (bufs[4] == 1) then new_rule.match = 'action' end
                            local aid = to_int(bufs[3][1])
                            if (aid) then new_rule.action_id = aid end
                            local replaced = false
                            for ri, r in ipairs(config.pet_overrides.local_player[pet]) do
                                if (r.from == new_rule.from and r.match == new_rule.match) then
                                    config.pet_overrides.local_player[pet][ri] = new_rule
                                    replaced = true
                                    break
                                end
                            end
                            if (not replaced) then
                                table.insert(config.pet_overrides.local_player[pet], new_rule)
                            end
                            safe_settings_save()
                            bufs[1][1] = ''
                            bufs[2][1] = ''
                            bufs[3][1] = ''
                        end
                    end
                    imgui.SameLine()
                    imgui.TextColored({ 0.5, 0.5, 0.5, 1 }, 'match / from / to / action')
                end
				
            end

            imgui.Separator()
            imgui.InputText('Pet Name', ui_pet, 32)
            imgui.InputText('Model', ui_model, 16)

            if (imgui.Button('Add New Pet')) then
                local m = to_int(ui_model[1])
                if (ui_pet[1] ~= '' and m) then
                    config.local_player[ui_pet[1]] = m
                    ui_local_models[ui_pet[1]] = { tostring(m) }
                    safe_settings_save()
                    ui_pet[1]   = ''
                    ui_model[1] = ''
                end
            end

            imgui.EndTabItem()
        end

        ----------------------------------------------------
        -- Other Players
        ----------------------------------------------------
        if (imgui.BeginTabItem('Other Players')) then
            local players = config.players:keys()

            for i = 1, #players do
                local pname = players[i]
                ui_remote_models[pname] = ui_remote_models[pname] or {}

                if (imgui.TreeNode(pname)) then
                    local pets = config.players[pname]:keys()

                    for j = 1, #pets do
                        local pet = pets[j]
                        local model = config.players[pname][pet]

                        ui_remote_models[pname][pet] =
                            ui_remote_models[pname][pet] or { tostring(model) }

                        if (imgui.SmallButton('X##' .. pname .. '_' .. pet)) then
                            config.players[pname][pet] = nil
                            ui_remote_models[pname][pet] = nil
                            safe_settings_save()
                            break
                        end
                        imgui.SameLine()
						
                        imgui.Text(pet)
                        imgui.SameLine(200)
                        imgui.SetNextItemWidth(80)
                        imgui.InputText(
                            '##rm_' .. pname .. '_' .. pet,
                            ui_remote_models[pname][pet],
                            16
                        )

						imgui.SameLine()
                        if (imgui.SmallButton('Apply Model##rm_' .. pname .. '_' .. pet)) then
                            local m = to_int(ui_remote_models[pname][pet][1])
                            if (m ~= nil) then
                                config.players[pname][pet] = m
                                safe_settings_save()
                            end
                        end
                        

					if (config.advanced_patching == 1) then
                        config.pet_overrides = config.pet_overrides or T{}
                        config.pet_overrides.players = config.pet_overrides.players or T{}
                        config.pet_overrides.players[pname] = config.pet_overrides.players[pname] or T{}
                        local rules = config.pet_overrides.players[pname][pet]

                        if (rules and #rules > 0) then
                            if (imgui.TreeNode('Rules##rr_' .. pname .. '_' .. pet)) then
                                local del_idx = nil
                                if (imgui.BeginTable('rrules_' .. pname .. '_' .. pet, 5,
                                        ImGuiTableFlags_Borders + ImGuiTableFlags_RowBg)) then
                                    imgui.TableSetupColumn('', ImGuiTableColumnFlags_WidthFixed, 20)
                                    imgui.TableSetupColumn('Match', ImGuiTableColumnFlags_WidthFixed, 50)
                                    imgui.TableSetupColumn('From', ImGuiTableColumnFlags_WidthFixed, 70)
                                    imgui.TableSetupColumn('To Action', ImGuiTableColumnFlags_WidthFixed, 120)
                                    imgui.TableSetupColumn('Action ID', ImGuiTableColumnFlags_WidthFixed, 60)
                                    imgui.TableHeadersRow()

                                    for ri, rule in ipairs(rules) do
                                        imgui.TableNextRow()
                                        imgui.TableNextColumn()
                                        if (imgui.SmallButton('X##rrd_' .. pname .. '_' .. pet .. '_' .. ri)) then
                                            del_idx = ri
                                        end
                                        imgui.TableNextColumn()
                                        local mtype = rule.match == 'action' and 'Action' or 'Anim'
                                        imgui.Text(mtype)
                                        imgui.TableNextColumn()
                                        if (rule.match == 'action') then
                                            imgui.Text(tostring(rule.from or 0) .. ' ' .. get_action_name(rule.from or 0))
                                        else
                                            imgui.Text(tostring(rule.from or 0))
                                        end
                                        imgui.TableNextColumn()
                                        imgui.Text(tostring(rule.to or 0) .. ' ' .. get_action_name(rule.to or 0))
                                        imgui.TableNextColumn()
                                        local aid = rule.action_id or rule.spell_id
                                        imgui.Text(aid and tostring(aid) or '-')
                                    end

                                    imgui.EndTable()
                                end

                                if (del_idx) then
                                    table.remove(rules, del_idx)
                                    safe_settings_save()
                                end

                                imgui.TreePop()
                            end
                        end

                        ui_override_add.players[pname] = ui_override_add.players[pname] or {}
                        ui_override_add.players[pname][pet] =
                            ui_override_add.players[pname][pet] or { { '' }, { '' }, { '' }, 0 }
                        local bufs = ui_override_add.players[pname][pet]
                        if (type(bufs[4]) ~= 'number') then bufs[4] = 0 end

                        local match_labels = { 'Anim', 'Action' }
						imgui.SetNextItemWidth(60)
                        if (imgui.BeginCombo('##rra_match_' .. pname .. '_' .. pet, match_labels[bufs[4] + 1])) then
                            for mi = 0, 1 do
                                if (imgui.Selectable(match_labels[mi + 1], bufs[4] == mi)) then
                                    bufs[4] = mi
                                end
                            end
                            imgui.EndCombo()
                        end
                        imgui.SameLine()
                        imgui.SetNextItemWidth(60)
                        imgui.InputText('##rra_from_' .. pname .. '_' .. pet, bufs[1], 8, ImGuiInputTextFlags_CharsDecimal)
                        imgui.SameLine()
                        imgui.SetNextItemWidth(40)
                        imgui.InputText('##rra_to_' .. pname .. '_' .. pet, bufs[2], 8, ImGuiInputTextFlags_CharsDecimal)
                        imgui.SameLine()
                        imgui.SetNextItemWidth(50)
                        imgui.InputText('##rra_sp_' .. pname .. '_' .. pet, bufs[3], 8, ImGuiInputTextFlags_CharsDecimal)
                        imgui.SameLine()
                        if (imgui.SmallButton('+##rra_' .. pname .. '_' .. pet)) then
                            local from_v = to_int(bufs[1][1])
                            local to_v = to_int(bufs[2][1])
                            if (from_v and to_v) then
                                config.pet_overrides.players[pname][pet] =
                                    config.pet_overrides.players[pname][pet] or {}
                                local new_rule = { from = from_v, to = to_v }
                                if (bufs[4] == 1) then new_rule.match = 'action' end
                                local aid = to_int(bufs[3][1])
                                if (aid) then new_rule.action_id = aid end
                                local replaced = false
                                for ri, r in ipairs(config.pet_overrides.players[pname][pet]) do
                                    if (r.from == new_rule.from and r.match == new_rule.match) then
                                        config.pet_overrides.players[pname][pet][ri] = new_rule
                                        replaced = true
                                        break
                                    end
                                end
                                if (not replaced) then
                                    table.insert(config.pet_overrides.players[pname][pet], new_rule)
                                end
                                safe_settings_save()
                                bufs[1][1] = ''
                                bufs[2][1] = ''
                                bufs[3][1] = ''
                            end
                        end
                        imgui.SameLine()
                        imgui.TextColored({ 0.5, 0.5, 0.5, 1 }, 'match / from / to / action')
                    end
						
                    end 

                    imgui.Separator()
                    if (imgui.SmallButton('Delete Player##' .. pname)) then
                        config.players[pname] = nil
                        ui_remote_models[pname] = nil
                        safe_settings_save()
                        imgui.TreePop()
                        break
                    end

                    imgui.TreePop()
                end
            end --End: Advanced Patching

            imgui.Separator()
            imgui.InputText('Player', ui_player, 32)
            imgui.InputText('Pet', ui_pet, 32)
            imgui.InputText('Model', ui_model, 16)

            if (imgui.Button('Add New Player Pet')) then
                local m = to_int(ui_model[1])
                if (ui_player[1] ~= '' and ui_pet[1] ~= '' and m) then
                    config.players[ui_player[1]] = config.players[ui_player[1]] or T{}
                    config.players[ui_player[1]][ui_pet[1]] = m
                    ui_remote_models[ui_player[1]] = ui_remote_models[ui_player[1]] or {}
                    ui_remote_models[ui_player[1]][ui_pet[1]] = { tostring(m) }
                    safe_settings_save()
                    ui_player[1] = ''
                    ui_pet[1]    = ''
                    ui_model[1]  = ''
                end
            end

            imgui.EndTabItem()
        end

        ----------------------------------------------------
        -- Export / Import
        ----------------------------------------------------
        if (imgui.BeginTabItem('Export / Import')) then
            imgui.Text('[Your Pets]')
            imgui.Separator()
            imgui.Text('Note: All Export/Imports create and use')
            imgui.Text('files in your UniquePets addon install folder.')
            imgui.Separator()            

            if (imgui.Button('Export Your Pets')) then
                if (local_player_name) then
                    config.pet_overrides = config.pet_overrides or T{}
					write_export(local_player_name .. '_Export.lua', T{
						players = T{
							[local_player_name] = T{
								models = config.local_player,
                                overrides = config.pet_overrides.local_player or T{},
							}
						},
						animation_settings = T{
							is_patching = config.is_patching,
							anim_value = config.anim_value,
							anim_to_patch = config.anim_to_patch,
							advanced_patching = config.advanced_patching,
						}
					})
                end
            end

            if (imgui.Button('Import Your Pets')) then
                local data = load_import(local_player_name .. '_Export.lua')
                if (data) then
                    local pname, models, overrides = validate_single_player_import(data)
					if (pname) then
						config.local_player = models or T{}

                        config.pet_overrides = config.pet_overrides or T{}
                        config.pet_overrides.local_player = overrides or T{}

						if (type(data.animation_settings) == 'table') then
							config.is_patching = data.animation_settings.is_patching or config.is_patching
							config.anim_value = data.animation_settings.anim_value or config.anim_value
							config.anim_to_patch = data.animation_settings.anim_to_patch or config.anim_to_patch
							config.advanced_patching = data.animation_settings.advanced_patching or config.advanced_patching
						end

						ui_local_models = {}
						safe_settings_save()
					end
                end
            end

            imgui.Spacing()
            imgui.Separator()
            imgui.Text('[Other Players Pets]')
            imgui.Separator()
            imgui.Text('Note: This will use your OtherPets_Export.lua file')
            imgui.Text('and overwrite your pets in the Other Players tab.')
            imgui.Separator()
            if (imgui.Button('Export All Other Players')) then
                config.pet_overrides = config.pet_overrides or T{}
				write_export('OtherPets_Export.lua', T{
					players = T{
						models = config.players,
                        overrides = config.pet_overrides.players or T{},
					}
				})
            end

            imgui.Separator()
            if (imgui.Button('Import and Overwrite Other Pets')) then
                local data = load_import('OtherPets_Export.lua')
				if (data and type(data.players) == 'table') then
					if (data.players.models) then
						config.players = T(data.players.models)
                        config.pet_overrides = config.pet_overrides or T{}
                        config.pet_overrides.players = T(data.players.overrides or {})
					else
						config.players = T(data.players)
					end

					ui_remote_models = {}
					safe_settings_save()
				end
            end

            imgui.Separator()
            imgui.Text('[Import Single Other Player]')
            imgui.Separator()
											 
					
            imgui.InputText('Player Name', ui_player, 32)

            if (imgui.Button('Import Single Player')) then
                local data = load_import(ui_player[1] .. '_Export.lua')
                if (data) then
                    local pname, models, overrides = validate_single_player_import(data)
					if (pname) then
						config.players[pname] = models or T{}

                        config.pet_overrides = config.pet_overrides or T{}
                        config.pet_overrides.players = config.pet_overrides.players or T{}
                        config.pet_overrides.players[pname] = overrides or T{}

						ui_remote_models[pname] = {}
						safe_settings_save()
					end
                end
            end
            
            imgui.Separator()
            imgui.Text('Note: Just enter the player name.') 
            imgui.Text('So if "Mazu_Export.Lua" is the file, enter just "Mazu"')

            imgui.EndTabItem()
        end

        ----------------------------------------------------
        -- Animation Patching
        ----------------------------------------------------
        if (imgui.BeginTabItem('Animation Patching')) then
            imgui.Text('Animation override controls')
            imgui.Separator()

            -- Patch Animation Dropdown
            imgui.Text('Patch Animation')
            local current_label = bool_labels[config.is_patching + 1]
            if (imgui.BeginCombo('##is_patching', current_label)) then
                for i = 1, #bool_labels do
                    local is_selected = (config.is_patching == i - 1)
                    if (imgui.Selectable(bool_labels[i], is_selected)) then
                        config.is_patching = i - 1
                        safe_settings_save()
                    end
                end
                imgui.EndCombo()
            end

            imgui.Spacing()

            -- Animation Value
            imgui.Text('Animation ID')
            imgui.SetNextItemWidth(100)
            
			
            if (imgui.InputText('##anim_val_input', ui_buffers.anim_val_input, 8, ImGuiInputTextFlags_CharsDecimal)) then
                config.anim_value = tonumber(ui_buffers.anim_val_input[1]) or 0
                safe_settings_save()
            end
			imgui.Text('Note: New ID to patch bad actions with.')
            imgui.Spacing()
            imgui.Separator()

            -- Optional animation to patch
            imgui.Text('[OPTIONAL] Additional Action to Replace')
            imgui.SetNextItemWidth(100)
   
            
            if (imgui.InputText('##anim_to_patch_input', ui_buffers.anim_to_patch_input, 8, ImGuiInputTextFlags_CharsDecimal)) then
                config.anim_to_patch = tonumber(ui_buffers.anim_to_patch_input[1]) or 0
                safe_settings_save()
            end
            
            imgui.Text('Note: Another action ID to patch with Animation ID above.')
            
            -- Reference/Derived Values
            --local active = (config.is_patching == 1)
            --imgui.Text(('Active: %s'):format(active and 'YES' or 'NO'))
            --imgui.Text(('Value: %d'):format(config.anim_value))
            
            imgui.Separator()
            imgui.Spacing()

            imgui.Text('Animation/Action ID:')
            imgui.Text('0: No animation')
			imgui.Text('1: Attack')
            imgui.Text('2: Ranged Attack (Finish)')
            imgui.Text('3: Weaponskill (Finish)')
            imgui.Text('4: Magic/Spell (Finish)')
            imgui.Text('5: Item (Finish)')
            imgui.Text('6: Job Ability (Finish)')
            imgui.Text('7: Monster WS (Start)')
			imgui.Text('8: Magic (Start)')
			imgui.Text('9: Item (Start)')
			imgui.Text('10: Job Ability (Start)')
            imgui.Text('11: Monster Skill')
            imgui.Text('12: Range Attack (Start)')
            imgui.Text('13: Unknown/Avatar BP')
            imgui.Text('14: Dancer')
            imgui.Text('15: Rune Fencer')
            imgui.Text('Note: Not all animations/actions work. Experiment!')
 
			imgui.Separator()
            imgui.Spacing()
			
			imgui.Text('Advanced Patching')
			local adv_label = bool_labels[config.advanced_patching + 1]
			if (imgui.BeginCombo('##advanced_patching', adv_label)) then
				for i = 1, #bool_labels do
					local sel = (config.advanced_patching == i - 1)
					if (imgui.Selectable(bool_labels[i], sel)) then
						config.advanced_patching = i - 1
						safe_settings_save()
					end
				end
				imgui.EndCombo()
			end

			imgui.Text('Note: Enables individual patching for EACH pet.')      

            imgui.EndTabItem()
        end

        ----------------------------------------------------
        -- Model Sync
        ----------------------------------------------------
        if (imgui.BeginTabItem('Model Sync')) then
            imgui.TextColored({ 0.4, 0.8, 1, 1 },
                'Swap pet models based on player state (idle/combat/heal)')
            imgui.TextColored({ 0.6, 0.6, 0.6, 1 },
                'Configure idle and heal models per pet in the Your Pets tab.')
            imgui.Separator()
            imgui.Spacing()

            local ms_enabled = { model_sync.enabled or false }
            if (imgui.Checkbox('Enable Model Sync', ms_enabled)) then
                model_sync.enabled = ms_enabled[1]
                config.model_sync_enabled = model_sync.enabled
                safe_settings_save()
            end

            imgui.Spacing()
            imgui.Separator()

            imgui.Text('Current State:')
            imgui.SameLine()
            if (not model_sync.enabled) then
                imgui.TextColored({ 0.5, 0.5, 0.5, 1 }, 'Disabled')
            elseif (model_sync.forced_state == 'heal') then
                imgui.TextColored({ 0.4, 1, 0.4, 1 }, 'Healing')
            elseif (model_sync.forced_state == 'idle') then
                imgui.TextColored({ 0.6, 0.8, 1, 1 }, 'Idle')
            elseif (model_sync.forced_state == 'combat') then
                imgui.TextColored({ 1, 0.8, 0.4, 1 }, 'Combat')
            else
                imgui.TextColored({ 0.5, 1, 0.5, 1 }, 'Ready')
            end

            -- Show current pet's sync config
            local pet, petIdx = get_pet_entity()
            if (pet and patchedPets[pet.ServerId]) then
                local petInfo = patchedPets[pet.ServerId]
                local petSync = get_pet_sync(petInfo.pet)
                imgui.Spacing()
                imgui.Text(string.format('Active Pet: %s', petInfo.pet))
                if (petSync) then
                    local cm = find_with_wildcards(
                        petInfo.is_local and config.local_player or
                        (config.players[petInfo.owner] or {}),
                        petInfo.pet)
                    if (cm) then
                        imgui.TextColored({ 1, 0.8, 0.4, 1 },
                            string.format('  Combat: %d', cm))
                    end
                    if (petSync.idle_model and petSync.idle_model > 0) then
                        imgui.TextColored({ 0.5, 0.8, 1, 1 },
                            string.format('  Idle: %d', petSync.idle_model))
                    end
                    if (petSync.heal_model and petSync.heal_model > 0) then
                        imgui.TextColored({ 0.4, 1, 0.4, 1 },
                            string.format('  Heal: %d', petSync.heal_model))
                    end
                else
                    imgui.TextColored({ 0.6, 0.6, 0.6, 1 },
                        '  No idle/heal models configured for this pet.')
                end
            end

            imgui.Spacing()
            imgui.Separator()
            imgui.Spacing()
            imgui.TextColored({ 0.6, 0.6, 0.6, 1 },
                '/upets modelsync  -  toggle on/off')

            imgui.EndTabItem()
        end


        imgui.EndTabBar()
    end

    imgui.End()
end)
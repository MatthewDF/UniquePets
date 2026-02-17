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
    pet_anim_overrides = {
        local_player = T{},
        players = T{},
    },
	
	pet_spell_overrides = {
		local_player = T{},
		players = T{},
	}	
}

local config = settings.load(default_settings)

-- UI Buffers (Initialized empty, synced in settings_update)
local ui_buffers = {
    anim_val_input      = { tostring(config.anim_value or 0) },
    anim_to_patch_input = { tostring(config.anim_to_patch or 0) }
}

local function settings_update(s)
    if (s ~= nil and type(s) == 'table') then
        config = s
        -- Keep UI buffers in sync with the loaded file
        ui_buffers.anim_val_input[1] = tostring(config.anim_value or 0)
        ui_buffers.anim_to_patch_input[1] = tostring(config.anim_to_patch or 0)
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

------------------------------------------------------------
-- Misc
------------------------------------------------------------

local bool_labels = { 'False', 'True' }

------------------------------------------------------------
-- UI Edit Buffers
------------------------------------------------------------

local ui_local_models  = {}
local ui_remote_models = {}

local ui_anim_override_buffers = {
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

    -- Backwards compatibility: old format (pet = model)
    if (next(entry) and type(entry[next(entry)]) == 'number') then
        return pname, T(entry), T{}, T{}
    end

    -- New extended format
    return pname,
           T(entry.models or {}),
           T(entry.anim_overrides or {}),
           T(entry.spell_overrides or {})
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

------------------------------------------------------------
-- Commands
------------------------------------------------------------

addon.commands = { '/uniquepets', '/upets' }

ashita.events.register('command', 'upets_command', function (e)
    local a = e.command:args()
    if (#a == 0) then return end

    if (a[1] == '/uniquepets' or a[1] == '/upets') then
        e.blocked = true
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

    local subKind = bit.band(struct.unpack('H', e.data, 0x31), 0x07)
    if (subKind ~= 0) then return end

    local entityName = ent.Name
    local entSid     = struct.unpack('L', e.data, 0x05)

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
        return
    end

    -- Remote pet
    local ownerAct = remotePets.byPetActIndex[actIndex]
    if (not ownerAct) then return end

    local ownerName = get_entity_name(ownerAct)
    if (not ownerName) then return end
	
    local playerCfg = find_with_wildcards(config.players, ownerName)
    if (not playerCfg) then return end

	local model = find_with_wildcards(playerCfg, entityName)
	
	if (model) then
		ashita.bits.pack_be(e.data_modified_raw, model, 0x32, 0, 16)
		patchedPets[entSid] = {
			pet      = entityName,
			owner    = ownerName,
			is_local = false,
		}
	end
end)

------------------------------------------------------------
-- Animation Patching (0x0028)
------------------------------------------------------------
ashita.events.register('packet_in', 'upets_animation_packet', function (e)
    if (e.id ~= 0x0028 or config.is_patching == 0) then return end

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

    local anim_name = get_action_name(cmd_no)
	local matches_target = 13
											
	if (config.anim_to_patch ~= 0) then
		matches_target = config.anim_to_patch
	end
	
	-- Advanced per-pet override
	if (config.advanced_patching == 1 and (cmd_no == 13 or cmd_no == matches_target)) then
		local override_anim = nil

		if (petInfo.is_local) then
			override_anim =
				find_with_wildcards(
					config.pet_anim_overrides.local_player,
					petInfo.pet
				)
		else
			local p = config.pet_anim_overrides.players[petInfo.owner]
			if (p) then
				override_anim = find_with_wildcards(p, petInfo.pet)
			end
		end

		if (override_anim and override_anim ~= 0) then
			
			-- If we're overriding for attacks, provide the cmd_arg info needed first
			if (override_anim == 1) then
				ashita.bits.pack_be(e.data_modified_raw, 812348513, 0, cmd_argOffset, 32)
			end
			
			-- Spell animation override
			if (override_anim == 4) then
				
				-- Collect spell id if provided
				local spell_id_inject = 1 -- default
				
				-- Spell ID Injection for spell casting animation
				local spell_overrides = config.pet_spell_overrides
				if (spell_overrides) then
					if (petInfo.is_local) then
						local t = spell_overrides.local_player
						if (t and t[petInfo.pet]) then
							spell_id_inject = t[petInfo.pet]
						end
					else
						local p = spell_overrides.players
						if (p and p[petInfo.owner]
							and p[petInfo.owner][petInfo.pet]) then
							spell_id_inject = p[petInfo.owner][petInfo.pet]
						end
					end
				end				
				
				-- Read through packet further to do animation injection
				actionPacket.Targets = T{};
				for i = 1,targetCount do
					local target = T{};
					target.Id = UnpackBits(32);
					local actionCount = UnpackBits(4);
					target.Actions = T{};
					for j = 1,actionCount do
						local action = {};
						action.Reaction = UnpackBits(5);
						action.Animation = UnpackBits(12);
						
						-- "Animation" here is also known as the sub_kind in this packet
						subkind = bitOffset-12
						
						-- We inject the spell ID into cmd_arg and sub_kind
						ashita.bits.pack_be(e.data_modified_raw, spell_id_inject, 0, cmd_argOffset, 32)
						
						ashita.bits.pack_be(e.data_modified_raw, spell_id_inject, 0, subkind, 12);
						
						action.SpecialEffect = UnpackBits(7);
						action.Knockback = UnpackBits(3);
						action.Param = UnpackBits(17);
						action.Message = UnpackBits(10);
						action.Flags = UnpackBits(31);
						
						local hasAdditionalEffect = (UnpackBits(1) == 1);
						if hasAdditionalEffect then
							local additionalEffect = {};
							additionalEffect.Damage = UnpackBits(10);
							additionalEffect.Param = UnpackBits(17);
							additionalEffect.Message = UnpackBits(10);
							action.AdditionalEffect = additionalEffect;
						end

						local hasSpikesEffect = (UnpackBits(1) == 1);
						if hasSpikesEffect then
							local spikesEffect = {};
							spikesEffect.Damage = UnpackBits(10);
							spikesEffect.Param = UnpackBits(14);
							spikesEffect.Message = UnpackBits(10);
							action.SpikesEffect = spikesEffect;
						end

						target.Actions:append(action);
					end
					actionPacket.Targets:append(target);
				end					
			end			
			
			ashita.bits.pack_be(e.data_modified_raw, override_anim, 82, 4)
			return
		end
	end
	
	if (string.find(anim_name, 'Unknown') or cmd_no == matches_target) then
		
		-- Patch animation

		-- If we're overriding for attacks, provide the cmd_arg info needed first
		if (override_anim == 1) then
			ashita.bits.pack_be(e.data_modified_raw, 812348513, 0, bitOffset-32, 32)
		end		
		
        ashita.bits.pack_be(e.data_modified_raw, config.anim_value, 82, 4)

        local actor_name = get_actor_name(serverId)
    end
end)


------------------------------------------------------------
-- UI
------------------------------------------------------------

local ui_player = { '' }
local ui_pet    = { '' }
local ui_model  = { '' }

ashita.events.register('d3d_present', 'upets_ui', function ()
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


				if (config.advanced_patching == 1) then
					ui_anim_override_buffers.local_player[pet] =
						ui_anim_override_buffers.local_player[pet]
						or { tostring(config.pet_anim_overrides.local_player[pet] or '') }

					imgui.SameLine()
					imgui.Text('|')
					imgui.SameLine()
					imgui.Text('Anim. ID:')
					imgui.SameLine()
					imgui.SetNextItemWidth(60)
					imgui.InputText(
						'##ua_' .. pet,
						ui_anim_override_buffers.local_player[pet],
						8,
						ImGuiInputTextFlags_CharsDecimal
					)

					if (imgui.IsItemDeactivatedAfterEdit()) then
						local raw = ui_anim_override_buffers.local_player[pet][1]
						local v = to_int(raw)

						if (raw == '' or v == nil) then
							config.pet_anim_overrides.local_player[pet] = nil
						else
							config.pet_anim_overrides.local_player[pet] = v
						end

						safe_settings_save()
					end

					-- NEW: Spell ID field when override == 4
					local current_override =
						to_int(ui_anim_override_buffers.local_player[pet][1])

					if (current_override == 4) then
						config.pet_spell_overrides = config.pet_spell_overrides or T{}
						config.pet_spell_overrides.local_player =
							config.pet_spell_overrides.local_player or T{}

						ui_spell_override_buffers = ui_spell_override_buffers or T{}
						ui_spell_override_buffers.local_player =
							ui_spell_override_buffers.local_player or T{}

						ui_spell_override_buffers.local_player[pet] =
							ui_spell_override_buffers.local_player[pet]
							or { tostring(
								config.pet_spell_overrides.local_player[pet] or ''
							)}
						imgui.SameLine()
						imgui.Text('|')
						imgui.SameLine()
						imgui.Text('Spell ID:')
						imgui.SameLine()
						imgui.SetNextItemWidth(70)
						imgui.InputText(
							'##us_' .. pet,
							ui_spell_override_buffers.local_player[pet],
							8,
							ImGuiInputTextFlags_CharsDecimal
						)

						if (imgui.IsItemDeactivatedAfterEdit()) then
							local v =
								to_int(ui_spell_override_buffers.local_player[pet][1])

							if (v == nil) then
								config.pet_spell_overrides.local_player[pet] = nil
							else
								config.pet_spell_overrides.local_player[pet] = v
							end

							safe_settings_save()
						end
					end					
					
				end --END: Advanced Patching
				
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
                        
					-- Advanced Patching	
					if (config.advanced_patching == 1) then
						ui_anim_override_buffers.players[pname] =
							ui_anim_override_buffers.players[pname] or {}

						ui_anim_override_buffers.players[pname][pet] =
							ui_anim_override_buffers.players[pname][pet]
							or { tostring(
								config.pet_anim_overrides.players[pname]
								and config.pet_anim_overrides.players[pname][pet]
								or ''
							)}

						imgui.SameLine()
						imgui.Text('|')
						imgui.SameLine()
						imgui.Text('Anim. ID:')
						imgui.SameLine()
						imgui.SetNextItemWidth(60)
						imgui.InputText(
							'##ua_' .. pname .. '_' .. pet,
							ui_anim_override_buffers.players[pname][pet],
							8,
							ImGuiInputTextFlags_CharsDecimal
						)

						if (imgui.IsItemDeactivatedAfterEdit()) then
							local raw = ui_anim_override_buffers.players[pname][pet][1]
							local v = to_int(raw)

							config.pet_anim_overrides.players[pname] =
								config.pet_anim_overrides.players[pname] or T{}

							if (raw == '' or v == nil) then
								config.pet_anim_overrides.players[pname][pet] = nil
							else
								config.pet_anim_overrides.players[pname][pet] = v
							end

							safe_settings_save()
						end

						-- NEW: Spell ID field when override == 4
						local current_override =
							to_int(ui_anim_override_buffers.players[pname][pet][1])

						if (current_override == 4) then
							config.pet_spell_overrides = config.pet_spell_overrides or T{}
							config.pet_spell_overrides.players =
								config.pet_spell_overrides.players or T{}

							config.pet_spell_overrides.players[pname] =
								config.pet_spell_overrides.players[pname] or T{}

							ui_spell_override_buffers = ui_spell_override_buffers or T{}
							ui_spell_override_buffers.players =
								ui_spell_override_buffers.players or T{}

							ui_spell_override_buffers.players[pname] =
								ui_spell_override_buffers.players[pname] or T{}

							ui_spell_override_buffers.players[pname][pet] =
								ui_spell_override_buffers.players[pname][pet]
								or { tostring(
									config.pet_spell_overrides.players[pname][pet] or ''
								)}

							imgui.SameLine()
							imgui.Text('|')
							imgui.SameLine()
							imgui.Text('Spell ID:')
							imgui.SameLine()
							imgui.SetNextItemWidth(70)
							imgui.InputText(
								'##us_' .. pname .. '_' .. pet,
								ui_spell_override_buffers.players[pname][pet],
								8,
								ImGuiInputTextFlags_CharsDecimal
							)

							if (imgui.IsItemDeactivatedAfterEdit()) then
								local v =
									to_int(ui_spell_override_buffers.players[pname][pet][1])

								if (v == nil) then
									config.pet_spell_overrides.players[pname][pet] = nil
								else
									config.pet_spell_overrides.players[pname][pet] = v
								end

								safe_settings_save()
							end
						end
						
					end	--END: Advanced Patching
						
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
					write_export(local_player_name .. '_Export.lua', T{
						players = T{
							[local_player_name] = T{
								models = config.local_player,
								anim_overrides = config.pet_anim_overrides.local_player,
								spell_overrides = config.pet_spell_overrides
													and config.pet_spell_overrides.local_player
													or T{},
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
					local pname, models, anims, spells = validate_single_player_import(data)
					if (pname) then
						config.local_player = models or T{}
						config.pet_anim_overrides.local_player = anims or T{}

						config.pet_spell_overrides = config.pet_spell_overrides or T{}
						config.pet_spell_overrides.local_player = spells or T{}

						-- Optional: import animation globals if present
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
				write_export('OtherPets_Export.lua', T{
					players = T{
						models = config.players,
						anim_overrides = config.pet_anim_overrides.players,
						spell_overrides = config.pet_spell_overrides
											and config.pet_spell_overrides.players
											or T{},
					}
				})
            end

            imgui.Separator()
            if (imgui.Button('Import and Overwrite Other Pets')) then
                local data = load_import('OtherPets_Export.lua')
				if (data and type(data.players) == 'table') then

					-- Backwards compatibility
					if (data.players.models) then
						config.players = T(data.players.models)
						config.pet_anim_overrides.players = T(data.players.anim_overrides or {})
						config.pet_spell_overrides = config.pet_spell_overrides or T{}
						config.pet_spell_overrides.players = T(data.players.spell_overrides or {})
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
					local pname, models, anims, spells = validate_single_player_import(data)
					if (pname) then
						config.players[pname] = models or T{}

						config.pet_anim_overrides.players[pname] =
							anims or T{}

						config.pet_spell_overrides = config.pet_spell_overrides or T{}
						config.pet_spell_overrides.players =
							config.pet_spell_overrides.players or T{}
						config.pet_spell_overrides.players[pname] =
							spells or T{}

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

        imgui.EndTabBar()
    end

    imgui.End()
end)
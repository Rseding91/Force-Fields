require "defines"

-- TODO:
--	refactor findentities calls to one function
--	fix mining emitters when someone has the GUI open


local loaded
local tickRate = 20
local toolName = "forcefield-tool"
local toolRadius = 0.1
local fieldSuffix = "-forcefield"
local fieldgateSuffix = "-forcefield-gate"
local fieldDamagedTriggerName = "forcefield-damaged"
local emitterName = "forcefield-emitter"
local maxRangeUpgrades = 23
local maxWidthUpgrades = 10
local widthUpgradeMultiplier = 4
local emitterDefaultDistance = 10
local emitterDefaultWidth = 25
local emitterMaxDistance = emitterDefaultDistance + maxRangeUpgrades
local emitterMaxWidth = emitterDefaultWidth + (maxWidthUpgrades * widthUpgradeMultiplier)
local defaultFieldType = "blue-forcefield"
local maxFieldDistance = math.max(emitterMaxDistance, emitterMaxWidth)

--[[
	chargeRate: tickRate * chargeRate = new field health generation per tick
	degradeRate: tickRate * degradeRate = health loss per tick when degrading
	respawnRate: tickRate * respawnRate = ticks between field respawn
	energyPerCharge: tickRate * energyPerCharge = energy used per initial health generation
	energyPerRespawn: tickRate * energyPerRespawn = energy per field respawn
	energyPerHealthLost: the amount of energy per health lost to regenerate the field per health lost once the field is fully generated
	damageWhenMined: damage dealt to the player mining a field
--]]

local forcefieldTypes =
{
	["blue" .. fieldSuffix] =
	{
		chargeRate = 0.2036111111111111,
		degradeRate = 2.777777777777778,
		respawnRate = 15,
		energyPerCharge = 4200,
		energyPerRespawn = 5000,
		energyPerHealthLost = 17000,
		damageWhenMined = 20
	},
	["green" .. fieldSuffix] =
	{
		chargeRate = 0.175,
		degradeRate = 2,
		respawnRate = 50,
		energyPerCharge = 4000,
		energyPerRespawn = 20000,
		energyPerHealthLost = 16000,
		damageWhenMined = 30
	},
	["purple" .. fieldSuffix] =
	{
		chargeRate = 0.2083333333333334,
		degradeRate = 3.333333333333333,
		respawnRate = 100,
		energyPerCharge = 7000,
		energyPerRespawn = 10000,
		energyPerHealthLost = 25000,
		damageWhenMined = 15,
		deathEntity = "forcefield-death-damage"
	},
	["red" .. fieldSuffix] =
	{
		chargeRate = 0.175,
		degradeRate = 4.333333333333333,
		respawnRate = 30,
		energyPerCharge = 10000,
		energyPerRespawn = 50000,
		energyPerHealthLost = 40000,
		damageWhenMined = 99
	}
}



remote.addinterface("forcefields", {
	test = function()
		for _,player in pairs(game.players) do
			transferToPlayer(player, {name = "forcefield-emitter", count = 50})
			transferToPlayer(player, {name = "forcefield-tool", count = 2})
			transferToPlayer(player, {name = "processing-unit", count = 50})
			transferToPlayer(player, {name = "advanced-circuit", count = 50})
		end
	end,
	reset = function()
		glob.emitters = nil
		glob.fields = nil
		glob.searchDamagedPos = nil
		glob.activeEmitters = nil
		glob.degradingFields = nil
		glob.ticking = nil
		glob.emitterConfigGUIs = nil
		game.onevent(defines.events.ontick, nil)
		local entities
		local minx = 0
		local miny = 0
		local maxx = 0
		local maxy = 0
		for coord in game.getchunks() do
			if coord.x < minx then
				minx = coord.x
			end
			if coord.x > maxx then
				maxx = coord.x
			end
			if coord.y < miny then
				miny = coord.y
			end
			if coord.y > maxy then
				maxy = coord.y
			end
		end
		minx = minx * 32
		maxx = maxx * 32
		miny = miny * 32
		maxy = maxy * 32
		for name in pairs(forcefieldTypes) do
			entities = game.findentitiesfiltered({area = {{minx, miny}, {maxx, maxy}}, name = name})
			for _,v in pairs(entities) do
				v.destroy()
			end
		end
		entities = game.findentitiesfiltered({area = {{minx, miny}, {maxx, maxy}}, name = emitterName})
		for _,v in pairs(entities) do
			v.destroy()
		end
		for _,player in pairs(game.players) do
			if player.gui.center.emitterConfig ~= nil then
				player.gui.center.emitterConfig.destroy()
			end
		end
	end
})

game.onevent(defines.events.onplayercreated, function(event)
	for _,player in pairs(game.players) do
		if player.gui.center.emitterConfig ~= nil then
			player.gui.center.emitterConfig.destroy()
		end
	end
	glob.emitterConfigGUIs = nil
end)

function throwError(what)
	for _,player in pairs(game.players) do
		player.print(what)
	end
end

function verifySettings()
	if tickRate < 0 then
		tickRate = 0
		throwError("Tick rate must be >= 0.")
	end
	
	if toolRadius < 0 then
		toolRadius = 0
		throwError("Tool radius must be >= 0.")
	end
	
	if emitterDefaultDistance < 1 then
		emitterDefaultDistance = 1
		emitterMaxDistance = emitterDefaultDistance + maxRangeUpgrades
		maxFieldDistance = math.max(emitterMaxDistance, emitterMaxWidth)
		throwError("Emitter default distance must be >= 1.")
	end
	
	if emitterDefaultWidth < 1 then
		emitterDefaultWidth = 1
		throwError("Emitter default width must be >= 1.")
		emitterMaxWidth = emitterDefaultWidth + (maxWidthUpgrades * widthUpgradeMultiplier)
		maxFieldDistance = math.max(emitterMaxDistance, emitterMaxWidth)
	elseif (math.floor((emitterDefaultWidth - 1) / 2) * 2) + 1 ~= emitterDefaultWidth then
		emitterDefaultWidth = 25
		throwError("Emitter default width must be an odd number (or one).")
		emitterMaxWidth = emitterDefaultWidth + (maxWidthUpgrades * widthUpgradeMultiplier)
		maxFieldDistance = math.max(emitterMaxDistance, emitterMaxWidth)
	end
	
	local entityPrototypes = game.entityprototypes
	for name,fieldTable in pairs(forcefieldTypes) do
		if entityPrototypes[name] ~= nil then
			fieldTable["maxHealth"] = entityPrototypes[name].maxhealth
		else
			throwError("Invalid field name defined - no matching prototype exists: " .. name)
		end
	end
	
	if not forcefieldTypes[defaultFieldType] then
		defaultFieldType = "blue" .. fieldSuffix
		throwError("Emitter default field type isn't known.")
	end
end

function onload()
	if not loaded then
		loaded = true
		if glob.ticking then
			game.onevent(defines.events.ontick, ticker)
		end
		verifySettings()
		glob.version = 1.0
	end
end

game.onload(onload)
game.oninit(onload)

game.onevent(defines.events.onpreplayermineditem, function(event)
	if forcefieldTypes[event.entity.name] ~= nil then
		onForcefieldMined(event.entity, event.playerindex)
	elseif event.entity.name == emitterName then
		onEmitterMined(event.entity, event.playerindex)
	end
end)

game.onevent(defines.events.onrobotpremined, function(event)
	if event.entity.name == emitterName then
		onEmitterMined(event.entity)
	end
end)

game.onevent(defines.events.onentitydied, function(event)
	if forcefieldTypes[event.entity.name] ~= nil then
		onForcefieldDied(event.entity)
	elseif event.entity.name == emitterName then
		onEmitterDied(event.entity)
	end
end)

game.onevent(defines.events.onmarkedfordeconstruction, function(event)
	if event.entity.name == emitterName then
		local emitterTable = findEmitter(event.entity)
		if emitterTable ~= nil then
			emitterTable["14"] = true
			degradeLinkedFields(emitterTable)
		end
	end
end)

game.onevent(defines.events.oncanceleddeconstruction, function(event)
	if event.entity.name == emitterName then
		local emitterTable = findEmitter(event.entity)
		if emitterTable ~= nil then
			emitterTable["14"] = false
			setActive(emitterTable, true)
		end
	end
end)

function transferToPlayer(player, dropStack)
	local countBefore = player.getitemcount(dropStack.name)
	local countAfter
	
	player.insert(dropStack)
	countAfter = player.getitemcount(dropStack.name)
	if countAfter < (countBefore + dropStack.count) then
		dropOnGround(player.position, {name = dropStack.name, count = (countBefore + dropStack.count) - countAfter})
	end
end

function dropOnGround(position, dropStack, markForDeconstruction)
	local dropPos
	local entity
	for n=1,dropStack.count do
		dropPos = game.findnoncollidingposition("item-on-ground", position, 50, 0.5)
		if dropPos then
			entity = game.createentity({name = "item-on-ground", position = dropPos, stack = {name = dropStack.name, count = 1}})
			if markForDeconstruction then
				entity.orderdeconstruction(game.players[1].force)
			end
		end
	end
end

function storeKilledEmitter(emitterTable)
	local newKilledEmitter = {}
	if glob.killedEmitters == nil then
		glob.killedEmitters = {}
	end
	newKilledEmitter["1"] = emitterTable["1"].position
	newKilledEmitter["2"] = emitterTable["6"]
	newKilledEmitter["3"] = emitterTable["7"]
	newKilledEmitter["4"] = emitterTable["9"]
	newKilledEmitter["5"] = emitterTable["10"]
	table.insert(glob.killedEmitters, newKilledEmitter)
end

function removeKilledEmitter(index)
	table.remove(glob.killedEmitters, index)
	if #glob.killedEmitters == 0 then
		glob.killedEmitters = nil
	end
end

function onEmitterDied(emitter)
	local emitterTable = findEmitter(emitter)
	if emitterTable ~= nil then
		removeEmitterID(emitterTable["5"])
		storeKilledEmitter(emitterTable)
	end
end

function onEmitterMined(emitter, playerIndex)
	local emitterTable = findEmitter(emitter)
	local player
	
	if emitterTable ~= nil then
		removeEmitterID(emitterTable["5"])
	end
	if playerIndex then
		player = game.players[playerIndex]
	end
	
	if emitterTable["12"] ~= 0 then
		if player then
			transferToPlayer(player, {name = "advanced-circuit", count = emitterTable["12"]})
		else
			dropOnGround(emitterTable["1"].position, {name = "advanced-circuit", count = emitterTable["12"]}, true)
		end
	end
	if emitterTable["13"] ~= 0 then
		if player then
			transferToPlayer(player, {name = "processing-unit", count = emitterTable["13"]})
		else
			dropOnGround(emitterTable["1"].position, {name = "processing-unit", count = emitterTable["13"]}, true)
		end
	end
end

function onForcefieldMined(field, playerindex)
	if playerindex ~= nil then
		local player = game.players[playerindex]
		if player.character ~= nil then
			player.character.damage(forcefieldTypes[field.name]["damageWhenMined"], game.forces.player)
		end
	end
	if glob.fields ~= nil then
		local pos = field.position
		if glob.fields[pos.x] ~= nil and glob.fields[pos.x][pos.y] ~= nil then
			local emitterTable = glob.emitters[glob.fields[pos.x][pos.y]]
			if emitterTable then
				setActive(emitterTable, true)
			end
			removeForceFieldID(pos.x, pos.y)
		end
	end
end

function tableIsEmpty(t)
	if t then
		for k in pairs(t) do
			return false
		end
	end
	return true
end

function directionToString(direction)
	if direction == defines.direction.north then
		return "north"
	end
	if direction == defines.direction.south then
		return "south"
	end
	if direction == defines.direction.east then
		return "east"
	end
	if direction == defines.direction.west then
		return "west"
	end
end

function findEmitter(emitter)
	if glob.emitters ~= nil then
		for k,v in pairs(glob.emitters) do
			if v["1"].equals(emitter) then
				return v
			end
		end
	end
end

function removeEmitter(emitter)
	local emitterTable = findEmitter(emitter)
	if emitterTable ~= nil then
		removeEmitterID(emitterTable["5"])
	end
end

function removeEmitterID(emitterID)
	if glob.emitters ~= nil then
		if glob.emitters[emitterID] ~= nil then
			degradeLinkedFields(glob.emitters[emitterID])
			glob.emitters[emitterID] = nil
			if tableIsEmpty(glob.emitters) then
				glob.emitters = nil
				glob.emitterNEI = nil
			else
				return true
			end
		end
	end
end

function removeActiveEmitterID(activeEmitterID)
	-- Returns true if the glob.activeEmitters table isn't empty
	if glob.activeEmitters ~= nil then
		table.remove(glob.activeEmitters, activeEmitterID)
		if #glob.activeEmitters == 0 then
			glob.activeEmitters = nil
		else
			return true
		end
	end
end

function removeForcefield(field)
	if glob.fields ~= nil then
		local pos = field.position
		if glob.fields[pos.x] ~= nil and glob.fields[pos.x][pos.y] ~= nil then
			removeForceFieldID(pos.x, pos.y)
		end
	end
end

function removeForceFieldID(x, y)
	-- Does no checking

	glob.fields[x][y] = nil
	if tableIsEmpty(glob.fields[x]) then
		glob.fields[x] = nil
		if tableIsEmpty(glob.fields) then
			glob.fields = nil
		end
	end
end

function removeDegradingFieldID(fieldID)
	-- Returns true if the glob.degradingFields table isn't empty
	if glob.degradingFields ~= nil then
		local pos = glob.degradingFields[fieldID][2]
		table.remove(glob.degradingFields, fieldID)
		local emitters = game.findentitiesfiltered({area = {{x = pos.x - maxFieldDistance, y = pos.y - maxFieldDistance}, {x = pos.x + maxFieldDistance, y = pos.y + maxFieldDistance}}, name = emitterName})
		local emitterTable
		for _,emitter in pairs(emitters) do
			emitterTable = findEmitter(emitter)
			if emitterTable then
				setActive(emitterTable, true)
			end
		end
		if #glob.degradingFields == 0 then
			glob.degradingFields = nil
		else
			return true
		end
	end
end

function degradeLinkedFields(emitterTable)
	if glob.fields ~= nil then
		local pos1, xInc, yInc, incTimes = getFieldsArea(emitterTable)
		local pos2 = {x = pos1.x + (xInc * incTimes), y = pos1.y + (yInc * incTimes)}
		local fields
		if xInc == -1 or yInc == -1 then
			fields = findForcefieldsArea({pos2, pos1}, true)
		else
			fields = findForcefieldsArea({pos1, pos2}, true)
		end
		
		if fields then
			if glob.degradingFields == nil then
				glob.degradingFields = {}
			end
			
			for k,field in pairs(fields) do
				pos = field.position
				if glob.fields[pos.x] ~= nil and glob.fields[pos.x][pos.y] == emitterTable["5"] then
					table.insert(glob.degradingFields, {[1] = field, [2] = field.position})
					removeForcefield(field)
					
					if glob.fields == nil then
						break
					end
				end
			end
			
			if #glob.degradingFields == 0 then
				glob.degradingFields = nil
			else
				activateTicker()
			end
		end
	end
end

function entityBuilt(event)
	if event.createdentity.name == toolName then
		local position = event.createdentity.position
		if event.playerindex ~= nil then
			game.players[event.playerindex].insert({name = toolName, count = 1})
		else
			game.createentity({name = "item-on-ground", position = position, stack = {name = toolName, count = 1}, force = game.forces.player})
		end
		event.createdentity.destroy()
		useTool(position, event.playerindex)
	elseif event.createdentity.name == emitterName then
		onEmitterBuilt(event.createdentity)
	end
end

game.onevent(defines.events.onbuiltentity, entityBuilt)
game.onevent(defines.events.onrobotbuiltentity, entityBuilt)

game.onevent(defines.events.ontriggercreatedentity, function(event)
	if event.entity.name == fieldDamagedTriggerName then
		local position = event.entity.position
		event.entity.destroy()
		onForcefieldDamaged(position)
	end
end)

function ticker()
	if glob.ticking == 0 then
		glob.ticking = tickRate - 1
		tick()
	else
		glob.ticking = glob.ticking - 1
	end
end

function tick()
	local shouldKeepTicking
	-- Active emitters tick
	if glob.activeEmitters ~= nil then
		local shouldRemainActive
		local emitterTable
		shouldKeepTicking = true
		
		-- For each active emitter check if they have fields to repair or fields to build
		for k,emitterTable in pairs(glob.activeEmitters) do
			if emitterTable["1"].valid then
				shouldRemainActive = false
				if emitterTable["14"] == false then
					if emitterTable["4"] ~= nil then
						-- The function will toggle index 4 if it finishes building fields.
						if scanAndBuildFields(emitterTable) then
							shouldRemainActive = true
						end
					end
				end
				if emitterTable["11"] then
					-- The function will toggle index 11 if it finishes generating fields.
					if generateFields(emitterTable) then
						shouldRemainActive = true
					end
				end
				
				if emitterTable["3"] then
					-- The function will toggle index 3 if it finishes repairing fields.
					if regenerateFields(emitterTable) then
						shouldRemainActive = true
					end
				end
				
				if not shouldRemainActive then
					-- Index 2 is the active state of the emitter
					emitterTable["2"] = false
					if not removeActiveEmitterID(k) then
						break
					end
				end
			else
				removeEmitterID(emitterTable["5"])
				if not removeActiveEmitterID(k) then
					break
				end
			end
		end
	end
	
	-- Degrading force fields tick - happens when a emitter dies or is mined.
	if glob.degradingFields ~= nil then
		shouldKeepTicking = true
		for k,v in pairs(glob.degradingFields) do
			if v[1].valid then
				v[1].health = v[1].health - (forcefieldTypes[v[1].name]["degradeRate"] * tickRate)
				if v[1].health == 0 then
					v[1].destroy()
					if not removeDegradingFieldID(k) then
						break
					end
				end
			else
				if not removeDegradingFieldID(k) then
					break
				end
			end
		end
	end
	
	if glob.searchDamagedPos ~= nil then
		shouldKeepTicking = true
		for sx,ys in pairs(glob.searchDamagedPos) do
			for sy in pairs(ys) do
				local foundFields = findForcefieldsRadius({x = sx + 0.5, y = sy + 0.5}, 0)
				if foundFields ~= nil then
					handleDamagedFields(foundFields)
				end
				table.remove(ys, sy)
			end
			table.remove(glob.searchDamagedPos, sx)
		end
		if #glob.searchDamagedPos == 0 then
			glob.searchDamagedPos = nil
		end
	end
	
	if not shouldKeepTicking then
		glob.ticking = nil
		game.onevent(defines.events.ontick, nil)
	end
end

function useTool(pos, playerIndex)
	local emitter = game.findentitiesfiltered({area = {{x = pos.x - toolRadius, y = pos.y - toolRadius}, {x = pos.x + toolRadius, y = pos.y + toolRadius}}, name = emitterName})
	if #emitter ~= 0 then
		local emitterTable = findEmitter(emitter[1])
		if emitterTable ~= nil then
			showEmitterGui(emitterTable, playerIndex)
		end
	end
end

function onEmitterBuilt(entity)
	local newEmitter = {}
	if glob.emitters == nil then
		glob.emitters = {}
		glob.emitterNEI = 1
	end
	
	newEmitter["1"] = entity							-- emitter entity
	newEmitter["2"] = false								-- is active
	newEmitter["3"] = nil								-- damaged fields table (fields needing to be charged back to full health from damage)
	newEmitter["4"] = true								-- check for building fields
	newEmitter["5"] = "I" .. glob.emitterNEI			-- emitterID (the index the table is using in the glob.emitters table)
														-- used by fields to reference the emitter they're being powered from
	newEmitter["6"] = emitterDefaultWidth				-- width the emitter is projecting at
	newEmitter["7"] = emitterDefaultDistance			-- distance the emitter is projecting at
	newEmitter["8"] = 0									-- field ticks until next build check
	newEmitter["9"] = defaultFieldType					-- field type
	newEmitter["10"] = defines.direction.north			-- emitter direction
	newEmitter["11"] = nil								-- initially generated fields needing to be generated to full health
	newEmitter["12"] = 0								-- width upgrades applied
	newEmitter["13"] = 0								-- distance upgrades applied
	newEmitter["14"] = false							-- is disabled
	
	-- Simulates reviving killed emitters
	if glob.killedEmitters ~= nil then
		for k,killedEmitter in pairs(glob.killedEmitters) do
			if killedEmitter["1"].x == entity.position.x and killedEmitter["1"].y == entity.position.y then
				newEmitter["6"] = killedEmitter["2"]
				newEmitter["7"] = killedEmitter["3"]
				newEmitter["9"] = killedEmitter["4"]
				newEmitter["10"] = killedEmitter["5"]
				removeKilledEmitter(k)
				break
			end
		end
	end
	
	
	glob.emitters["I" .. glob.emitterNEI] = newEmitter
	glob.emitterNEI = glob.emitterNEI + 1
	
	setActive(newEmitter, true, true)
end

function getFieldsArea(emitterTable)
	local scanDirection = emitterTable["10"]
	local pos = {}
	local xInc = 0
	local yInc = 0
	
	if scanDirection == defines.direction.north then
		pos.x = emitterTable["1"].position.x - (emitterTable["6"] - 1) / 2
		pos.y = emitterTable["1"].position.y - emitterTable["7"]
		xInc = 1
	elseif scanDirection == defines.direction.east then
		pos.x = emitterTable["1"].position.x + emitterTable["7"]
		pos.y = emitterTable["1"].position.y - (emitterTable["6"] - 1) / 2
		yInc = 1
	elseif scanDirection == defines.direction.south then
		pos.x = emitterTable["1"].position.x + (emitterTable["6"] - 1) / 2
		pos.y = emitterTable["1"].position.y + emitterTable["7"]
		xInc = -1
	else
		pos.x = emitterTable["1"].position.x - emitterTable["7"]
		pos.y = emitterTable["1"].position.y + (emitterTable["6"] - 1) / 2
		yInc = -1
	end
	
	return pos, xInc, yInc, emitterTable["6"]
end

function scanAndBuildFields(emitterTable)
	local builtField
	
	if emitterTable["8"] == 0 then
		local energyBefore = emitterTable["1"].energy
		if emitterTable["1"].energy >= (tickRate * forcefieldTypes[emitterTable["9"]]["energyPerRespawn"] + tickRate * forcefieldTypes[emitterTable["9"]]["energyPerCharge"]) then
			local pos, xInc, yInc, incTimes = getFieldsArea(emitterTable)
			local blockingFields = 0
			local blockingFieldsBefore = 0
			local direction
			local playerForce = game.forces.player
			
			if emitterTable["10"] == defines.direction.north or emitterTable["10"] == defines.direction.south then
				direction = defines.direction.east
			else
				direction = defines.direction.north
			end
			
			if glob.fields == nil then
				glob.fields = {}
			end
			
			for n=1,incTimes do
				-- If another emitter (or even this one previously) has built a field at this location, skip trying to build there
				if glob.fields[pos.x] == nil or glob.fields[pos.x][pos.y] == nil then
					if game.canplaceentity({name = emitterTable["9"], position = pos, direction = direction}) then
						local newField = game.createentity({name = emitterTable["9"], position = pos, force = game.forces.player, direction = direction})
						
						newField.health = forcefieldTypes[emitterTable["9"]]["chargeRate"]
						if emitterTable["11"] == nil then
							emitterTable["11"] = {}
						end
						table.insert(emitterTable["11"], newField)
						
						if glob.fields[pos.x] == nil then
							glob.fields[pos.x] = {}
						end
						glob.fields[pos.x][pos.y] = emitterTable["5"]
						
						builtField = true
						emitterTable["1"].energy = emitterTable["1"].energy -  (tickRate * forcefieldTypes[emitterTable["9"]]["energyPerRespawn"])
						if n ~= incTimes and emitterTable["1"].energy == 0 then
							emitterTable["8"] = forcefieldTypes[emitterTable["9"]]["respawnRate"] * 10
							degradeLinkedFields(emitterTable)
							break
						end
						blockingFields = blockingFields + 1
					else
						local blockingField = findForcefieldsRadius(pos, 0.4, true)
						if blockingField ~= nil then
							if glob.degradingFields ~= nil then
								-- Prevents the emitter from going into extended sleep from "can't build" due to degrading fields (happens most when switching field types)
								local fpos = blockingField[1].position
								for _,field in pairs(glob.degradingFields) do
									if field[1].position.x == pos.x and field[1].position.y == pos.y then
										builtField = true
										break
									end
								end
							end
						else
							local blockingGhosts = findGhostForcefields(pos, 0.4)
							if blockingGhosts ~= nil then
								for _,ghost in pairs(blockingGhosts) do
									ghost.destroy()
								end
								builtField = true
							else
								game.createentity({name = "forcefield-build-damage", position = pos, force = playerForce})
							end
						end
					end
				else
					blockingFields = blockingFields + 1
				end
				pos.x = pos.x + xInc
				pos.y = pos.y + yInc
			end
			
			if tableIsEmpty(glob.fields) then
				glob.fields = nil
			end
			
			if blockingFields == incTimes then
				emitterTable["4"] = nil
				return false
			else
				if not builtField then
					emitterTable["8"] = forcefieldTypes[emitterTable["9"]]["respawnRate"] * 3 + math.random(forcefieldTypes[emitterTable["9"]]["respawnRate"])
				else
					emitterTable["8"] = forcefieldTypes[emitterTable["9"]]["respawnRate"]
				end
			end
		else
			emitterTable["8"] = forcefieldTypes[emitterTable["9"]]["respawnRate"] * 5
			degradeLinkedFields(emitterTable)
		end
	else
		emitterTable["8"] = emitterTable["8"] - 1
	end
	
	return true
end

function regenerateFields(emitterTable)
	local availableEnergy = emitterTable["1"].energy
	local neededEnergy
	
	for k,field in pairs(emitterTable["3"]) do
		if field.valid then
			neededEnergy = forcefieldTypes[field.name]["energyPerHealthLost"] * (forcefieldTypes[field.name]["maxHealth"] - field.health)
			if availableEnergy >= neededEnergy then
				field.health = forcefieldTypes[field.name]["maxHealth"]
				availableEnergy = availableEnergy - neededEnergy
				table.remove(emitterTable["3"], k)
			else
				degradeLinkedFields(emitterTable)
				emitterTable["3"] = {}
				emitterTable["8"] = forcefieldTypes[emitterTable["9"]]["respawnRate"] * 10
				setActive(emitterTable, true, true)
			end
		else
			table.remove(emitterTable["3"], k)
		end
	end
	
	emitterTable["1"].energy = availableEnergy
	if #emitterTable["3"] == 0 then
		emitterTable["3"] = nil
	else
		return true
	end
end

function generateFields(emitterTable)
	local availableEnergy = emitterTable["1"].energy
	
	for k,field in pairs(emitterTable["11"]) do
		if field.valid then
			if availableEnergy >= (forcefieldTypes[field.name]["energyPerCharge"] * tickRate) then
				field.health = field.health + (forcefieldTypes[field.name]["chargeRate"] * tickRate)
				availableEnergy = availableEnergy - (forcefieldTypes[field.name]["energyPerCharge"] * tickRate)
				if field.health >= forcefieldTypes[field.name]["maxHealth"] then
					table.remove(emitterTable["11"], k)
				end
			else
				degradeLinkedFields(emitterTable)
				emitterTable["11"] = {}
				emitterTable["8"] = forcefieldTypes[emitterTable["9"]]["respawnRate"] * 10
				setActive(emitterTable, true, true)
			end
		else
			table.remove(emitterTable["11"], k)
		end
	end
	
	emitterTable["1"].energy = availableEnergy
	if #emitterTable["11"] == 0 then
		emitterTable["11"] = nil
	else
		return true
	end
end

function findForcefieldsRadius(position, radius, includeFullHealth)
	local walls = game.findentitiesfiltered({area = {{x = position.x - radius, y = position.y - radius}, {x = position.x + radius, y = position.y + radius}}, type = "wall"})
	local gates = game.findentitiesfiltered({area = {{x = position.x - radius, y = position.y - radius}, {x = position.x + radius, y = position.y + radius}}, type = "gate"})
	local foundFields = {}
	
	if #walls ~= 0 then
		for i,wall in pairs(walls) do
			if forcefieldTypes[wall.name] ~= nil and (includeFullHealth or wall.health ~= forcefieldTypes[wall.name]["maxHealth"]) then
				table.insert(foundFields, wall)
			end
		end
	end
	if #gates ~= 0 then
		for i,gate in pairs(gates) do
			if forcefieldTypes[gate.name] ~= nil and (includeFullHealth or gate.health ~= forcefieldTypes[gate.name]["maxHealth"]) then
				table.insert(foundFields, gate)
			end
		end
	end
	if #foundFields ~= 0 then
		return foundFields
	end
end

function findForcefieldsArea(area, includeFullHealth)
	local walls = game.findentitiesfiltered({area = area, type = "wall"})
	local gates = game.findentitiesfiltered({area = area, type = "gate"})
	local foundFields = {}
	
	if #walls ~= 0 then
		for i,wall in pairs(walls) do
			if forcefieldTypes[wall.name] ~= nil and (includeFullHealth or wall.health ~= forcefieldTypes[wall.name]["maxHealth"]) then
				table.insert(foundFields, wall)
			end
		end
	end
	if #gates ~= 0 then
		for i,gate in pairs(gates) do
			if forcefieldTypes[gate.name] ~= nil and (includeFullHealth or gate.health ~= forcefieldTypes[gate.name]["maxHealth"]) then
				table.insert(foundFields, gate)
			end
		end
	end
	if #foundFields ~= 0 then
		return foundFields
	end
end

function findGhostForcefields(position, radius)
	local ghosts = game.findentitiesfiltered({area = {{x = position.x - radius, y = position.y - radius}, {x = position.x + radius, y = position.y + radius}}, type = "ghost"})
	if #ghosts ~= 0 then
		local foundGhosts = {}
		for i,ghost in pairs(ghosts) do
			if forcefieldTypes[ghost.ghostname] ~= nil then
				table.insert(foundGhosts, ghost)
			end
		end
		return foundGhosts
	end
end

function onForcefieldDamaged(pos)
	pos.x = math.floor(pos.x)
	pos.y = math.floor(pos.y)
	if glob.searchDamagedPos == nil then
		glob.searchDamagedPos = {}
	end
	if glob.searchDamagedPos[pos.x] == nil then
		glob.searchDamagedPos[pos.x] = {}
	end
	glob.searchDamagedPos[pos.x][pos.y] = 1
	activateTicker()
end

function handleDamagedFields(forceFields)
	local pos
	local fieldShouldBeAdded
	local addedFields
	local fieldID
	
	if glob.fields ~= nil and glob.emitters ~= nil then
		-- For each possibly damaged forcefield found
		for k,field in pairs(forceFields) do
			pos = field.position
			fieldShouldBeAdded = true
			
			-- If the field is known to the mod
			if glob.fields[pos.x] ~= nil and glob.fields[pos.x][pos.y] ~= nil then
				fieldID = glob.fields[pos.x][pos.y]
				-- If the field has a valid linked emitter
				if glob.emitters[fieldID] ~= nil then
					if glob.emitters[fieldID]["11"] ~= nil then
						for _,generatingField in pairs(glob.emitters[fieldID]["11"]) do
							if generatingField.equals(field) then
								fieldShouldBeAdded = false
								break
							end
						end
					end
					
					-- Add the damaged field to the emitter damaged field table if it isn't already in it
					if fieldShouldBeAdded then
						if glob.emitters[fieldID]["3"] == nil then
							glob.emitters[fieldID]["3"] = {}
						end
						table.insert(glob.emitters[fieldID]["3"], field)
						setActive(glob.emitters[fieldID])
						addedFields = true
					end
				end
			end
		end
	end
end

function onForcefieldDied(field)
	local pos = field.position
	if glob.fields ~= nil and glob.fields[pos.x] ~= nil and glob.fields[pos.x][pos.y] ~= nil then
		local emitterID = glob.fields[pos.x][pos.y]
		removeForceFieldID(pos.x, pos.y)
		if glob.emitters ~= nil and glob.emitters[emitterID] ~= nil then
			setActive(glob.emitters[emitterID], true)
		end
		if forcefieldTypes[field.name]["deathEntity"] ~= nil then
			game.createentity({name = forcefieldTypes[field.name]["deathEntity"], position = pos, force = game.forces.player})
		end
	end
end

function setActive(emitterTable, enableCheckBuildingFields, skipResetTimer)
	if emitterTable["14"] == true then
		return
	end
	
	if enableCheckBuildingFields then
		emitterTable["4"] = true
		if not skipResetTimer and emitterTable["8"] > forcefieldTypes[emitterTable["9"]]["respawnRate"] or not emitterTable["2"] then
			emitterTable["8"] = forcefieldTypes[emitterTable["9"]]["respawnRate"]
		end
	end
	
	if not emitterTable["2"] then
		emitterTable["2"] = true
		if glob.activeEmitters == nil then
			glob.activeEmitters = {}
		end
		table.insert(glob.activeEmitters, emitterTable)
		activateTicker()
	end
end

function activateTicker()
	if not glob.ticking then
		glob.ticking = tickRate
		game.onevent(defines.events.ontick, ticker)
	end
end

function getEmitterBonusWidth(emitterTable)
	return emitterTable["13"] * widthUpgradeMultiplier
end

function getEmitterBonusDistance(emitterTable)
	return emitterTable["12"]
end

function handleGUIDirectionButtons(event)
	local frame = game.players[event.element.playerindex].gui.center.emitterConfig
	local nameToDirection = {["directionN"] = defines.direction.north, ["directionS"] = defines.direction.south, ["directionE"] = defines.direction.east, ["directionW"] = defines.direction.west}
	
	if frame ~= nil then
		local directions = frame.emitterConfigTable.directions
		glob.emitterConfigGUIs["I" .. event.element.playerindex][2] = nameToDirection[event.element.name]
		
		--broken in 0.11.3
		--directions.directionN.style = "selectbuttons"
		--directions.directionS.style = "selectbuttons"
		--directions.directionE.style = "selectbuttons"
		--directions.directionW.style = "selectbuttons"
		--directions[event.element.name].style = "selectbuttonsselected"
		
		-- Work-around
		local selectedButtonName = event.element.name
		directions.directionN.destroy()
		directions.directionS.destroy()
		directions.directionE.destroy()
		directions.directionW.destroy()
		
		local d1Style = "selectbuttons"
		local d2Style = "selectbuttons"
		local d3Style = "selectbuttons"
		local d4Style = "selectbuttons"
		if selectedButtonName == "directionN" then
			d1Style = "selectbuttonsselected"
		elseif selectedButtonName == "directionS" then
			d2Style = "selectbuttonsselected"
		elseif selectedButtonName == "directionE" then
			d3Style = "selectbuttonsselected"
		elseif selectedButtonName == "directionW" then
			d4Style = "selectbuttonsselected"
		end
		directions.add({type = "button", name = "directionN", caption = "N", style = d1Style})
		directions.add({type = "button", name = "directionS", caption = "S", style = d2Style})
		directions.add({type = "button", name = "directionE", caption = "E", style = d3Style})
		directions.add({type = "button", name = "directionW", caption = "W", style = d4Style})
	end
end

function handleGUIFieldTypeButtons(event)
	local frame = game.players[event.element.playerindex].gui.center.emitterConfig
	local nameToFieldName = {["fieldB"] = "blue" .. fieldSuffix, ["fieldG"] = "green" .. fieldSuffix, ["fieldR"] = "red" .. fieldSuffix, ["fieldP"] = "purple" .. fieldSuffix}
	if frame ~= nil then
		local fields = frame.emitterConfigTable.fields
		local shouldSwitch = true
		
		--Broken in 0.11.3
		--fields.fieldB.style = "selectbuttons"
		--fields.fieldG.style = "selectbuttons"
		--fields.fieldR.style = "selectbuttons"
		--fields.fieldP.style = "selectbuttons"
		--fields[event.element.name].style = "selectbuttonsselected"
		
		-- Work around
		local selectedButtonName = event.element.name
		local f1Style = "selectbuttons"
		local f2Style = "selectbuttons"
		local f3Style = "selectbuttons"
		local f4Style = "selectbuttons"
		if selectedButtonName == "fieldB" then
			f1Style = "selectbuttonsselected"
		elseif selectedButtonName == "fieldG" then
			shouldSwitch = game.forces.player.technologies["green-fields"].researched
			f2Style = "selectbuttonsselected"
		elseif selectedButtonName == "fieldR" then
			shouldSwitch = game.forces.player.technologies["red-fields"].researched
			f3Style = "selectbuttonsselected"
		elseif selectedButtonName == "fieldP" then
			shouldSwitch = game.forces.player.technologies["purple-fields"].researched
			f4Style = "selectbuttonsselected"
		end
		
		if shouldSwitch then
			glob.emitterConfigGUIs["I" .. event.element.playerindex][3] = nameToFieldName[event.element.name]
			fields.fieldB.destroy()
			fields.fieldG.destroy()
			fields.fieldR.destroy()
			fields.fieldP.destroy()
			fields.add({type = "button", name = "fieldB", caption = "B", style = f1Style})
			fields.add({type = "button", name = "fieldG", caption = "G", style = f2Style})
			fields.add({type = "button", name = "fieldR", caption = "R", style = f3Style})
			fields.add({type = "button", name = "fieldP", caption = "P", style = f4Style})
		else
			game.players[event.element.playerindex].print("You need to complete research before this field type can be used.")
		end
	end
end

function handleGUIUpgradeButtons(event)
	local player = game.players[event.element.playerindex]
	local frame = player.gui.center.emitterConfig
	local nameToStyle = {["distanceUpgrades"] = "advanced-circuit", ["widthUpgrades"] = "processing-unit"}
	local styleToName = {["advanced-circuit"] = "distanceUpgrades", ["processing-unit"] = "widthUpgrades"}
	local nameToUpgradeLimit = {["distanceUpgrades"] = maxRangeUpgrades, ["widthUpgrades"] = maxWidthUpgrades}
	
	if frame ~= nil then
		local upgrades = frame.emitterConfigTable.upgrades
		local upgradeButton
		local count
		
		if player.cursorstack ~= nil then
			local stack = player.cursorstack
			
			if styleToName[stack.name] ~= nil then
				upgradeButton = upgrades[styleToName[stack.name]]
				if upgradeButton.caption ~= "" then
					count = tonumber(string.sub(upgradeButton.caption, 2)) + 1
				else
					count = 1
				end
				
				if count <= nameToUpgradeLimit[upgradeButton.name] then
					upgradeButton.caption = "x" .. tostring(count)
					updateMaxLabel(frame, upgradeButton)
					
					if count == 1 then
						--Broken in 0.11.3
						--upgradeButton.style = nameToStyle[upgradeButton.name]
						
						-- Work-around
						local distanceCaption = upgrades.distanceUpgrades.caption
						local widthCaption = upgrades.widthUpgrades.caption
						local distanceStyle
						local widthStyle
						upgrades.distanceUpgrades.destroy()
						upgrades.widthUpgrades.destroy()
						
						if distanceCaption == "" then
							distanceStyle = "noitem"
						else
							distanceStyle = "advanced-circuit"
						end
						if widthCaption == "" then
							widthStyle = "noitem"
						else
							widthStyle = "processing-unit"
						end
						
						upgrades.add({type = "button", name = "distanceUpgrades", caption = distanceCaption, style = distanceStyle})
						upgrades.add({type = "button", name = "widthUpgrades", caption = widthCaption, style = widthStyle})
					end
					
					stack.count = stack.count - 1
					if stack.count == 0 then
						player.cursorstack = nil
					else
						player.cursorstack = stack
					end
				else
					game.players[event.element.playerindex].print("Maximum upgrades of this type already installed.")
				end
			end
		else
			upgradeButton = upgrades[event.element.name]
			
			if upgradeButton.caption ~= "" then
				count = tonumber(string.sub(upgradeButton.caption, 2)) - 1
				if count == 0 then
					--Broken in 0.11.3
					--upgradeButton.style = "noitem"
					--upgradeButton.caption = ""
					
					-- Work-around
					local distanceCaption = upgrades.distanceUpgrades.caption
					local widthCaption = upgrades.widthUpgrades.caption
					local whichButton = upgradeButton.name
					local distanceStyle
					local widthStyle
					upgrades.distanceUpgrades.destroy()
					upgrades.widthUpgrades.destroy()
					
					if whichButton == "distanceUpgrades" then
						distanceCaption = ""
					else
						widthCaption = ""
					end
					
					if distanceCaption == "" then
						distanceStyle = "noitem"
					else
						distanceStyle = "advanced-circuit"
					end
					if widthCaption == "" then
						widthStyle = "noitem"
					else
						widthStyle = "processing-unit"
					end
					
					upgrades.add({type = "button", name = "distanceUpgrades", caption = distanceCaption, style = distanceStyle})
					upgrades.add({type = "button", name = "widthUpgrades", caption = widthCaption, style = widthStyle})
					upgradeButton = upgrades[whichButton]
				else
					upgradeButton.caption = "x" .. tostring(count)
				end
				
				updateMaxLabel(frame, upgradeButton)
				transferToPlayer(player, {name = nameToStyle[upgradeButton.name], count = 1})
			end
		end
	end
end

function removeAllUpgrades(event)
	local frame = game.players[event.element.playerindex].gui.center.emitterConfig

	if frame then -- This shouldn't ever be required but won't hurt to check
		if glob.emitterConfigGUIs ~= nil
			and glob.emitterConfigGUIs["I" .. event.element.playerindex] ~= nil
			and glob.emitterConfigGUIs["I" .. event.element.playerindex][1]["1"].valid then
			
			local upgrades = frame.emitterConfigTable.upgrades
			local count
			local buttonName
			for itemName,button in pairs({["advanced-circuit"] = upgrades.distanceUpgrades, ["processing-unit"] = upgrades.widthUpgrades}) do
				if button.caption ~= "" then
					count = tonumber(string.sub(button.caption, 2))
					--bugged in 0.11.3
					--button.caption = ""
					--button.style = "noitem"
					
					buttonName = button.name
					button.destroy()
					button = upgrades.add({type = "button", name = buttonName, caption = "", style = "noitem"})
					
					updateMaxLabel(frame, button)
					transferToPlayer(game.players[event.element.playerindex], {name = itemName, count = count})
				end
			end
		else
			if glob.emitterConfigGUIs ~= nil and glob.emitterConfigGUIs["I" .. event.element.playerindex] ~= nil then
				glob.emitterConfigGUIs["I" .. event.element.playerindex] = nil
				if tableIsEmpty(glob.emitterConfigGUIs) then
					glob.emitterConfigGUIs = nil
				end
			end
			frame.destroy()
		end
	end
end

function handleGUIMenuButtons(event)
	local frame = game.players[event.element.playerindex].gui.center.emitterConfig
	if frame ~= nil then
		if event.element.name == "applyButton" then
			if verifyAndSetFromGUI(event) then
				glob.emitterConfigGUIs["I" .. event.element.playerindex] = nil
				if tableIsEmpty(glob.emitterConfigGUIs) then
					glob.emitterConfigGUIs = nil
				end
				frame.destroy()
			end
		elseif event.element.name == "emitterHelpButton" then
			printGUIHelp(game.players[event.element.playerindex])
		elseif event.element.name == "removeAllButton" then
			removeAllUpgrades(event)
		end
	end
end

function printGUIHelp(player)
	player.print("Direction: the direction the emitter projects the forcefields in.")
	player.print("Field type: the type of forcefield the emitter projects:")
	player.print("    [B]lue: normal health, normal re-spawn, normal power usage.")
	player.print("    [G]reen: higher health, very slow re-spawn, below-normal power usage.")
	player.print("    [R]ed: normal health, slow re-spawn, very high power usage. Damages living things that directly attack them.")
	player.print("    [P]urple: low health, very slow re-spawn, high power usage. On death, heavily damages living things near-by.")
	player.print("Emitter distance: the distance from the emitter in the configured direction the fields are constructed.")
	player.print("Emitter width: the width of the field constructed by the emitter.")
	player.print("Upgrades applied: the distance (advanced circuit) and width (processing unit) upgrades applied to the emitter.")
	player.print("Help button: displays this information.")
	player.print("Remove all upgrades: removes all upgrades from the emitter.")
	player.print("Apply: saves and applies the settings to the emitter.")
end

function updateMaxLabel(frame, upgradeButton)
	local count
	if upgradeButton.caption == "" then
		count = 0
	else
		count = tonumber(string.sub(upgradeButton.caption, 2))
	end
	if upgradeButton.name == "distanceUpgrades" then
		frame.emitterConfigTable.distance.emitterMaxDistance.caption = "Max: " .. tostring(emitterDefaultDistance + count)
	else
		frame.emitterConfigTable.width.emitterMaxWidth.caption = "Max: " .. tostring(emitterDefaultWidth + (count * 4))
	end
end

local guiNames =
{
	["directionN"] = handleGUIDirectionButtons,
	["directionS"] = handleGUIDirectionButtons,
	["directionE"] = handleGUIDirectionButtons,
	["directionW"] = handleGUIDirectionButtons,

	["fieldB"] = handleGUIFieldTypeButtons,
	["fieldG"] = handleGUIFieldTypeButtons,
	["fieldR"] = handleGUIFieldTypeButtons,
	["fieldP"] = handleGUIFieldTypeButtons,

	["distanceUpgrades"] = handleGUIUpgradeButtons,
	["widthUpgrades"] = handleGUIUpgradeButtons,

	["emitterHelpButton"] = handleGUIMenuButtons,
	["removeAllButton"] = handleGUIMenuButtons,
	["applyButton"] = handleGUIMenuButtons
}

game.onevent(defines.events.onguiclick, function(event)
	if guiNames[event.element.name] then
		guiNames[event.element.name](event)
	end
end)

function verifyAndSetFromGUI(event)
	local newDirection
	local newFieldType
	local newDistance
	local newWidth
	local maxDistance
	local maxWidth
	local newWidthUpgrades
	local newDistanceUpgrades
	local selectedButtonStyle = "selectbuttonsselected"
	local player = game.players[event.element.playerindex]
	local settingsAreGood = true
	local settingsChanged = false
	local frame = player.gui.center.emitterConfig
	local emitterConfigTable = frame.emitterConfigTable 
	local upgrades = emitterConfigTable.upgrades
	
	if glob.emitterConfigGUIs ~= nil
		and glob.emitterConfigGUIs["I" .. event.element.playerindex] ~= nil
		and glob.emitterConfigGUIs["I" .. event.element.playerindex][1]["1"].valid then
		
		local emitterTable = glob.emitterConfigGUIs["I" .. event.element.playerindex][1]
		
		if glob.emitterConfigGUIs["I" .. event.element.playerindex][2] ~= nil then
			newDirection = glob.emitterConfigGUIs["I" .. event.element.playerindex][2]
		else
			newDirection = emitterTable["10"]
		end
		
		if glob.emitterConfigGUIs["I" .. event.element.playerindex][3] ~= nil then
			newFieldType = glob.emitterConfigGUIs["I" .. event.element.playerindex][3]
		else
			newFieldType = emitterTable["9"]
		end
		
		newDistance = tonumber(emitterConfigTable.distance.emitterDistance.text)
		newWidth = tonumber(emitterConfigTable.width.emitterWidth.text)
		maxDistance = tonumber(string.sub(emitterConfigTable.distance.emitterMaxDistance.caption, 6))
		maxWidth = tonumber(string.sub(emitterConfigTable.width.emitterMaxWidth.caption, 6))
		if upgrades.distanceUpgrades.caption ~= "" then
			newDistanceUpgrades = tonumber(string.sub(upgrades.distanceUpgrades.caption, 2))
		else
			newDistanceUpgrades = 0
		end
		if upgrades.widthUpgrades.caption ~= "" then
			newWidthUpgrades = tonumber(string.sub(upgrades.widthUpgrades.caption, 2))
		else
			newWidthUpgrades = 0
		end
		
		
		if not newDistance then
			player.print("New Distance is not a valid number.")
			settingsAreGood = false
		elseif newDistance > maxDistance then
			player.print("New Distance is larger than the allowed maximum.")
			settingsAreGood = false
		elseif newDistance < 1 then
			player.print("New Distance is smaller than the allowed minimum (1).")
			settingsAreGood = false
		elseif math.floor(newDistance) ~= newDistance then
			player.print("New Distance is not a valid number (can't have decimals).")
			settingsAreGood = false
		end
		if not newWidth then
			player.print("New Width is not a valid number.")
			settingsAreGood = false
		elseif newWidth > maxWidth then
			player.print("New Width is larger than the allowed maximum.")
			settingsAreGood = false
		elseif newWidth < 1 then
			player.print("New Width is smaller than the allowed minimum (1).")
			settingsAreGood = false
		elseif math.floor(newWidth) ~= newWidth then
			player.print("New Width is not a valid number (can't have decimals).")
			settingsAreGood = false
		elseif (math.floor((newWidth - 1) / 2) * 2) + 1 ~= newWidth then
			player.print("New Width has to be an odd number.")
			emitterConfigTable.width.emitterWidth.text = tostring((math.floor((newWidth - 1) / 2) * 2) + 1)
			settingsAreGood = false
		end
		
		if settingsAreGood then
			if emitterTable["6"] ~= newWidth
				or emitterTable["7"] ~= newDistance
				or emitterTable["9"] ~= newFieldType
				or emitterTable["10"] ~= newDirection then
				
				degradeLinkedFields(emitterTable)
				emitterTable["3"] = nil
				emitterTable["6"] = newWidth
				emitterTable["7"] = newDistance
				emitterTable["9"] = newFieldType
				emitterTable["10"] = newDirection
				emitterTable["11"] = nil
				setActive(emitterTable, true)
			end
			
			emitterTable["12"] = newDistanceUpgrades
			emitterTable["13"] = newWidthUpgrades
			return true
		end
	else
		return true
	end
end

function showEmitterGui(emitterTable, playerIndex)
	local GUICenter = game.players[playerIndex].gui.center
	local canOpenGUI = true
	if glob.emitterConfigGUIs ~= nil then
		for index,player in pairs(game.players) do
			--if index ~= playerIndex then
				if glob.emitterConfigGUIs["I" .. index] ~= nil and glob.emitterConfigGUIs["I" .. index][1] == emitterTable then
					if index ~= playerIndex then
						game.players[playerIndex].print(player.name .. " (player " .. index .. ") has the GUI for this emitter open right now.")
					end
					canOpenGUI = false
				end
			--end
		end
	end
	
	if canOpenGUI and GUICenter and GUICenter.emitterConfig == nil then
		local frame = GUICenter.add({type = "frame", name = "emitterConfig", caption = game.getlocalisedentityname(emitterName), direction = "vertical", style = frame_caption_label_style})
		local configTable = frame.add({type ="table", name = "emitterConfigTable", colspan = 2})
		configTable.add({type = "label", name = "directionLabel", caption = "Direction:                       "})
		local directions = configTable.add({type = "table", name = "directions", colspan = 4})
		
		local d1Style = "selectbuttons"
		local d2Style = "selectbuttons"
		local d3Style = "selectbuttons"
		local d4Style = "selectbuttons"
		if emitterTable["10"] == defines.direction.north then
			d1Style = "selectbuttonsselected"
		elseif emitterTable["10"] == defines.direction.south then
			d2Style = "selectbuttonsselected"
		elseif emitterTable["10"] == defines.direction.east then
			d3Style = "selectbuttonsselected"
		elseif emitterTable["10"] == defines.direction.south then
			d4Style = "selectbuttonsselected"
		end
		directions.add({type = "button", name = "directionN", caption = "N", style = d1Style})
		directions.add({type = "button", name = "directionS", caption = "S", style = d2Style})
		directions.add({type = "button", name = "directionE", caption = "E", style = d3Style})
		directions.add({type = "button", name = "directionW", caption = "W", style = d4Style})
		
		configTable.add({type = "label", name = "fieldTypeLabel", caption = "Field type:"})
		local fields = configTable.add({type = "table", name = "fields", colspan = 4})
		local f1Style = "selectbuttons"
		local f2Style = "selectbuttons"
		local f3Style = "selectbuttons"
		local f4Style = "selectbuttons"
		if emitterTable["9"] == "blue" .. fieldSuffix then
			f1Style = "selectbuttonsselected"
		elseif emitterTable["9"] == "green" .. fieldSuffix then
			f2Style = "selectbuttonsselected"
		elseif emitterTable["9"] == "red" .. fieldSuffix then
			f3Style = "selectbuttonsselected"
		elseif emitterTable["9"] == "purple" .. fieldSuffix then
			f4Style = "selectbuttonsselected"
		end
		fields.add({type = "button", name = "fieldB", caption = "B", style = f1Style})
		fields.add({type = "button", name = "fieldG", caption = "G", style = f2Style})
		fields.add({type = "button", name = "fieldR", caption = "R", style = f3Style})
		fields.add({type = "button", name = "fieldP", caption = "P", style = f4Style})
		
		-- Non-functional at the moment due to bugs with setting .style in Multiplayer
		--[[
		local d1 = directions.add({type = "button", name = "directionN", caption = "N", style = "selectbuttons"})
		local d2 = directions.add({type = "button", name = "directionS", caption = "S", style = "selectbuttons"})
		local d3 = directions.add({type = "button", name = "directionE", caption = "E", style = "selectbuttons"})
		local d4 = directions.add({type = "button", name = "directionW", caption = "W", style = "selectbuttons"})
		
		if emitterTable[10] == defines.direction.north then
			d1.style = "selectbuttonsselected"
		elseif emitterTable[10] == defines.direction.south then
			d2.style = "selectbuttonsselected"
		elseif emitterTable[10] == defines.direction.east then
			d3.style = "selectbuttonsselected"
		elseif emitterTable[10] == defines.direction.south then
			d4.style = "selectbuttonsselected"
		end
		
		configTable.add({type = "label", name = "fieldTypeLabel", caption = "Field type:"})
		local fields = configTable.add({type = "table", name = "fields", colspan = 4})
		local f1 = fields.add({type = "button", name = "fieldB", caption = "B", style = "selectbuttons"})
		local f2 = fields.add({type = "button", name = "fieldG", caption = "G", style = "selectbuttons"})
		local f3 = fields.add({type = "button", name = "fieldR", caption = "R", style = "selectbuttons"})
		local f4 = fields.add({type = "button", name = "fieldP", caption = "P", style = "selectbuttons"})
		
		if emitterTable[9] == "blue" .. fieldSuffix then
			f1.style = "selectbuttonsselected"
		elseif emitterTable[9] == "green" .. fieldSuffix then
			f2.style = "selectbuttonsselected"
		elseif emitterTable[9] == "red" .. fieldSuffix then
			f3.style = "selectbuttonsselected"
		elseif emitterTable[9] == "purple" .. fieldSuffix then
			f4.style = "selectbuttonsselected"
		end
		--]]
		
		configTable.add({type = "label", name = "distanceLabel", caption = "Emitter distance:"})
		local distance = configTable.add({type = "table", name = "distance", colspan = 2})
		distance.add({type = "textfield", name = "emitterDistance", style = "distancetext"}).text = emitterTable["7"]
		distance.add({type = "label", name = "emitterMaxDistance", caption = "Max: " .. tostring(emitterDefaultDistance + getEmitterBonusDistance(emitterTable)), style = "description_title_label_style"})
		configTable.add({type = "label", name = "currentWidthLabel", caption = "Emitter width:"})
		local width = configTable.add({type = "table", name = "width", colspan = 2})
		width.add({type = "textfield", name = "emitterWidth", style = "distancetext"}).text = emitterTable["6"]
		width.add({type = "label", name = "emitterMaxWidth", caption = "Max: " .. tostring(emitterDefaultWidth + getEmitterBonusWidth(emitterTable)), style = "description_title_label_style"})
		configTable.add({type = "label", name = "upgradesLabel", caption = "Upgrades applied:"})
		
		local upgrades = configTable.add({type = "table", name = "upgrades", colspan = 2})
		if emitterTable["12"] ~= 0 then
			upgrades.add({type = "button", name = "distanceUpgrades", caption = "x" .. tostring(emitterTable["12"]), style = "advanced-circuit"})
		else
			upgrades.add({type = "button", name = "distanceUpgrades", caption = "", style = "noitem"})
		end
		if emitterTable["13"] ~= 0 then
			upgrades.add({type = "button", name = "widthUpgrades", caption = "x" .. tostring(emitterTable["13"]), style = "processing-unit"})
		else
			upgrades.add({type = "button", name = "widthUpgrades", caption = "", style = "noitem"})
		end
		
		frame.add({type = "button", name = "emitterHelpButton", caption = "?"})
		frame.add({type = "button", name = "removeAllButton", caption = "Remove all upgrades"})
		frame.add({type = "button", name = "applyButton", caption = "Apply"})
		
		if glob.emitterConfigGUIs == nil then
			glob.emitterConfigGUIs = {}
		end
		
		glob.emitterConfigGUIs["I" .. playerIndex] = {}
		glob.emitterConfigGUIs["I" .. playerIndex][1] = emitterTable
	end
end
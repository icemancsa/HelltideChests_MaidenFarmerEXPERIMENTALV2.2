local heart_insertion = {}
local circular_movement = require("functions/circular_movement")

-- FSM States
local States = {
    IDLE = "IDLE",
    MOVING = "MOVING",
    INTERACTING = "INTERACTING"
}

-- State variables
local currentState = States.IDLE
local targetAltars = {}
local currentTargetIndex = 1
local blacklist = {}
local expiration_time = 10  -- blacklist expiration time
local failed_attempts = 0
local max_attempts = 3
local last_interaction_time = 0
local interaction_timeout = 5  -- 5 seconds timeout between interactions
local last_move_request_time = 0
local move_request_interval = 2  -- minimum interval between move requests

-- Helper functions
local function getDistance(pos1, pos2)
    return pos1:dist_to(pos2)
end

local function get_position_string(pos)
    if not pos then return "unknown position" end
    return string.format("(%.2f, %.2f, %.2f)", pos:x(), pos:y(), pos:z())
end

local function is_blacklisted(obj)
    if not obj then return false end
    local obj_name = obj:get_skin_name()
    local obj_pos = obj:get_position()
    local current_time = os.clock()
    
    for i, blacklisted_obj in ipairs(blacklist) do
        if blacklisted_obj.name == obj_name and blacklisted_obj.position:dist_to(obj_pos) < 1.0 then
            if current_time > blacklisted_obj.expiration_time then
                table.remove(blacklist, i)
                return false
            end
            return true
        end
    end
    
    return false
end

local function add_to_blacklist(obj)
    if not obj then return end
    local obj_name = obj:get_skin_name()
    local obj_pos = obj:get_position()
    local current_time = os.clock()

    local pos_string = get_position_string(obj_pos)

    table.insert(blacklist, {
        name = obj_name, 
        position = obj_pos, 
        expiration_time = current_time + expiration_time
    })
    --console.print("Added " .. obj_name .. " to blacklist at position: " .. pos_string)
end

local function request_move_to_position(target_pos)
    local current_time = os.clock()
    if current_time - last_move_request_time >= move_request_interval then
        pathfinder.request_move(target_pos)
        last_move_request_time = current_time
        return true
    end
    return false
end

local function is_helltide_boss_spawn_present()
    local actors = actors_manager.get_all_actors()
    for _, actor in ipairs(actors) do
        local name = actor:get_skin_name()
        if name == "S04_helltidebossSpawn_egg" then
            return true
        end
    end
    return false
end

-- State functions
local stateFunctions = {
    [States.IDLE] = function(menu_elements, helltide_final_maidenpos, explorer_circle_radius)
        if not menu_elements.main_helltide_maiden_auto_plugin_insert_hearts:get() then
            return States.IDLE
        end

        if is_helltide_boss_spawn_present() then
            --console.print("Helltide boss spawn present, remaining in IDLE")
            return States.IDLE
        end

        local current_hearts = get_helltide_coin_hearts()

        if current_hearts > 0 then
            local actors = actors_manager.get_all_actors()
            targetAltars = {}
            for _, actor in ipairs(actors) do
                local name = actor:get_skin_name()
                if name == "S04_SMP_Succuboss_Altar_A_Dyn" and not is_blacklisted(actor) then
                    table.insert(targetAltars, actor)
                end
            end
            if #targetAltars > 0 then
                currentTargetIndex = 1
                failed_attempts = 0
                return States.MOVING
            end
        end

        return States.IDLE
    end,

    [States.MOVING] = function(menu_elements, helltide_final_maidenpos, explorer_circle_radius)
        if #targetAltars == 0 or currentTargetIndex > #targetAltars then 
            return States.IDLE 
        end

        local currentTarget = targetAltars[currentTargetIndex]
        local player_pos = get_player_position()
        local altar_pos = currentTarget:get_position()
        local distance = getDistance(player_pos, altar_pos)
        
        if distance < 2.0 then
            return States.INTERACTING
        else
            request_move_to_position(altar_pos)
            return States.MOVING
        end
    end,

    [States.INTERACTING] = function(menu_elements, helltide_final_maidenpos, explorer_circle_radius)
        if #targetAltars == 0 or currentTargetIndex > #targetAltars then 
            return States.IDLE 
        end

        local currentTarget = targetAltars[currentTargetIndex]
        local current_hearts = get_helltide_coin_hearts()
        if current_hearts > 0 and currentTarget:get_skin_name() == "S04_SMP_Succuboss_Altar_A_Dyn" then
            if currentTarget:is_interactable() then
                console.print("Interacting with altar at position: " .. get_position_string(currentTarget:get_position()))
                interact_object(currentTarget)
                -- Immediately check if the interaction was successful
                if not currentTarget:is_interactable() then
                    console.print("Interaction successful, altar opened")
                    add_to_blacklist(currentTarget)
                    currentTargetIndex = currentTargetIndex + 1
                    failed_attempts = 0
                else
                    --console.print("Interaction failed, attempt " .. (failed_attempts + 1) .. " of " .. max_attempts)
                    failed_attempts = failed_attempts + 1
                end

                if failed_attempts >= max_attempts then
                    --console.print("Maximum attempts reached, moving to next altar")
                    currentTargetIndex = currentTargetIndex + 1
                    failed_attempts = 0
                end

                if currentTargetIndex > #targetAltars then
                    return States.IDLE
                else
                    return States.MOVING
                end
            else
                --console.print("Altar is not interactable, moving to next")
                currentTargetIndex = currentTargetIndex + 1
                return States.MOVING
            end
        else
            --console.print("Unable to interact with current altar, moving to next")
            currentTargetIndex = currentTargetIndex + 1
            if currentTargetIndex > #targetAltars then
                return States.IDLE
            else
                return States.MOVING
            end
        end
    end
}

-- Main heart insertion function
function heart_insertion.update(menu_elements, helltide_final_maidenpos, explorer_circle_radius)
    local local_player = get_local_player()
    if not local_player then return end
    
    if not menu_elements.main_helltide_maiden_auto_plugin_enabled:get() then return end

    -- Pause circular movement when heart insertion is active
    if currentState ~= States.IDLE then
        circular_movement.pause_movement()
    else
        circular_movement.resume_movement()
    end

    if is_helltide_boss_spawn_present() then
        currentState = States.IDLE
        circular_movement.resume_movement()
        return
    end

    local newState = stateFunctions[currentState](menu_elements, helltide_final_maidenpos, explorer_circle_radius)
    if newState ~= currentState then
        currentState = newState
    end

    -- Resume circular movement when heart insertion is complete
    if currentState == States.IDLE then
        circular_movement.resume_movement()
    end
end

-- Function to clear the blacklist
function heart_insertion.clearBlacklist()
    blacklist = {}
    --console.print("Altar blacklist cleared")
end

-- Function to print the blacklist (for debugging)
function heart_insertion.printBlacklist()
    --console.print("Current Altar Blacklist:")
    for i, item in ipairs(blacklist) do
        console.print(string.format("%d: %s at position: %s (expires in %.2f seconds)", 
            i, item.name, get_position_string(item.position), item.expiration_time - os.clock()))
    end
end

return heart_insertion
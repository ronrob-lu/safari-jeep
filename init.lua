-- ==============================================================================
-- VEHICLE MOD FOR LUANTI / MINETEST
-- Features 4 distinct off-road vehicles:
--   1. Safari Jeep (safari_jeep:jeep)         - Reference-matched classic safari vehicle
--   2. GAZ-67 (safari_jeep:gaz67)             - Open Soviet 4x4 military off-roader
--   3. UAZ-469 (safari_jeep:uaz469)           - Enclosed Soviet off-roader (hidden player)
--   4. Classic 4x4 Jeep (safari_jeep:jeep_4x4) - Open-top American 4x4 trail off-roader
--
-- Independent WASD steering (free camera look), cruise control, and two seats.
-- Author: ronrob-lu (2026) | License: MIT
-- ==============================================================================

local modname = minetest.get_current_modname() or "safari_jeep"

local atan2 = math.atan2 or math.atan

-- -----------------------------------------------------------------------------
-- Driving & Physics Configuration
-- -----------------------------------------------------------------------------
local MAX_SPEED         = 13.5    -- Max forward speed in nodes/sec (~48 km/h)
local MAX_REVERSE_SPEED = -4.5    -- Max reverse speed in nodes/sec (~16 km/h)
local ACCEL_RATE        = 5.0     -- Throttle acceleration (W key) in nodes/s^2
local BRAKE_RATE        = 6.5     -- Brake deceleration (S key) in nodes/s^2
local HANDBRAKE_RATE    = 14.0    -- Emergency brake (Spacebar) in nodes/s^2
local TURN_SPEED_MOVING = 1.6     -- Steering yaw speed while moving (rad/s)
local TURN_SPEED_STATIC = 1.2     -- Steering yaw speed while stationary (rad/s)
local GRAVITY           = -9.81   -- Natural falling gravity
local STEP_HEIGHT       = 1.25    -- Can climb 1-node steps and slopes smoothly

local SEAT_ATTACH_ROT   = {x = 0, y = 0, z = 0}

-- -----------------------------------------------------------------------------
-- Helper Functions
-- -----------------------------------------------------------------------------
local function get_yaw(obj)
    if obj.get_rotation then
        local r = obj:get_rotation()
        return (r and r.y) or 0
    elseif obj.get_yaw then
        return obj:get_yaw() or 0
    end
    return 0
end

local function set_rotation(obj, pitch, yaw, roll)
    if obj.set_rotation then
        obj:set_rotation({x = pitch or 0, y = yaw or 0, z = roll or 0})
    elseif obj.set_yaw then
        obj:set_yaw(yaw or 0)
    end
end

local function set_player_attached_state(player, attached)
    if not player or not player:is_player() then return end
    local name = player:get_player_name()

    -- 1. Notify MTG / MCL animation loops that player is attached
    -- Setting player_attached prevents globalsteps from resetting animation to walk/stand
    if player_api and player_api.player_attached then
        player_api.player_attached[name] = attached or nil
    end
    if default and default.player_attached then
        default.player_attached[name] = attached or nil
    end
    if mcl_player and mcl_player.player_attached then
        mcl_player.player_attached[name] = attached or nil
    end

    -- 2. Trigger sitting / standing animation across Minetest Game and MineClone / VoxeLibre
    local anim = attached and "sit" or "stand"
    if mcl_player and mcl_player.player_set_animation then
        pcall(function() mcl_player.player_set_animation(player, anim, 30) end)
    elseif player_api and player_api.set_animation then
        pcall(function() player_api.set_animation(player, anim, 30) end)
    elseif default and default.player_set_animation then
        pcall(function() default.player_set_animation(player, anim, 30) end)
    elseif player.set_animation then
        pcall(function()
            if attached then
                player:set_animation({x = 81, y = 160}, 30, 0)
            else
                player:set_animation({x = 0, y = 79}, 30, 0)
            end
        end)
    end
end

local function get_forward_vector(yaw)
    return {
        x = -math.sin(yaw),
        y = 0,
        z =  math.cos(yaw)
    }
end

local function get_right_vector(yaw)
    return {
        x =  math.cos(yaw),
        y = 0,
        z =  math.sin(yaw)
    }
end

local function safe_sound_play(name, spec)
    local ok, handle = pcall(function()
        return minetest.sound_play(name, spec)
    end)
    if ok then return handle end
    return nil
end

local function safe_sound_stop(handle)
    if handle then
        pcall(function()
            minetest.sound_stop(handle)
        end)
    end
end

-- -----------------------------------------------------------------------------
-- Vehicle Specifications
-- -----------------------------------------------------------------------------
local VEHICLE_DEFS = {
    jeep = {
        subname          = "jeep",
        title            = "Safari Jeep",
        desc             = "Safari Jeep\nRugged expedition vehicle with cruise control and 2 seats.\nRight-click to board, Shift to exit.",
        mesh             = "safari_jeep.obj",
        texture          = "safari_jeep.png",
        inv_image        = "safari_jeep_inv.png",
        -- Scaled 1.2x (0.2 times bigger):
        collisionbox     = {-1.20, 0.0, -1.20, 1.20, 1.74, 1.20},
        selectionbox     = {-1.30, 0.0, -1.98, 1.30, 1.80, 2.04},
        driver_offset    = {x =  4.8, y = 8.6, z = -0.6},
        passenger_offset = {x = -4.8, y = 8.6, z = -0.6},
        fpv_eye_y        = 10.2, -- 3 blocks higher FPV view aligned to player seat
        hide_player      = false,
        exhaust_offset   = {x = -0.48, y = 0.45, z = -1.8},
        hud_title        = "SAFARI JEEP",
        hud_color        = 0xFFA500, -- Safari Gold
        aliases          = {"safari_jeep:jeep", "safari-jeep:jeep"},
        recipe           = {
            {"default:steel_ingot", "default:glass",       "default:steel_ingot"},
            {"default:steel_ingot", "group:wood",          "default:steel_ingot"},
            {"default:steel_ingot", "default:steel_ingot", "default:steel_ingot"},
        },
    },
    gaz67 = {
        subname          = "gaz67",
        title            = "GAZ-67",
        desc             = "GAZ-67\nSoviet 4x4 military off-roader with open cabin and 2 seats.\nRight-click to board, Shift to exit.",
        mesh             = "gaz_67.obj",
        texture          = "gaz_67.png",
        inv_image        = "gaz_67_inv.png",
        collisionbox     = {-0.88, 0.0, -1.00, 0.88, 1.55, 1.00},
        selectionbox     = {-0.95, 0.0, -1.95, 0.95, 1.60, 1.50},
        -- Driver on steering wheel side (3.5), passenger (-3.5), FPV aligned to seat + 3 blocks higher (5.2)
        driver_offset    = {x =  3.5, y = 6.8, z = -4.0},
        passenger_offset = {x = -3.5, y = 6.8, z = -4.0},
        fpv_eye_y        = 8.2,
        hide_player      = false,
        exhaust_offset   = {x = -0.4, y = 0.35, z = -1.8},
        hud_title        = "GAZ-67",
        hud_color        = 0x8BC34A, -- Military Light Green
        aliases          = {"safari_jeep:gaz-67", "safari-jeep:gaz67", "safari_jeep:gaz_67"},
        recipe           = {
            {"default:steel_ingot", "default:glass",       "default:steel_ingot"},
            {"group:wood",          "default:steel_ingot", "group:wood"},
            {"default:steel_ingot", "default:steel_ingot", "default:steel_ingot"},
        },
    },
    uaz469 = {
        subname          = "uaz469",
        title            = "UAZ-469",
        desc             = "UAZ-469\nSoviet enclosed military off-road vehicle with 2 seats.\nPlayer is seated inside and hidden from outside.\nRight-click to board, Shift to exit.",
        mesh             = "uaz_469.obj",
        texture          = "uaz_469.png",
        inv_image        = "uaz_469_inv.png",
        collisionbox     = {-1.00, 0.0, -1.00, 1.00, 1.90, 1.00},
        selectionbox     = {-1.05, 0.0, -2.15, 1.05, 1.95, 2.05},
        driver_offset    = {x = -3.8, y = 7.5, z = 0.8},
        passenger_offset = {x =  3.8, y = 7.5, z = 0.8},
        hide_player      = true,  -- In UAZ-469 player is inside and hidden without sitting animation
        exhaust_offset   = {x = -0.45, y = 0.40, z = -2.1},
        hud_title        = "UAZ-469",
        hud_color        = 0x4CAF50, -- Forest Green
        aliases          = {"safari_jeep:uaz-469", "safari-jeep:uaz469", "safari_jeep:uaz_469"},
        recipe           = {
            {"default:steel_ingot", "default:glass",       "default:steel_ingot"},
            {"default:steel_ingot", "default:glass",       "default:steel_ingot"},
            {"default:steel_ingot", "default:steel_ingot", "default:steel_ingot"},
        },
    },
    jeep_4x4 = {
        subname          = "jeep_4x4",
        title            = "Classic 4x4 Jeep",
        desc             = "Classic 4x4 Jeep\nAmerican 4x4 trail off-roader with roll cage, leather bucket seats, and cruise control.\nRight-click to board, Shift to exit.",
        mesh             = "jeep_4x4.obj",
        texture          = "jeep_4x4.png",
        inv_image        = "jeep_4x4_inv.png",
        collisionbox     = {-1.00, 0.0, -1.00, 1.00, 1.65, 1.00},
        selectionbox     = {-1.15, 0.0, -1.75, 1.15, 1.70, 1.65},
        driver_offset    = {x =  4.9, y = 6.5, z = -1.9},
        passenger_offset = {x = -4.9, y = 6.5, z = -1.9},
        fpv_eye_y        = 8.2,
        hide_player      = false,
        exhaust_offset   = {x = -0.50, y = 0.30, z = -1.75},
        hud_title        = "4x4 JEEP",
        hud_color        = 0x4CAF50, -- Trail Green
        aliases          = {
            "safari_jeep:jeep4x4",
            "safari_jeep:classic_jeep",
            "safari_jeep:jeep_classic",
            "safari_jeep:wrangler",
            "safari_jeep:jeep_fbx",
            "safari-jeep:jeep_4x4",
            "safari-jeep:classic_jeep",
        },
        recipe           = {
            {"default:steel_ingot", "default:glass",       "default:steel_ingot"},
            {"group:wool",          "default:steel_ingot", "group:wool"},
            {"default:steel_ingot", "default:steel_ingot", "default:steel_ingot"},
        },
    },
}

-- Registry to track all vehicle entities for global player leave/die events
local REGISTERED_VEHICLE_NAMES = {}

-- -----------------------------------------------------------------------------
-- HUD Management
-- -----------------------------------------------------------------------------
local function show_driver_hud(self, player)
    if not player or not player:is_player() then return end
    if self.driver_hud_id then
        player:hud_remove(self.driver_hud_id)
        self.driver_hud_id = nil
    end

    local vdef = self.vdef
    self.driver_hud_id = player:hud_add({
        hud_elem_type = "text",
        position      = {x = 0.5, y = 0.88},
        offset        = {x = 0, y = 0},
        text          = string.format("%s [CRUISE READY] | W: Speed+ | S: Speed- | A/D: Steer | Space: Brake | Shift: Exit", vdef.hud_title),
        alignment     = {x = 0, y = 0},
        scale         = {x = 100, y = 100},
        number        = vdef.hud_color,
    })
end

local function update_driver_hud(self, player)
    if not player or not player:is_player() or not self.driver_hud_id then return end
    local kmh = math.floor(math.abs(self.speed) * 3.6 + 0.5)
    local gear = "PARK"
    if self.speed > 0.3 then
        gear = "DRIVE (CRUISE)"
    elseif self.speed < -0.3 then
        gear = "REVERSE"
    end

    local text = string.format(
        "🚙 %s  |  Speed: %d km/h  [%s]  |  [W] Accel  [S] Slow/Rev  [A/D] Steer  [Space] Brake  [Shift] Exit",
        self.vdef.hud_title, kmh, gear
    )

    pcall(function()
        player:hud_change(self.driver_hud_id, "text", text)
    end)
end

local function remove_driver_hud(self, player)
    if self.driver_hud_id and player and player:is_player() then
        pcall(function()
            player:hud_remove(self.driver_hud_id)
        end)
    end
    self.driver_hud_id = nil
end

local function show_passenger_hud(self, player)
    if not player or not player:is_player() then return end
    if self.passenger_hud_id then
        player:hud_remove(self.passenger_hud_id)
        self.passenger_hud_id = nil
    end

    self.passenger_hud_id = player:hud_add({
        hud_elem_type = "text",
        position      = {x = 0.5, y = 0.88},
        offset        = {x = 0, y = 0},
        text          = string.format("🚙 %s [PASSENGER SEAT]  |  Enjoy the ride!  |  [Shift] Exit", self.vdef.hud_title),
        alignment     = {x = 0, y = 0},
        scale         = {x = 100, y = 100},
        number        = 0x4FC3F7, -- Sky blue
    })
end

local function remove_passenger_hud(self, player)
    if self.passenger_hud_id and player and player:is_player() then
        pcall(function()
            player:hud_remove(self.passenger_hud_id)
        end)
    end
    self.passenger_hud_id = nil
end

-- -----------------------------------------------------------------------------
-- Entity Factory: Creates entity prototype from vehicle definition
-- -----------------------------------------------------------------------------
local function create_vehicle_entity(vdef)
    local ent = {
        vdef                = vdef,
        initial_properties  = {
            physical            = true,
            collide_with_objects= true,
            collisionbox        = vdef.collisionbox,
            selectionbox        = vdef.selectionbox,
            visual              = "mesh",
            mesh                = vdef.mesh,
            textures            = {vdef.texture},
            visual_size         = {x = 1, y = 1, z = 1},
            stepheight          = STEP_HEIGHT,
            hp_max              = 100,
            makes_footstep_sound= false,
        },

        speed               = 0.0,
        v_yaw               = 0.0,
        v_pitch             = 0.0,
        driver              = nil,
        passenger           = nil,
        driver_orig_vsize   = nil,
        passenger_orig_vsize= nil,
        engine_sound_handle = nil,
        last_horn_time      = 0,
        smoke_timer         = 0,
        last_pos            = nil,
        stall_timer         = 0,
    }

    -- Detach driver
    function ent:detach_driver()
        local driver = self.driver
        if not driver then return end

        remove_driver_hud(self, driver)
        safe_sound_stop(self.engine_sound_handle)
        self.engine_sound_handle = nil

        if driver:is_player() then
            -- Reset eye offset if player is leaving vehicle
            if driver.set_eye_offset then
                pcall(function()
                    driver:set_eye_offset({x = 0, y = 0, z = 0}, {x = 0, y = 0, z = 0})
                end)
            end

            -- Restore player visibility if hidden
            if self.vdef.hide_player then
                driver:set_properties({
                    visual_size = self.driver_orig_vsize or {x = 1, y = 1, z = 1}
                })
            else
                set_player_attached_state(driver, false)
            end

            driver:set_detach()

            -- Eject to the driver's side
            local pos = self.object:get_pos()
            if pos then
                local right = get_right_vector(self.v_yaw)
                local side_sign = (self.vdef.driver_offset.x >= 0) and 1 or -1
                driver:set_pos({
                    x = pos.x + right.x * (side_sign * 1.8),
                    y = pos.y + 0.1,
                    z = pos.z + right.z * (side_sign * 1.8)
                })
            end
        end

        self.driver = nil
        self.driver_orig_vsize = nil
        self.speed = 0.0
    end

    -- Detach passenger
    function ent:detach_passenger()
        local passenger = self.passenger
        if not passenger then return end

        remove_passenger_hud(self, passenger)

        if passenger:is_player() then
            -- Reset eye offset if player is leaving vehicle
            if passenger.set_eye_offset then
                pcall(function()
                    passenger:set_eye_offset({x = 0, y = 0, z = 0}, {x = 0, y = 0, z = 0})
                end)
            end

            -- Restore player visibility if hidden
            if self.vdef.hide_player then
                passenger:set_properties({
                    visual_size = self.passenger_orig_vsize or {x = 1, y = 1, z = 1}
                })
            else
                set_player_attached_state(passenger, false)
            end

            passenger:set_detach()

            -- Eject to the passenger's side
            local pos = self.object:get_pos()
            if pos then
                local right = get_right_vector(self.v_yaw)
                local side_sign = (self.vdef.passenger_offset.x >= 0) and 1 or -1
                passenger:set_pos({
                    x = pos.x + right.x * (side_sign * 1.8),
                    y = pos.y + 0.1,
                    z = pos.z + right.z * (side_sign * 1.8)
                })
            end
        end

        self.passenger = nil
        self.passenger_orig_vsize = nil
    end

    -- Attach driver
    function ent:attach_driver(player)
        if not player or not player:is_player() then return end
        self.driver = player

        player:set_attach(self.object, "", self.vdef.driver_offset, SEAT_ATTACH_ROT)

        -- Hide player if vehicle is enclosed (e.g. UAZ-469) - DO NOT sit hidden player!
        if self.vdef.hide_player then
            local props = player:get_properties()
            self.driver_orig_vsize = props and props.visual_size or {x = 1, y = 1, z = 1}
            player:set_properties({visual_size = {x = 0, y = 0, z = 0}})
        else
            set_player_attached_state(player, true)
            if self.vdef.fpv_eye_y and player.set_eye_offset then
                local eye_x = (self.vdef.driver_offset.x or 0) / 10
                local eye_y = self.vdef.fpv_eye_y
                local eye_z = (self.vdef.driver_offset.z or 0) / 10
                pcall(function()
                    player:set_eye_offset({x = eye_x, y = eye_y, z = eye_z}, {x = 0, y = 0, z = 0})
                end)
            end
        end

        show_driver_hud(self, player)

        local pos = self.object:get_pos()
        self.engine_sound_handle = safe_sound_play("safari_jeep_engine", {
            pos = pos,
            gain = 0.4,
            loop = true,
            max_hear_distance = 25,
        })
    end

    -- Attach passenger
    function ent:attach_passenger(player)
        if not player or not player:is_player() then return end
        self.passenger = player

        player:set_attach(self.object, "", self.vdef.passenger_offset, SEAT_ATTACH_ROT)

        -- Hide player if vehicle is enclosed (e.g. UAZ-469) - DO NOT sit hidden player!
        if self.vdef.hide_player then
            local props = player:get_properties()
            self.passenger_orig_vsize = props and props.visual_size or {x = 1, y = 1, z = 1}
            player:set_properties({visual_size = {x = 0, y = 0, z = 0}})
        else
            set_player_attached_state(player, true)
            if self.vdef.fpv_eye_y and player.set_eye_offset then
                local eye_x = (self.vdef.passenger_offset.x or 0) / 10
                local eye_y = self.vdef.fpv_eye_y
                local eye_z = (self.vdef.passenger_offset.z or 0) / 10
                pcall(function()
                    player:set_eye_offset({x = eye_x, y = eye_y, z = eye_z}, {x = 0, y = 0, z = 0})
                end)
            end
        end

        show_passenger_hud(self, player)
    end

    -- Entity activation
    function ent:on_activate(staticdata, dtime_s)
        self.object:set_armor_groups({immortal = 1})
        self.object:set_properties({
            visual_size  = {x = 1, y = 1, z = 1},
            mesh         = self.vdef.mesh,
            textures     = {self.vdef.texture},
            collisionbox = self.vdef.collisionbox,
            selectionbox = self.vdef.selectionbox,
        })
        self.v_yaw = get_yaw(self.object)
        self.speed = 0.0

        if staticdata and staticdata ~= "" then
            local data = minetest.deserialize(staticdata)
            if type(data) == "table" then
                if data.v_yaw then self.v_yaw = data.v_yaw end
                if data.speed then self.speed = data.speed end
            end
        end

        set_rotation(self.object, 0, self.v_yaw, 0)
        self.object:set_acceleration({x = 0, y = GRAVITY, z = 0})
    end

    -- Static data serialization
    function ent:get_staticdata()
        return minetest.serialize({
            v_yaw = self.v_yaw,
            speed = 0.0,
        })
    end

    -- Boarding / Dismounting on right-click
    function ent:on_rightclick(clicker)
        if not clicker or not clicker:is_player() then return end
        local name = clicker:get_player_name()

        if self.driver and self.driver:get_player_name() == name then
            self:detach_driver()
            return
        end
        if self.passenger and self.passenger:get_player_name() == name then
            self:detach_passenger()
            return
        end

        if not self.driver then
            self:attach_driver(clicker)
            minetest.chat_send_player(name, string.format("🚙 You took the %s Driver seat! [W] Speed up, [S] Slow down, [A/D] Steer, [Space] Brake, [Shift] Exit", self.vdef.title))
        elseif not self.passenger then
            self:attach_passenger(clicker)
            minetest.chat_send_player(name, string.format("🚙 You took the %s Passenger seat! Press [Shift] to exit.", self.vdef.title))
        else
            minetest.chat_send_player(name, string.format("🚙 This %s is full! (2/2 seats occupied)", self.vdef.title))
        end
    end

    -- Punch / Retrieval / Horn
    function ent:on_punch(puncher, time_from_last_punch, tool_capabilities, dir)
        if not puncher or not puncher:is_player() then return end
        local ctrl = puncher:get_player_control()

        -- Sneak + Punch on empty vehicle retrieves it to inventory
        if ctrl.sneak and not self.driver and not self.passenger then
            local inv = puncher:get_inventory()
            local item = ItemStack(modname .. ":" .. self.vdef.subname)
            if inv and inv:room_for_item("main", item) then
                inv:add_item("main", item)
            else
                minetest.add_item(self.object:get_pos(), item)
            end

            safe_sound_stop(self.engine_sound_handle)
            self.object:remove()
            return
        end

        -- Honk the horn if driver punches while seated
        if self.driver and self.driver:get_player_name() == puncher:get_player_name() then
            local now = minetest.get_gametime()
            if now - self.last_horn_time >= 0.5 then
                self.last_horn_time = now
                safe_sound_play("safari_jeep_horn", {
                    pos = self.object:get_pos(),
                    gain = 0.9,
                    max_hear_distance = 35,
                })
            end
        end
    end

    -- Physics & Input loop
    function ent:on_step(dtime)
        local pos = self.object:get_pos()
        if not pos then return end

        -- 1. Validate attached players
        if self.driver and (not self.driver:is_player() or self.driver:get_pos() == nil) then
            self:detach_driver()
        end
        if self.passenger and (not self.passenger:is_player() or self.passenger:get_pos() == nil) then
            self:detach_passenger()
        end

        -- 2. Process Passenger dismount
        if self.passenger then
            local p_ctrl = self.passenger:get_player_control()
            if p_ctrl and p_ctrl.sneak then
                self:detach_passenger()
            end
        end

        -- 3. Process Driver controls
        if self.driver then
            local ctrl = self.driver:get_player_control()
            if ctrl then
                if ctrl.sneak then
                    self:detach_driver()
                    return
                end

                -- Cruise Control Throttle
                if ctrl.up then
                    self.speed = math.min(MAX_SPEED, self.speed + ACCEL_RATE * dtime)
                elseif ctrl.down then
                    self.speed = math.max(MAX_REVERSE_SPEED, self.speed - BRAKE_RATE * dtime)
                end

                -- Handbrake
                if ctrl.jump then
                    if self.speed > 0 then
                        self.speed = math.max(0, self.speed - HANDBRAKE_RATE * dtime)
                    elseif self.speed < 0 then
                        self.speed = math.min(0, self.speed + HANDBRAKE_RATE * dtime)
                    end
                end

                -- Independent Steering (A / D)
                local current_turn_rate = (math.abs(self.speed) > 1.0) and TURN_SPEED_MOVING or TURN_SPEED_STATIC
                local steer_polarity = (self.speed < -0.2) and -1.0 or 1.0

                if ctrl.left then
                    self.v_yaw = self.v_yaw + current_turn_rate * dtime * steer_polarity
                end
                if ctrl.right then
                    self.v_yaw = self.v_yaw - current_turn_rate * dtime * steer_polarity
                end

                -- Horn on click
                if ctrl.dig or ctrl.LMB then
                    local now = minetest.get_gametime()
                    if now - self.last_horn_time >= 0.6 then
                        self.last_horn_time = now
                        safe_sound_play("safari_jeep_horn", {
                            pos = pos,
                            gain = 0.9,
                            max_hear_distance = 35,
                        })
                    end
                end

                update_driver_hud(self, self.driver)
            end
        else
            -- Decelerate to stop when driver leaves
            if math.abs(self.speed) > 0.1 then
                local decel = HANDBRAKE_RATE * dtime
                if self.speed > 0 then
                    self.speed = math.max(0, self.speed - decel)
                else
                    self.speed = math.min(0, self.speed + decel)
                end
            else
                self.speed = 0.0
            end
        end

        self.v_yaw = self.v_yaw % (math.pi * 2)

        -- 4. Calculate Velocity Vector
        local fwd = get_forward_vector(self.v_yaw)
        local target_vx = fwd.x * self.speed
        local target_vz = fwd.z * self.speed

        local current_vel = self.object:get_velocity() or {x = 0, y = 0, z = 0}
        local vy = current_vel.y

        self.object:set_acceleration({x = 0, y = GRAVITY, z = 0})

        -- Stall / collision detection
        if self.last_pos and dtime > 0 and math.abs(self.speed) > 1.5 then
            local moved_dist = math.sqrt((pos.x - self.last_pos.x)^2 + (pos.z - self.last_pos.z)^2)
            local expected_dist = math.abs(self.speed) * dtime
            if moved_dist < expected_dist * 0.12 then
                self.stall_timer = self.stall_timer + dtime
                if self.stall_timer > 0.25 then
                    self.speed = 0.0
                    self.stall_timer = 0
                end
            else
                self.stall_timer = 0
            end
        end
        self.last_pos = {x = pos.x, y = pos.y, z = pos.z}

        -- Pitch calculation for slopes
        local target_pitch = 0.0
        if math.abs(self.speed) > 0.5 then
            local slope_angle = atan2(vy, math.max(0.5, math.abs(self.speed)))
            slope_angle = math.max(-0.45, math.min(0.45, slope_angle))
            target_pitch = -slope_angle * 0.7
        end
        self.v_pitch = self.v_pitch + (target_pitch - self.v_pitch) * math.min(1.0, dtime * 6.0)

        set_rotation(self.object, self.v_pitch, self.v_yaw, 0)
        self.object:set_velocity({x = target_vx, y = vy, z = target_vz})

        -- 5. Exhaust smoke particles
        self.smoke_timer = self.smoke_timer + dtime
        if self.smoke_timer > 0.12 then
            self.smoke_timer = 0
            if math.abs(self.speed) > 0.2 or (self.driver and math.random() < 0.3) then
                local right = get_right_vector(self.v_yaw)
                local exh = self.vdef.exhaust_offset
                local exh_x = pos.x + fwd.x * exh.z + right.x * exh.x
                local exh_y = pos.y + exh.y
                local exh_z = pos.z + fwd.z * exh.z + right.z * exh.x

                minetest.add_particle({
                    pos = {x = exh_x, y = exh_y, z = exh_z},
                    velocity = {
                        x = -fwd.x * 0.8 + (math.random() - 0.5) * 0.2,
                        y = 0.2 + math.random() * 0.3,
                        z = -fwd.z * 0.8 + (math.random() - 0.5) * 0.2,
                    },
                    acceleration = {x = 0, y = 0.4, z = 0},
                    expirationtime = 0.7,
                    size = 1.2 + math.random() * 0.8,
                    collisiondetection = false,
                    vertical = false,
                    texture = "safari_jeep_smoke.png",
                })
            end
        end
    end

    -- Clean up on death / removal
    function ent:on_deactivate()
        safe_sound_stop(self.engine_sound_handle)
        self:detach_driver()
        self:detach_passenger()
    end

    return ent
end

-- -----------------------------------------------------------------------------
-- Register All 3 Vehicles
-- -----------------------------------------------------------------------------
for key, vdef in pairs(VEHICLE_DEFS) do
    local full_name = modname .. ":" .. vdef.subname
    REGISTERED_VEHICLE_NAMES[full_name] = true

    -- 1. Register Entity
    local ent = create_vehicle_entity(vdef)
    minetest.register_entity(full_name, ent)

    -- 2. Register Craftitem (Inventory Item)
    minetest.register_craftitem(full_name, {
        description     = vdef.desc,
        inventory_image = vdef.inv_image,
        wield_image     = vdef.inv_image,
        stack_max       = 1,

        on_place = function(itemstack, placer, pointed_thing)
            if pointed_thing.type ~= "node" then return itemstack end

            local above = pointed_thing.above
            local spawn_pos = {x = above.x, y = above.y + 0.1, z = above.z}

            local yaw = 0
            if placer and placer:is_player() then
                yaw = placer:get_look_horizontal() or 0
            end

            local obj = minetest.add_entity(spawn_pos, full_name)
            if obj then
                set_rotation(obj, 0, yaw, 0)
                local e = obj:get_luaentity()
                if e then
                    e.v_yaw = yaw
                end

                if not (minetest.is_creative_mode and minetest.is_creative_mode(placer:get_player_name())) then
                    itemstack:take_item()
                end
            end

            return itemstack
        end,
    })

    -- 3. Optional Crafting Recipe
    if minetest.get_modpath("default") and vdef.recipe then
        minetest.register_craft({
            output = full_name,
            recipe = vdef.recipe,
        })
    end

    -- 4. Aliases
    if vdef.aliases then
        for _, alias in ipairs(vdef.aliases) do
            if alias ~= full_name then
                minetest.register_alias(alias, full_name)
            end
        end
    end
end

-- -----------------------------------------------------------------------------
-- Global Player Event Hooks (Disconnection & Death Safety)
-- -----------------------------------------------------------------------------
local function clean_player_on_vehicle(player)
    if not player or not player:is_player() then return end
    local attach = player:get_attach()
    if attach then
        local ent = attach:get_luaentity()
        if ent and ent.name and REGISTERED_VEHICLE_NAMES[ent.name] then
            if ent.driver and ent.driver:get_player_name() == player:get_player_name() then
                ent:detach_driver()
            elseif ent.passenger and ent.passenger:get_player_name() == player:get_player_name() then
                ent:detach_passenger()
            end
        end
    end
    -- Safety guarantee: reset visual_size in case vehicle was unloaded
    pcall(function()
        player:set_properties({visual_size = {x = 1, y = 1, z = 1}})
    end)
    if player.set_eye_offset then
        pcall(function()
            player:set_eye_offset({x = 0, y = 0, z = 0}, {x = 0, y = 0, z = 0})
        end)
    end
    set_player_attached_state(player, false)
end

minetest.register_on_leaveplayer(function(player)
    clean_player_on_vehicle(player)
end)

minetest.register_on_dieplayer(function(player)
    clean_player_on_vehicle(player)
end)

minetest.log("action", "[safari-jeep] Successfully loaded Safari Jeep, GAZ-67, UAZ-469, and Classic 4x4 Jeep (v1.2.0) by ronrob-lu!")

-- FreeFlip.luau
-- mewow!
-- Handles the "free flip" mechanic for air rotations

local RS = game:GetService("ReplicatedStorage")
local CONFIG = require(RS.Shared.MovementConfig)

local FreeFlip = {}

export type FlipState = {
	Active: boolean,
	Pitch: number, -- radians, forward/back tilt
	Roll: number,-- radians, side tilt
	PitchVelocity: number,
	RollVelocity: number,
	LastGroundedUpright: boolean,
	StumbleEndTime: number, -- os.clock() time when stumble ends
}

function FreeFlip.CreateState(): FlipState
	return {
		Active = false,
		Pitch = 0,
		Roll = 0,
		PitchVelocity = 0,
		RollVelocity = 0,
		LastGroundedUpright = true,
		StumbleEndTime = 0,
	}
end

function FreeFlip.Update(
	state: FlipState,
	character: Model, -- Character model for setting Stumbling attribute
	moveInput: Vector2,-- WASD input (X = right/left, Y = forward/back)
	flipPressedThisFrame: boolean,  -- True only on the frame shift is pressed
	flipHeld: boolean, -- True while shift is held
	onGround: boolean,
	groundNormal: Vector3?,
	currentVelocity: Vector3,
	now: number,  -- os.clock() current time
	dt: number
): (FlipState, Vector3, boolean) -- returns updated state, potentially modified velocity, and whether acceleration should be blocked
	
	local FLIP = CONFIG.FreeFlip
	local blockAcceleration = false
	local velocity = currentVelocity
	
	-- Calculate horizontal speed for rotation scaling
	local horizontalVel = vector.create(velocity.X, 0, velocity.Z)
	local horizontalSpeed = vector.magnitude(horizontalVel)
	
	-- Check if currently stumbling
	local isStumbling = now < state.StumbleEndTime
	if isStumbling then
		blockAcceleration = true
	end
	
	-- Activate flip mode on shift press while airborne
	if flipPressedThisFrame and not onGround and not isStumbling then
		state.Active = true
	end
	
	if onGround then
		-- Landing logic
		
		local upVector = FreeFlip.GetUpVectorFromAngles(state.Pitch, state.Roll)
		local effectiveNormal = groundNormal or vector.create(0, 1, 0)
		local uprightDot = vector.dot(upVector, effectiveNormal)
		
		local isUpright = uprightDot >= FLIP.UprightThreshold
		
		if not isUpright and (math.abs(state.Pitch) > 0.1 or math.abs(state.Roll) > 0.1) then
			-- Stumble! Apply speed penalty and lock movement
			local horizontalVel = vector.create(velocity.X, 0, velocity.Z)
			local horizontalSpeed = vector.magnitude(horizontalVel)
			
			if horizontalSpeed > 0.1 then
				local penalizedSpeed = horizontalSpeed * FLIP.StumbleSpeedMultiplier
				local direction = horizontalVel / horizontalSpeed
				velocity = vector.create(
					direction.X * penalizedSpeed,
					velocity.Y,
					direction.Z * penalizedSpeed
				)
			end
			
			-- Start stumble lock
			state.StumbleEndTime = now + FLIP.StumbleDuration
			character:SetAttribute("Stumbling", true)
			blockAcceleration = true
		else
			-- Clean landing, clear stumble if it was set
			if character:GetAttribute("Stumbling") then
				character:SetAttribute("Stumbling", false)
			end
			
			-- Prevent physics burst by clamping to pre-flip speed
			local horizontalVel = vector.create(velocity.X, 0, velocity.Z)
			local horizontalSpeed = vector.magnitude(horizontalVel)
			if horizontalSpeed > 50 then
				local direction = horizontalVel / horizontalSpeed
				velocity = vector.create(direction.X * 50, velocity.Y, direction.Z * 50)
			end
		end
		
		-- Snap back to upright on ground
		state.Pitch = 0
		state.Roll = 0
		state.PitchVelocity = 0
		state.RollVelocity = 0
		state.Active = false
		state.LastGroundedUpright = isUpright
		
		-- Clear flip attributes
		character:SetAttribute("FlipPitch", 0)
		character:SetAttribute("FlipRoll", 0)
		
		return state, velocity, blockAcceleration
	end
	
	-- Clear stumbling attribute when stumble duration ends
	if not isStumbling and character:GetAttribute("Stumbling") then
		character:SetAttribute("Stumbling", false)
	end
	
	-- In the air with flip active
	if state.Active and not isStumbling then
		blockAcceleration = true
		
		-- Normalize angles to [-pi, pi] so full rotations still count as upright
		local function NormalizeAngle(angle: number): number
			local TWO_PI = math.pi * 2
			angle = angle % TWO_PI
			if angle > math.pi then
				angle = angle - TWO_PI
			elseif angle < -math.pi then
				angle = angle + TWO_PI
			end
			return angle
		end
		
		local normalizedPitch = NormalizeAngle(state.Pitch)
		local normalizedRoll = NormalizeAngle(state.Roll)
		local totalTilt = math.abs(normalizedPitch) + math.abs(normalizedRoll)
		local closeToUpright = totalTilt < FLIP.FlipExitTolerance
		
		if closeToUpright and not flipHeld then
			-- Snap state to normalized angles so correction works properly
			state.Pitch = normalizedPitch
			state.Roll = normalizedRoll
			
			-- Auto-correct to fully upright and exit flip mode
			local correctionSpeed = FLIP.AutoCorrectionSpeed * dt
			
			if math.abs(state.Pitch) > 0.01 then
				local sign = state.Pitch > 0 and 1 or -1
				state.Pitch = state.Pitch - sign * math.min(correctionSpeed, math.abs(state.Pitch))
			else
				state.Pitch = 0
			end
			
			if math.abs(state.Roll) > 0.01 then
				local sign = state.Roll > 0 and 1 or -1
				state.Roll = state.Roll - sign * math.min(correctionSpeed, math.abs(state.Roll))
			else
				state.Roll = 0
			end
			
			state.PitchVelocity = 0
			state.RollVelocity = 0
			
			-- Check if fully corrected - exit flip mode
			if math.abs(state.Pitch) < 0.01 and math.abs(state.Roll) < 0.01 then
				state.Active = false
				state.Pitch = 0
				state.Roll = 0
				blockAcceleration = false
			end
			
			character:SetAttribute("FlipPitch", state.Pitch)
			character:SetAttribute("FlipRoll", state.Roll)
		else
			-- Still in flip mode - WASD controls rotation
			local speedAlpha = math.clamp(
				(horizontalSpeed - FLIP.RotationSpeedScaleStart) / (FLIP.RotationSpeedScaleEnd - FLIP.RotationSpeedScaleStart),
				0, 1
			)
			local rotSpeed = FLIP.RotationSpeedMin + (FLIP.RotationSpeedMax - FLIP.RotationSpeedMin) * speedAlpha
			
			-- W/S controls pitch (forward/back flip)
			-- A/D controls roll (side flip)
			local pitchInput = -moveInput.Y -- W = forward flip (negative pitch), S = backward
			local rollInput = -moveInput.X -- A = left roll, D = right roll
			
			-- Apply rotation with some smoothing via velocity
			local accel = FLIP.RotationAcceleration
			
			state.PitchVelocity = state.PitchVelocity + (pitchInput * accel * dt)
			state.RollVelocity = state.RollVelocity + (rollInput * accel * dt)
			
			-- Clamp velocities
			state.PitchVelocity = math.clamp(state.PitchVelocity, -rotSpeed, rotSpeed)
			state.RollVelocity = math.clamp(state.RollVelocity, -rotSpeed, rotSpeed)
			
			-- Apply drag when no input
			if math.abs(pitchInput) < 0.1 then
				state.PitchVelocity = state.PitchVelocity * (1 - FLIP.RotationDrag * dt)
			end
			if math.abs(rollInput) < 0.1 then
				state.RollVelocity = state.RollVelocity * (1 - FLIP.RotationDrag * dt)
			end
			
			-- Update angles
			state.Pitch = state.Pitch + state.PitchVelocity * dt
			state.Roll = state.Roll + state.RollVelocity * dt
			
			-- Set attributes for camera to read
			character:SetAttribute("FlipPitch", state.Pitch)
			character:SetAttribute("FlipRoll", state.Roll)
		end
	end
	
	return state, velocity, blockAcceleration
end

-- Helper to get the up vector from pitch/roll angles
function FreeFlip.GetUpVectorFromAngles(pitch: number, roll: number): Vector3
	-- Start with world up, apply rotations
	local cf = CFrame.Angles(pitch, 0, roll)
	return cf.UpVector
end

-- Build the final CFrame with flip rotation applied
-- cameraLookFlat should be the camera's look vector projected onto XZ plane
function FreeFlip.BuildCFrame(
	state: FlipState,
	position: Vector3,
	cameraLookFlat: Vector3
): CFrame
	-- Base CFrame facing camera direction (yaw only)
	local baseCF = CFrame.lookAt(position, position + cameraLookFlat, vector.create(0, 1, 0))
	
	-- Apply pitch (around local X/right axis) and roll (around local Z/look axis)
	local rotationCF = CFrame.Angles(state.Pitch, 0, state.Roll)
	
	return baseCF * rotationCF
end

-- Check if current orientation is safe for landing
function FreeFlip.IsUprightEnough(state: FlipState, groundNormal: Vector3?): boolean
	local FLIP = CONFIG.FreeFlip
	local upVector = FreeFlip.GetUpVectorFromAngles(state.Pitch, state.Roll)
	local effectiveNormal = groundNormal or vector.create(0, 1, 0)
	local dot = vector.dot(upVector, effectiveNormal)
	return dot >= FLIP.UprightThreshold
end

return FreeFlip

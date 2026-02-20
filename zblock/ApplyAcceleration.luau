-- ApplyAcceleration.luau
-- mewow!

local RS = game:GetService("ReplicatedStorage")
local vector = vector

local CONFIG = require(RS.Shared.MovementConfig)

local AIR_MAX_SPEED = CONFIG.AirMaxSpeed
local AIR_ACCEL = CONFIG.AirAccel
local GROUND_MAX_SPEED = CONFIG.GroundMaxSpeed
local GROUND_ACCEL = CONFIG.GroundAccel

local MAX_SLOPE_ANGLE = CONFIG.MaxSlopeAngle or 50
local MAX_SLOPE_THRESHOLD = 1 - math.cos(math.rad(MAX_SLOPE_ANGLE))
local ABSOLUTE_MAX_SLOPE = 1 - math.cos(math.rad(CONFIG.AbsoluteMaxSlopeAngle or 70))

local AIR_ACCEL_SOFT_CAP = CONFIG.AirAccelSoftCap or 50
local AIR_ACCEL_MIN_SCALE = CONFIG.AirAccelMinScale or 0.25
local AIR_ACCEL_FALLOFF = CONFIG.AirAccelFalloff or 1.2

local FORWARD_AIR_CONTROL = CONFIG.ForwardAirControl or 0.4
local TURN_SPEED_FALLOFF = CONFIG.TurnSpeedFalloff or false
local TURN_FALLOFF_START = CONFIG.TurnFalloffStart or 45
local TURN_MIN_SCALE = CONFIG.TurnMinScale or 0.35

export type GroundedInfo = {
	Instance: Instance?,
	Normal: vector?,
}

local function ProjectOntoPlane(Vec: vector, Normal: vector): vector
	return Vec - Normal * vector.dot(Vec, Normal)
end

local function GetAirAccelScale(Speed: number): number
	if Speed <= AIR_ACCEL_SOFT_CAP then
		return 1
	end
	local Ratio = AIR_ACCEL_SOFT_CAP / Speed
	return math.max(AIR_ACCEL_MIN_SCALE, Ratio ^ AIR_ACCEL_FALLOFF)
end

local function GetTurnScale(Speed: number): number
	if not TURN_SPEED_FALLOFF or Speed <= TURN_FALLOFF_START then
		return 1
	end
	local Ratio = TURN_FALLOFF_START / Speed
	return math.max(TURN_MIN_SCALE, Ratio)
end

return function(
	GroundedInfo: GroundedInfo?,
	Velocity: Vector3,
	InputVect: Vector3,
	LookDir: Vector3,
	dt: number
): vector
	if InputVect.Magnitude <= 0.01 then
		return Velocity
	end
	
	local OnGround = GroundedInfo and GroundedInfo.Instance ~= nil
	local GroundNormal = GroundedInfo and GroundedInfo.Normal or vector.create(0,1,0)
	
	local SlopeDot = vector.dot(GroundNormal, vector.create(0,1,0))
	local SlopeAmount = 1 - SlopeDot
	local TooSteep = SlopeAmount > MAX_SLOPE_THRESHOLD
	
	-- Taper acceleration on steep slopes
	local SlopeAccelScale = 1
	if OnGround and SlopeAmount > MAX_SLOPE_THRESHOLD then
		if SlopeAmount >= ABSOLUTE_MAX_SLOPE then
			SlopeAccelScale = 0
		else
			local t = (SlopeAmount - MAX_SLOPE_THRESHOLD) / (ABSOLUTE_MAX_SLOPE - MAX_SLOPE_THRESHOLD)
			SlopeAccelScale = 1 - t
		end
		
		if SlopeAccelScale <= 0 then
			return Velocity
		end
	end
	
	local WishDir = vector.normalize(InputVect)
	local MaxSpeed, Accelerate
	
	if OnGround then
		local SlopeScale = 1 / math.max(SlopeDot, 0.5)
		MaxSpeed = GROUND_MAX_SPEED * SlopeScale
		Accelerate = GROUND_ACCEL * SlopeScale * SlopeAccelScale  -- applied here
	else
		MaxSpeed = AIR_MAX_SPEED
		Accelerate = AIR_ACCEL
	end
	
	-- W-key handling ONLY when actually airborne
	if not OnGround then
		local FlatLook = vector.create(LookDir.X, 0, LookDir.Z)
		if vector.magnitude(FlatLook) > 0.001 then
			FlatLook = vector.normalize(FlatLook)
			
			local ForwardAmount = vector.dot(WishDir, FlatLook)
			local StrafeVec = WishDir - FlatLook * ForwardAmount
			
			local AdjustedForward = FlatLook * (ForwardAmount * FORWARD_AIR_CONTROL)
			local NewWishDir = AdjustedForward + StrafeVec
			
			if vector.magnitude(NewWishDir) > 0.001 then
				WishDir = vector.normalize(NewWishDir)
			end
		end
		
		local HorizontalVel = vector.create(Velocity.X, 0, Velocity.Z)
		local HorizontalSpeed = vector.magnitude(HorizontalVel)
		
		Accelerate = Accelerate * GetAirAccelScale(HorizontalSpeed)
		
		local TurnScale = GetTurnScale(HorizontalSpeed)
		if TurnScale < 1 and HorizontalSpeed > 0.1 then
			local VelDir = vector.normalize(HorizontalVel)
			local WishDirFlat = vector.create(WishDir.X, 0, WishDir.Z)
			if vector.magnitude(WishDirFlat) > 0.001 then
				WishDirFlat = vector.normalize(WishDirFlat)
				WishDir = vector.normalize(
					WishDirFlat * TurnScale + VelDir * (1 - TurnScale)
				)
			end
		end
	end
	
	local WishSpeed = MaxSpeed
	local CurrentSpeed
	
	if OnGround then
		local ProjectedWishDir = ProjectOntoPlane(WishDir, GroundNormal)
		if vector.magnitude(ProjectedWishDir) > 0.001 then
			WishDir = vector.normalize(ProjectedWishDir)
		end
		
		local ProjectedVelocity = ProjectOntoPlane(Velocity, GroundNormal)
		local TotalSpeed = vector.magnitude(ProjectedVelocity)
		
		-- On ground, cap based on total speed, not directional
		if TotalSpeed >= MaxSpeed then
			return Velocity
		end
		
		CurrentSpeed = vector.dot(ProjectedVelocity, WishDir)
	else
		CurrentSpeed = vector.dot(Velocity, WishDir)
	end
	
	local AddSpeed = WishSpeed - CurrentSpeed
	
	if AddSpeed <= 0 then
		return Velocity
	end
	
	local AccelSpeed = math.min(Accelerate * dt * WishSpeed, AddSpeed)
	
	return Velocity + (WishDir * AccelSpeed)
end
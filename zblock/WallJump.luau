-- WallJump.luau
-- mewow!

local RS = game:GetService("ReplicatedStorage")
local CONFIG = require(RS.Shared.MovementConfig)

local WALL_EPSILON = CONFIG.WallEpsilon or 2
local BHOP_TOLERANCE = CONFIG.BhopTolerance
local WALL_JUMP_FORCE = CONFIG.WallJumpForce or 10
local WALL_BHOP_BOOST = CONFIG.WallBhopBoost or 1.5

export type WallJumpState = {
	LastWallTouched: BasePart?,
	LastWallTouchTime: number,
	WallExhausted: boolean,
}

local function CreateState(): WallJumpState
	return {
		LastWallTouched = nil,
		LastWallTouchTime = -math.huge,
		WallExhausted = false,
	}
end

local function DetectWall(Collider: BasePart): (BasePart?, vector?)
	local Origin = Collider.Position
	
	local OverlapParam = OverlapParams.new()
	OverlapParam.FilterType = Enum.RaycastFilterType.Exclude
	OverlapParam.FilterDescendantsInstances = {Collider.Parent}
	
	local RayParam = RaycastParams.new()
	RayParam.FilterType = Enum.RaycastFilterType.Exclude
	RayParam.FilterDescendantsInstances = {Collider.Parent}
	
	local Hits = workspace:GetPartBoundsInRadius(Origin, WALL_EPSILON, OverlapParam)
	
	local ClosestWall: BasePart? = nil
	local ClosestNormal: vector? = nil
	local ClosestDist = math.huge
	
	for _, Hit in Hits do
		local ClosestPoint = Hit:GetClosestPointOnSurface(Origin)
		local Offset = ClosestPoint - Origin
		local Dist = Offset.Magnitude
		
		if Dist < 0.01 then
			continue
		end
		
		local Result = workspace:Raycast(Origin, Offset.Unit * (Dist + 0.1), RayParam)
		
		if Result and Result.Instance == Hit and math.abs(Result.Normal.Y) < 0.5 then
			if Dist < ClosestDist then
				ClosestDist = Dist
				ClosestWall = Hit
				ClosestNormal = Result.Normal
			end
		end
	end
	
	return ClosestWall, ClosestNormal
end

local function Update(
	State: WallJumpState,
	Collider: BasePart,
	WallHitbox: BasePart,
	Velocity: Vector3,
	CameraLookVector: Vector3,
	JumpPressedThisFrame: boolean,
	OnGround: boolean,
	Now: number
): (Vector3, boolean)
	
	if OnGround then
		State.LastWallTouched = nil
		State.LastWallTouchTime = -math.huge
		State.WallExhausted = false
		return Velocity, false
	end
	
	local Wall, WallNormal = DetectWall(Collider, WallHitbox)
	
	if not Wall then
		return Velocity, false
	end
	
	if Wall ~= State.LastWallTouched then
		State.LastWallTouched = Wall
		State.LastWallTouchTime = Now
		State.WallExhausted = false
	end
	
	if State.WallExhausted then
		return Velocity, false
	end
	
	if not JumpPressedThisFrame then
		return Velocity, false
	end
	
	-- Jump was pressed this frame while near a wall
	local TimeSinceTouched = Now - State.LastWallTouchTime
	local GotBoost = TimeSinceTouched <= BHOP_TOLERANCE
	
	-- Build new velocity in camera direction
	local FlatLook = Vector3.new(CameraLookVector.X, 0, CameraLookVector.Z)
	if FlatLook.Magnitude > 0.01 then
		FlatLook = FlatLook.Unit
	else
		FlatLook = Vector3.new(0, 0, -1)
	end
	
	local CurrentHorizontalSpeed = Vector3.new(Velocity.X, 0, Velocity.Z).Magnitude
	local NewHorizontalSpeed = CurrentHorizontalSpeed
	
	if GotBoost then
		NewHorizontalSpeed = NewHorizontalSpeed * WALL_BHOP_BOOST
	end
	
	local NewVelocity = FlatLook * NewHorizontalSpeed + Vector3.new(0, WALL_JUMP_FORCE, 0)
	
	-- Add small kick away from wall for feel
	local WallKick = WallNormal * (CONFIG.WallKickStrength or 30)
	NewVelocity = NewVelocity + WallKick
	
	State.WallExhausted = true
	
	return NewVelocity, true
end

return {
	CreateState = CreateState,
	Update = Update,
}
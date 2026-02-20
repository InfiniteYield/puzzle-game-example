-- Love.luau
-- mewow!
-- The core of the player movement system, aka bhopping, wall jumping and air strafing

-- services
local RUNS = game:GetService("RunService")
local RS = game:GetService("ReplicatedStorage")
local UIS = game:GetService("UserInputService")

-- mods
local ClientMods = RS:WaitForChild("Client")

local Input = require(ClientMods.Input)

local ClientSettings = require(ClientMods.ClientSettings)
local ClientNetworking = require(ClientMods.ClientNetworking)
local ClientSounds = require(ClientMods.ClientSounds)

-- consts
local PHYS_PROPS = PhysicalProperties.new(
	1, -- density
	0,-- friction
	0, -- elasticity
	1, -- fric weight
	1 -- elas weight
)

local CONFIG = require(RS.Shared.MovementConfig)

-- vars
local Client = game.Players.LocalPlayer
local Char : Model = script.Parent
local Camera = workspace.CurrentCamera

local Collider : BasePart = Char:WaitForChild("Collider")

local RootAttachment : Attachment = Collider:FindFirstChild("RootRigAttachment")

local HoldingJump = false
local HoldingFlip = false

local AUTOHOP_ENABLED = false
local AUTOBOUND_ENABLED = false

local antigrav = Instance.new("VectorForce")
local LinearVelo = Instance.new("LinearVelocity")

local LastJumpTime = -math.huge
local JUMP_GRACE_PERIOD = 0.05 -- ~3 frames at 60hz, tune as needed

-- helpers
local function GetMovementVect(Input: Vector2): Vector3
	local cf = Collider.CFrame
	
	-- Flatten the vectors by removing the Y component and re-normalizing
	local forward = Vector3.new(cf.LookVector.X, 0, cf.LookVector.Z).Unit
	local right = Vector3.new(cf.RightVector.X, 0, cf.RightVector.Z).Unit
	
	-- Now your WishDir is guaranteed to be on the same plane as your HorizontalVelocity
	local Direction = (forward * Input.Y) + (right * Input.X)
	
	if Direction.Magnitude > 0 then
		Direction = Direction.Unit
	end
	
	return Direction
end

local IsJumping = Input.IsJumping
local GetGround = require(ClientMods.GetGround)

local ApplyFriction = require(script.ApplyFriction)
local ApplyAcceleration = require(script.ApplyAcceleration)

-- walljump
local WallJump = require(script.WallJump)
local WallHitbox: BasePart = Char:WaitForChild("WallHitbox")
local WallJumpState = WallJump.CreateState()

-- free flip
local FreeFlip = require(script.FreeFlip)
local FlipState = FreeFlip.CreateState()

-- input helper for flip
local IsFastFlipping = Input.IsFastFlipping

-- dead
local IsDead : boolean= false

-- impulse force
local ImpulseForce : Vector3?

--setup

local function Setup()
	-- set up our friction
	for _, part : BasePart in Char:QueryDescendants("BasePart") do
		part.CustomPhysicalProperties = PHYS_PROPS
	end
	
	-- get our antigrav ready
	antigrav.Attachment0 = RootAttachment
	antigrav.Force = Vector3.new(0, 0, 0)
	antigrav.Name = "AntigravForce"
	
	antigrav.RelativeTo = Enum.ActuatorRelativeTo.World
	antigrav.ApplyAtCenterOfMass = true
	antigrav.Parent = Collider
	
	LinearVelo.Attachment0 = RootAttachment
	LinearVelo.Name = "LinearVelocity"
	LinearVelo.RelativeTo = Enum.ActuatorRelativeTo.World
	LinearVelo.VelocityConstraintMode = Enum.VelocityConstraintMode.Vector
	LinearVelo.VectorVelocity = Vector3.zero
	LinearVelo.MaxForce = math.huge
	LinearVelo.Parent = Collider
	
	-- debugging
	LinearVelo.Enabled = false
	antigrav.Enabled = true
	
end

Setup()

local clock = os.clock

-- main
local function main(dt: number)
	
	local now = clock()
	
	-- essentials
	local CurrentCFrame = Collider.CFrame
	local Velocity = Collider.AssemblyLinearVelocity
	
	if IsDead then
		antigrav.Enabled = false
		LinearVelo.Enabled = false
		return
	end
	
	-- localized constants (in case they're updated during runtime)
	local FRICTION_VALS = CONFIG.FrictionValues
	local GRAVITY = CONFIG.Gravity
	
	local STANDSTILL_THRESHOLD = CONFIG.StandstillThreshold
	
	local BHOP_TOLERANCE = CONFIG.BhopTolerance
	local BHOP_MISSED_FRICTION = CONFIG.BhopMissedFrictionMult
	
	local MAX_SLOPE_ANGLE = CONFIG.MaxSlopeAngle
	local MAX_SLOPE_THRESHOLD = 1 - math.cos(math.rad(MAX_SLOPE_ANGLE))
	
	-- align upright while facing the direction of the camera's lookvector
	local CameraLookVect = Camera.CFrame.LookVector
	
	-- project it to just x/z so we dont get tilt
	CameraLookVect = vector.create(CameraLookVect.X, 0, CameraLookVect.Z)
	
	-- Normalize the flattened look vector
	local CameraLookMag = vector.magnitude(CameraLookVect)
	if CameraLookMag > 0.001 then
		CameraLookVect = CameraLookVect / CameraLookMag
	else
		CameraLookVect = vector.create(0, 0, -1)
	end
	
	-- updated lookvector
	local CurrentLookVector = Collider.CFrame.LookVector
	
	local OnGround, LastHitGround, HitPart, GroundNormal, HitPoint, HitMaterial = GetGround(Collider)
	
	-- Ignore ground briefly after jumping so we don't "re-ground" immediately
	if (now - LastJumpTime) < JUMP_GRACE_PERIOD then
		OnGround = false
	end
	
	-- get current input vector
	local MoveInput = Input.GetMovementVector()
	
	-- Block input while stumbling
	local IsStumbling = Char:GetAttribute("Stumbling") == true
	if IsStumbling then
		MoveInput = Vector2.zero
	end
	
	local MoveVect = GetMovementVect(MoveInput)
	
	-- check if we're jumping (blocked while stumbling)
	local IsJumpHeld, LastTimePressed = IsJumping()
	if IsStumbling then
		IsJumpHeld = false
	end
	local JumpPressedThisFrame = IsJumpHeld and not HoldingJump
	local ActuallyJumpedThisFrame = false
	
	-- check shift for flip mode
	local IsFlipHeld, LastFlipPressTime = IsFastFlipping()
	if IsStumbling then
		IsFlipHeld = false
	end
	local FlipPressedThisFrame = IsFlipHeld and not HoldingFlip
	
	-- track bhop
	local Bhopped = false
	
	-- friction and gravity
	if OnGround then
		-- Grounded
		local GroundVel = Velocity - GroundNormal * Velocity:Dot(GroundNormal)
		
		if IsJumpHeld then
			local TimeSinceLanded = now - LastHitGround
			local TimeSincePressed = now - LastTimePressed
			
			if AUTOHOP_ENABLED or (TimeSincePressed <= BHOP_TOLERANCE and TimeSinceLanded <= BHOP_TOLERANCE) then
				Velocity = Vector3.new(GroundVel.X, CONFIG.JumpForce, GroundVel.Z)
				LastJumpTime = now
				ActuallyJumpedThisFrame = true
				Bhopped = true
				
			elseif JumpPressedThisFrame then 
				Velocity = Vector3.new(GroundVel.X, CONFIG.JumpForce, GroundVel.Z)
				LastJumpTime = now
				ActuallyJumpedThisFrame = true
			end
		end
		
		if not ActuallyJumpedThisFrame then
			-- Use reduced friction when stumbling for comedic sliding
			local frictionValue = FRICTION_VALS.Default
			if IsStumbling then
				frictionValue = CONFIG.FreeFlip.StumbleFriction
			end
			GroundVel = ApplyFriction(GroundVel, MoveVect, frictionValue, dt)
			Velocity = GroundVel - GroundNormal * 0.5
		end
	end
	
	local WallJumped = false
	if not ActuallyJumpedThisFrame then
		local NewVelocity, DidWallJump = WallJump.Update(
			WallJumpState,
			Collider,
			WallHitbox,
			Velocity,
			CameraLookVect,
			JumpPressedThisFrame or (AUTOBOUND_ENABLED and IsJumpHeld),
			OnGround,
			now
		)
		
		if DidWallJump then
			Velocity = NewVelocity
			LastJumpTime = now -- Use grace period so we don't re-ground instantly
			WallJumped = true
		elseif NewVelocity ~= Velocity then
			-- Slipped
			Velocity = NewVelocity
		end
	end
	
	-- Update free flip state
	-- Note: We pass the raw movement input (Vector2) for flip control
	local BlockAcceleration = false
	
	if not WallJumped then
		FlipState, Velocity, BlockAcceleration = FreeFlip.Update(
			FlipState,
			Char,
			MoveInput,
			FlipPressedThisFrame,
			IsFlipHeld,
			OnGround,
			GroundNormal,
			Velocity,
			now,
			dt
		)
	end
	
	-- gravity if we're airborne or on something very steep
	local ApplyingGrav = false
	
	local function dograv()
		local InFlipMode = FlipState.Active
		
		local EffectiveGravity = InFlipMode and (GRAVITY / CONFIG.FreeFlip.FlipGravityDivisor) or GRAVITY
		Velocity = Velocity + Vector3.new(0, -EffectiveGravity * dt, 0)
	end
	
	if not OnGround then
		dograv()
		ApplyingGrav = true
	else
		local CurrentFloorAngle = 1-GroundNormal:Dot(Vector3.yAxis)
		
		if CurrentFloorAngle > (MAX_SLOPE_THRESHOLD) then
			dograv()
			ApplyingGrav = true
		end
	end
	
	-- apply acceleration (blocked during flip or recovery)
	if not ActuallyJumpedThisFrame and not WallJumped and not BlockAcceleration then
		Velocity = ApplyAcceleration(
			OnGround and {Instance = HitPart, Normal = GroundNormal} or nil,
			Velocity, 
			MoveVect,
			CurrentLookVector,
			dt
		)
	end
	
	-- standstill check (only for horizontal, preserve Y)
	local HorizontalSpeed = Velocity.Magnitude
	
	if MoveVect.Magnitude < 0.01 and Velocity.Magnitude < 1 and not ApplyingGrav then
		--print("cancelling")
		Velocity = Vector3.new(0, 0, 0)
	end
	
	-- Build the collider CFrame with flip rotation applied
	local FinalCFrame
	if FlipState.Active or (math.abs(FlipState.Pitch) > 0.01 or math.abs(FlipState.Roll) > 0.01) then
		-- Use flip CFrame when flipping or still tilted
		FinalCFrame = FreeFlip.BuildCFrame(FlipState, Collider.Position, CameraLookVect)
	else
		-- Normal upright CFrame facing camera
		FinalCFrame = CFrame.lookAt(
			Collider.Position, 
			Collider.Position + CameraLookVect,
			Vector3.yAxis
		)
	end
	
	Collider.CFrame = FinalCFrame
	
	Collider:SetAttribute("IntendedCFrame", Collider.CFrame)
	Collider:SetAttribute("IntendedVelocity", Velocity)
	
	-- override rq
	if ImpulseForce then
		Velocity = Velocity + (ImpulseForce * Collider.AssemblyMass)
		ImpulseForce = nil
	end
	
	-- apply velocity
	
	Collider.AssemblyLinearVelocity = Velocity
	
	antigrav.Force = Vector3.new(0, Collider.AssemblyMass * workspace.Gravity, 0)
	
	HoldingJump = IsJumpHeld
	HoldingFlip = IsFlipHeld
	
	if WallJumped == true or Bhopped == true then
		ClientSounds.Play("Bhop", Collider.Position, {
			LocalVolumeMultiplier = 0.3,
			RollOffMinDistance = 0,
			RollOffMaxDistance = 500
		})
	end
	
	-- update external attribs for the style system and replicator engine
	Char:SetAttribute("Grounded", OnGround)
	if Bhopped then
		Char:SetAttribute("Bhopped", true)
	end
	if WallJumped then
		Char:SetAttribute("WallJumped", true)
	end
	
	Char:SetAttribute("FlipAngle", FlipState and FlipState.Active and FlipState.Roll or 0)
	
end

local function OnDead()
	IsDead = Char:GetAttribute("Dead")
	if IsDead then
		print("dead")
		
		Collider.AssemblyLinearVelocity += Vector3.new(0,10,0)
		Collider.CustomPhysicalProperties = PhysicalProperties.new(1, 0.4, 1, 1, 1)
	else
		Setup()
	end
end

-- plumb

RUNS.Heartbeat:Connect(main)
Char:GetAttributeChangedSignal("Dead"):Connect(OnDead)
ClientNetworking.Connect("Fling", "Main", function(force : Vector)
	local char = game.Players.LocalPlayer.Character
	if not char then return end
	local coll = char:FindFirstChild("HumanoidRootPart")
	if not coll then return end
	ImpulseForce = force
end)

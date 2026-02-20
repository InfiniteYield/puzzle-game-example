-- ApplyFriction.luau

local RS = game:GetService("ReplicatedStorage")

local Config = require(RS.Shared.MovementConfig)

return function(Velocity : Vector3, MoveVect : Vector3, FrictionValue : number, dt : number)
	local Speed = Velocity.Magnitude
	if Speed < 0.01 then return Vector3.zero end -- basically stopped
	
	if MoveVect.Magnitude < 0.01 then
		FrictionValue *= Config.StoppingMultiplier
	end
	
	local drop = Speed * FrictionValue * dt
	
	local newSpeed = math.max(Speed - drop, 0)
	
	-- Scale the velocity vector to the new speed
	return Velocity * (newSpeed / Speed)
end
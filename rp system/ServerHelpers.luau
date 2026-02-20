-- provides some util functions for both OutfitAccessories and OutfitHandler
-- just here to not crowd the code

-- services
	local RepStorage = game:GetService("ReplicatedStorage")
	local RunS = game:GetService("RunService")
	local InsertS = game:GetService("InsertService")

-- modules
	local MRS = RepStorage:WaitForChild("MultiverseReplicatedStorage")

	local Shared = MRS:WaitForChild("Shared")

	local ItemUtils = require(Shared:WaitForChild("ItemUtils"))
	local Types = require(Shared:WaitForChild("Types"))

-- vars
	local LAYERED_LOWER = 64
	local LAYERED_UPPER = 72

	local Cache = RepStorage:FindFirstChild("AccessoriesCache") or (function()
		if RunS:IsServer() then
			local c = Instance.new("Folder")
			c.Name = "AccessoriesCache"
			c.Parent = RepStorage
			return c
		else
			return RepStorage:WaitForChild("AccessoriesCache")
		end
	end)() :: Folder

-- main module
local ServerHelpers = {}

-- publics
function ServerHelpers.modelBelongsToOtherPlayer(caller: Player, target: Model): boolean
	for _, plr in game.Players:GetPlayers() do
		if plr ~= caller and plr.Character and (target == plr.Character or target:IsDescendantOf(plr.Character)) then
			return true
		end
	end
	return false
end

function ServerHelpers.resolveHumanoidForTarget(caller: Player, target: Model?): Humanoid?
	if target == nil then
		return caller.Character and caller.Character:FindFirstChildOfClass("Humanoid") or nil
	end
	local char = game.Players:GetPlayerFromCharacter(target)
	if char and caller.Character ~= target then
		return nil -- target is someone else's character
	end
	return target:FindFirstChildOfClass("Humanoid")
end

function ServerHelpers.readBodyPartTransparency(char : Model) : {[string] : number}
	local out: {[string] : number} = {}
	for _, part in char:GetChildren() do
		
		if not part:IsA("BasePart") then
			continue
		end
		
		local valid = false
		
		for i, v in Enum.BodyPart:GetEnumItems() do
			if part.Name == v.Name then
				valid = true
				break
			end
		end
		
		if valid then
			out[part.Name] = part.Transparency
		end
	end
	return out
end

function ServerHelpers.readBodyParts(hd: HumanoidDescription): {[string]: number}
	local keys = {
		Enum.AvatarAssetType.Head.Name,
		Enum.AvatarAssetType.Face.Name,
		Enum.AvatarAssetType.LeftArm.Name,
		Enum.AvatarAssetType.RightArm.Name,
		Enum.AvatarAssetType.LeftLeg.Name,
		Enum.AvatarAssetType.RightLeg.Name,
		Enum.AvatarAssetType.Torso.Name,
	}
	local out: {[string]: number} = {}
	for _, k in keys do
		local v = (hd :: any)[k]
		if v and v ~= 0 then out[k] = v end
	end
	return out
end

function ServerHelpers.getOrCreateBodyColors(character: Model): BodyColors
	local bc = character:FindFirstChildOfClass("BodyColors") :: BodyColors?
	if not bc then
		bc = Instance.new("BodyColors")
		bc.Name = "Body Colors"
		bc.Parent = character
	end
	return bc
end

function ServerHelpers.readBodyColors(character: Model): {[string]: Color3}
	local bc = ServerHelpers.getOrCreateBodyColors(character)
	return {
		Head=bc.HeadColor3, Torso=bc.TorsoColor3,
		LeftArm=bc.LeftArmColor3, RightArm=bc.RightArmColor3,
		LeftLeg=bc.LeftLegColor3, RightLeg=bc.RightLegColor3,
	}
end

function ServerHelpers.readAnimations(hd: HumanoidDescription): {[string]: number}
	return {
		ClimbAnimation = hd.ClimbAnimation,
		FallAnimation  = hd.FallAnimation,
		IdleAnimation  = hd.IdleAnimation,
		JumpAnimation  = hd.JumpAnimation,
		MoodAnimation  = hd.MoodAnimation,
		RunAnimation   = hd.RunAnimation,
		SwimAnimation  = hd.SwimAnimation,
		WalkAnimation  = hd.WalkAnimation,
	}
end

function ServerHelpers.readScale(hd: HumanoidDescription): {[string]: number}
	return {
		BodyTypeScale = hd.BodyTypeScale,
		DepthScale = hd.DepthScale,
		HeadScale = hd.HeadScale,
		HeightScale = hd.HeightScale,
		ProportionScale = hd.ProportionScale,
		WidthScale = hd.WidthScale,
	}
end

function ServerHelpers.getOrCreateCached(assetId: number): Accessory
	for _, acc in Cache:GetChildren() do
		if acc:IsA("Accessory") and acc:GetAttribute("AssetId") == assetId then
			return acc
		end
	end
	if not RunS:IsServer() then
		error("Accessory cache miss on client; ask server to cache first.")
	end
	local model = InsertS:LoadAsset(assetId) :: Instance
	local accessory = model:FindFirstChildOfClass("Accessory")
	if not accessory then
		model:Destroy()
		error(("Asset %d does not contain an Accessory"):format(assetId))
	end
	accessory.Parent = Cache
	accessory:SetAttribute("AssetId", assetId)
	model:Destroy()
	return accessory
end

function ServerHelpers.EnsureImpostor(obj : Accessory)
	local handle = obj:WaitForChild("Handle")
	
	if handle:IsA("MeshPart") then
		return
	end
	
	return handle:WaitForChild("Impostor")
end

function ServerHelpers.GetHighestLayer(Character : Model)
	local HighestLayer = 0
	for _, v in Character:GetChildren() do
		if v:IsA("Accessory") then
			local handle = v:FindFirstChild("Handle")
			if not handle then continue end
			if handle:IsA("MeshPart") then
				local wrap = handle:FindFirstChildOfClass("WrapLayer")
				if not wrap then continue end
				HighestLayer = math.max(wrap.Order, HighestLayer)
			end
		end
	end
	
	return HighestLayer
end

-- Returns true if assetId is a layered clothing asset and optionally the order of the Accessory if provided
function ServerHelpers.isLayeredAsset(assetId: number, Accessory : Accessory?): (boolean, number?)
	local info = ItemUtils.GetItemDetails(assetId)
	if not info then return false end
	local v = info.AssetType.Value
	
	local IsLayered = v >= LAYERED_LOWER and v <= LAYERED_UPPER
	local Order
	
	if IsLayered and Accessory then
		local Handle = Accessory.Handle :: MeshPart
		Order = Handle:FindFirstChildOfClass("WrapLayer").Order
	end
	
	return IsLayered, Order
end

function ServerHelpers.reconcileImpostor(accessory: Accessory, data : Types.OutfitAccessoryData, player : Player?): BasePart
		local handle = accessory:FindFirstChild("Handle") :: BasePart
		local existing = handle:FindFirstChild("Impostor")
		
		local particle
		
		local function verifyParticle(parent : Instance)
			if data.Particle.Texture ~= nil and data.Particle.Texture ~= "" then
				particle = parent:FindFirstChildOfClass("ParticleEmitter") or Instance.new("ParticleEmitter", parent)
				
				for i, v in data.Particle do
					particle[i] = v
				end
			
			else
				local found = parent:FindFirstChildOfClass("ParticleEmitter")
				if found then
					found:Destroy()
				end
			end
		end
		
		if existing and existing:IsA("BasePart") then
			
			verifyParticle(existing)

			--reapply all data to accessory impostor to keep it updated
			local sm = existing:FindFirstChildOfClass("SpecialMesh")
			if sm then
				
				sm.MeshId = data.MeshId
				sm.TextureId = data.TextureId
				
				local handlesm = handle:FindFirstChildOfClass("SpecialMesh")
				sm.Scale = handlesm.Scale * data.Scale
				
				sm.VertexColor = Vector3.new(data.Color.R, data.Color.G, data.Color.B)
				
			
				
			end
			
			existing.Name = "Impostor"
			existing.Color = data.Color
			
			existing.Material = data.Electric and Enum.Material.ForceField or data.Material
			
			existing.Transparency = data.Transparency
			existing.Size = handle.Size
			
			local Weld = existing:FindFirstChild("Weld")
			if Weld then
				Weld.C0 = data.Offset or CFrame.new()
			end
			
			return existing, particle
		end
		
		if handle:IsA("MeshPart") then
			
			verifyParticle(handle)
			
			local SurfaceAppearance = handle:FindFirstChildOfClass("SurfaceAppearance")
			if SurfaceAppearance then
				SurfaceAppearance.Color = data.Color
			end
			
			local WrapLayer = handle:FindFirstChildOfClass("WrapLayer")
			if WrapLayer then
				if not data.LayerOrder then
					data.LayerOrder = ServerHelpers.GetHighestLayer(accessory.Parent) + 1
				end
				WrapLayer.Order = data.LayerOrder
			end
			
			handle.Material = data.Electric and Enum.Material.ForceField or data.Material
			
			-- particle
			
			return nil,  particle
		end
		
		handle.Transparency = 1
		
		local impostor = Instance.new("Part")
		impostor.Name = "Impostor"
		impostor.Size = handle.Size
		impostor.CFrame = handle.CFrame
		impostor.Material = data.Electric and Enum.Material.ForceField or data.Material
		impostor.Transparency = data.Transparency
		impostor.Color = data.Color
		
		-- so we avoid bullsh
		impostor.CanCollide = false
		impostor.CanQuery = false
		impostor.CanTouch = false
		impostor.Massless = true
		
		verifyParticle(impostor)
		
		local handlesm = handle:FindFirstChildOfClass("SpecialMesh")
		
		local sm = Instance.new("SpecialMesh")
		sm.Name = "SpecialMesh"
		sm.MeshType = Enum.MeshType.FileMesh
		sm.MeshId = data.MeshId
		sm.TextureId = data.TextureId
		sm.Scale = handlesm.Scale * data.Scale -- allows it to scale with proper proportions per roblox's criteria 
		sm.VertexColor = Vector3.new(data.Color.R, data.Color.G, data.Color.B)
		
		sm.Parent = impostor
		
		local weld = Instance.new("Weld")
		weld.Name = "Weld"
		weld.Part0 = handle
		weld.Part1 = impostor
		weld.C0 = data.Offset or CFrame.new()
		weld.Parent = impostor
		
		impostor.Parent = handle
		
		if player and impostor:IsDescendantOf(workspace) then
			impostor:SetNetworkOwner(player)
		end
		
		return impostor, particle
	end


return ServerHelpers

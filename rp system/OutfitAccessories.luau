
-- services
local RunS = game:GetService("RunService")
local RepStorage = game:GetService("ReplicatedStorage")
local SSS = game:GetService("ServerScriptService")
local Players = game:GetService("Players")
local Http = game:GetService("HttpService")
local AvaEditServ = game:GetService("AvatarEditorService")

-- consts
local SERVER = RunS:IsServer()

-- modules

local MRS = RepStorage:WaitForChild("MultiverseReplicatedStorage")
local MSSS = SERVER and SSS:WaitForChild("MultiverseServerScriptService") or nil

local Shared = MRS:WaitForChild("Shared")
local Types = require(Shared:WaitForChild("Types"))
local Utils = require(Shared:WaitForChild("Utility"))
local ItemUtils = require(Shared:WaitForChild("ItemUtils"))
local ServerHelpers = require(script.Parent:WaitForChild("ServerHelpers"))

local FilterTextAPI = SERVER and require(MSSS:WaitForChild("FilterTextAPI")) or nil
local Constants = require(Shared:WaitForChild("Constants"))

local SolveDecal = SERVER and require(MSSS:WaitForChild("SolveDecal"))

-- vars
local NetworkHeap : Folder = RepStorage:WaitForChild("NetworkHeap")


local OutfitAccessories = {}
OutfitAccessories.__index = OutfitAccessories

-- types

type OutfitAccessory = Types.OutfitAccessory
type OutfitAccessoryData = Types.OutfitAccessoryData

export type OutfitAccessories = typeof(OutfitAccessories) & Types.OutfitAccessory

-- privates

-- clients use this in each method to ask for the server's mirrored operation
local function ClientCall(outfit, method, ...)
	local success, res = outfit.Invoke:InvokeServer(method, ...)
	if not success then
		warn("Invalid call to OutfitHandler", outfit, method, ..., "error:", res)
	end
	return success, res
end

-- Creates a new RemoteEvent and RemoteFunction for the client to connect to
local function CreateNetworkComms(guid : string) : (RemoteEvent, RemoteFunction)
	local Invoke = Instance.new("RemoteFunction")
	Invoke.Name = guid
	Invoke.Parent = NetworkHeap
	
	local Event = Instance.new("RemoteEvent")
	Event.Name = "ToClient"
	Event.Parent = Invoke
	
	local Updated = Instance.new("BindableEvent")
	Updated.Name = "Updated"
	Updated.Parent = Invoke
	
	return Event, Invoke, Updated
end

-- Returns the Accessory's MeshId, TextureId, Material, Transparency, and Scale
local function GetAccessoryMainVals(Accessory : Accessory)
	local Handle = Accessory:WaitForChild("Handle") :: BasePart
	local Attachment = Handle:FindFirstChildOfClass("Attachment")
	
	-- returns
	local AttachmentType = Accessory:GetAttribute("AttachmentType") or Utils.GetAttachmentTypeFromAttachmentName(Attachment.Name)
	local MeshId : string
	local TextureId : string
	local Material : Enum.Material
	local Transparency : number
	local Scale : Vector3
	local Color : Color3
	local Offset : CFrame = CFrame.new()
	
	if Handle:IsA("MeshPart") then
		MeshId = Handle.MeshId
		TextureId = Handle.TextureID
		Material = Handle.Material
		Transparency = Handle.Transparency
		Scale = Vector3.one
		local sa : SurfaceAppearance= Handle:FindFirstChild("SurfaceAppearance")
		Color = sa and sa.Color or Color3.new(1,1,1)
	else
		local sm : SpecialMesh = Handle:FindFirstChildOfClass("SpecialMesh")
		
		local impostor = Handle:FindFirstChild("Impostor")
		if impostor then
			local impostorsm = impostor:FindFirstChildOfClass("SpecialMesh")
			MeshId = impostorsm.MeshId
			TextureId = impostorsm.TextureId
			Material = impostor.Material
			Transparency = impostor.Transparency
			Color = Color3.new(impostorsm.VertexColor.X, impostorsm.VertexColor.Y,impostorsm.VertexColor.Z)
			
			local w = impostor:FindFirstChildOfClass("Weld")
			if w then
				Offset = w.C0
			end
			
			local function SolveScale(v1 : Vector3, v3 : Vector3) : Vector3
				-- guard against division by zero
				assert(v1.X ~= 0 and v1.Y ~= 0 and v1.Z ~= 0, "v1 has zero component(s), cannot divide")
				return Vector3.new(
					v3.X / v1.X,
					v3.Y / v1.Y,
					v3.Z / v1.Z
				)
			end
			
			Scale = SolveScale(sm.Scale, impostorsm.Scale)
			
		else
			MeshId = sm.MeshId
			TextureId = sm.TextureId
			Material = Handle.Material
			
			Color = Color3.new(sm.VertexColor.X, sm.VertexColor.Y,sm.VertexColor.Z)
			
			Transparency = Handle.Transparency
			Scale = Vector3.one
		end
		
	end
	
	return MeshId, TextureId, Material, Transparency, Scale, Color, AttachmentType, Offset
	
end

-- Shared network invoke that's tied to the server's RemoteFunction when a new instance is made
local function NetworkInvoke(self : OutfitAccessories, sendingPlayer : Player, method : string, ...)
	if sendingPlayer ~= self.Player then
		sendingPlayer:Kick("no")
		return
	end
	
	assert(self[method], `OutfitAccessories: Invalid method {method}`)
	
	local success, ret = pcall(self[method], self, ...)
	return success, ret
end

-- Returns the character bodypart name that an AccessoryType typically attaches to
local function GetAccessoryAttachmentPart(accessoryType: Enum.AccessoryType): string?
	-- Mapping based on Roblox’s standard HumanoidDescription / Accessory attachment rules
	local map: {[Enum.AccessoryType]: string} = {
		[Enum.AccessoryType.Hat] = "Head",
		[Enum.AccessoryType.Hair] = "Head",
		[Enum.AccessoryType.Face] = "Head",
		
		[Enum.AccessoryType.Neck] = "UpperTorso",
		[Enum.AccessoryType.Shoulder] = "UpperTorso",
		[Enum.AccessoryType.TShirt] = "UpperTorso", -- clothing layered on torso
		[Enum.AccessoryType.Shirt] = "UpperTorso",
		[Enum.AccessoryType.Sweater] = "UpperTorso",
		[Enum.AccessoryType.Jacket] = "UpperTorso",
		
		[Enum.AccessoryType.Pants] = "LowerTorso",
		[Enum.AccessoryType.DressSkirt] = "LowerTorso",
		[Enum.AccessoryType.Shorts] = "LowerTorso",
		
		[Enum.AccessoryType.Front] = "UpperTorso",
		[Enum.AccessoryType.Back] = "UpperTorso",
		[Enum.AccessoryType.Waist] = "LowerTorso",
		
		[Enum.AccessoryType.Eyebrow] = "Head",
		[Enum.AccessoryType.Eyelash] = "Head",
	}
	
	return map[accessoryType]
end

local function Sanitize(data : OutfitAccessoryData)
	-- adds missing properties post 10/23/2025 update
	data.Particle = data.Particle or {
		Texture = 0
		
	}
	
	local function SanitizeParticleData(data: {[any]: any}?): ParticleData
		return {
			Color = data.Color or ColorSequence.new(Color3.new(1, 1, 1)),
			LightEmission = data.LightEmission or 0,
			LightInfluence = data.LightInfluence or 1,
			Size = data.Size or NumberSequence.new(1),
			Squash = data.Squash or NumberSequence.new(0),
			Texture = data.Texture or "",
			Transparency = data.Transparency or NumberSequence.new(0),
			
			EmissionDirection = data.EmissionDirection or Enum.NormalId.Top,
			Lifetime = data.Lifetime or NumberRange.new(1),
			Rate = data.Rate or 10,
			Rotation = data.Rotation or NumberRange.new(0),
			RotSpeed = data.RotSpeed or NumberRange.new(0),
			Speed = data.Speed or NumberRange.new(5),
			SpreadAngle = data.SpreadAngle or Vector2.new(0, 0),
			
			Shape = data.Shape or Enum.ParticleEmitterShape.Box,
			ShapeInOut = data.ShapeInOut or Enum.ParticleEmitterShapeInOut.Outward,
			ShapeStyle = data.ShapeStyle or Enum.ParticleEmitterShapeStyle.Volume,
			
			LockedToPart = data.LockedToPart or false,
			TimeScale = data.TimeScale or 1,
			WindAffectsDrag = data.WindAffectsDrag or false
		}
	end
	
	data.Particle = data.Particle or {}
	data.Particle = SanitizeParticleData(data.Particle)
	
	if typeof(data.Particle.Texture) == "number" then
		data.Particle.Texture = ""
	end
end

-- publics

-- constructors

function OutfitAccessories.fromData(Player : Player, data : OutfitAccessoryData) : OutfitAccessories
	if SERVER then
		-- Instance
		local CachedRef = ServerHelpers.getOrCreateCached(data.AssetId)
		
		if not CachedRef then
			return
		end
		
		--Event and invoke
		
		local Event, Invoke, Updated = CreateNetworkComms(data.GUID)
		
		Sanitize(data)
		
		local self : OutfitAccessory = {
			Data = Utils.DeepCopy(data),
			Player = Player,
			Instance = nil,
			CachedRef = CachedRef,
			Impostor = nil,
			Event = Event,
			Updated = Updated,
			Invoke = Invoke,
			
			_BatchDepth = 0,
			_Dirty = false,
			_FramesUntilFlush = 0,
			_InFlush = false,
		}
		
		
		
		setmetatable(self, OutfitAccessories)
		
		Invoke.OnServerInvoke = function(plr : Player, method : string, ...)
			return NetworkInvoke(self, plr, method, ...)
		end
		
		return self
		
	else
		-- client
		local ClientNetwork = require(RepStorage:WaitForChild("ClientNetworking"))
		
		local success, returned = ClientNetwork.Invoke("OutfitAccessoriesInvoke", "fromData", data)
		
		setmetatable(returned, OutfitAccessories)
		
		returned.Event.OnClientEvent:Connect(function(newdata : OutfitAccessoryData)
			returned.Data = newdata
		end)
		
		-- no you do not need to keep track of this connection, :Destroy() will take care of it ^
		
		return returned
	end
	
end

function OutfitAccessories.fromInstance(Player : Player, Accessory : Accessory) : OutfitAccessories
	
	if SERVER then
		
		-- find the assetid first
		local Char = Accessory.Parent
		local Humanoid = Char:FindFirstChildOfClass("Humanoid")
		assert(Humanoid, "No humanoid")
		local Description = Humanoid:FindFirstChildOfClass("HumanoidDescription")
		assert(Description, "No description")
		
		local AssetId : number?
		
		if Accessory:GetAttribute("AssetId") then
			AssetId = Accessory:GetAttribute("AssetId")
		else
			for i, v in Description:GetChildren() do
				if v:IsA("AccessoryDescription") then
					if v:GetAppliedInstance() == Accessory then
						AssetId = v.AssetId
						Accessory:SetAttribute("AssetId", AssetId)
						break
					end
				end
			end
		end
		
		if not AssetId then
			warn("Unable to resolve AssetId for Accessory", Accessory)
			return
		end
		
		local info = ItemUtils.GetItemDetails(AssetId)
		
		local MeshId, TextureId, Material, Transparency, Scale, Color, AttachmentType, Offset = GetAccessoryMainVals(Accessory)
		
		local GUID = Http:GenerateGUID()
		
		local Event , Invoke, Updated = CreateNetworkComms(GUID)
		
		local IsLayered, Order = ServerHelpers.isLayeredAsset(AssetId, Accessory)
		
		local self : OutfitAccessory = setmetatable({
			Data = {
				GUID = GUID,
				
				AssetId = AssetId,
				
				Name = Accessory.Name,
				
				AccessoryType = AvaEditServ:GetAccessoryType(info.AssetType),
				
				MeshId = MeshId,
				OriginalMeshId = MeshId,
				
				TextureId = TextureId,
				OriginalTextureId = TextureId,
				
				IsLayered = IsLayered,
				LayerOrder = Order,
				
				Color = Color,
				
				Transparency = Transparency,
				
				Material = Material,
				
				Electric = (Material == Enum.Material.ForceField),
				
				AccessoryAttachmentType = AttachmentType,
				OriginalAccessoryAttachmentType = AttachmentType,
				
				Offset = Offset,
				
				Scale = Scale,
				
				ItemType = info.ItemType,
				
				Particle = {}
				
			},
			Player = Player,
			Instance = nil,
			Character = nil, -- applied later
			CachedRef = ServerHelpers.getOrCreateCached(AssetId),
			Event = Event,
			Updated = Updated,
			Invoke = Invoke,
		}, OutfitAccessories)
		
		Sanitize(self.Data)
		
		Invoke.OnServerInvoke = function(plr : Player, method : string, ...)
			return NetworkInvoke(self, plr, method, ...)
		end

		return self
		
	else
		-- client
		local ClientNetwork = require(RepStorage:WaitForChild("ClientNetworking"))
		
		local success, returned = ClientNetwork.Invoke("OutfitAccessoriesInvoke", "fromInstance", Accessory)
		
		setmetatable(returned, OutfitAccessories)
		
		returned.Event.OnClientEvent:Connect(function(newdata : OutfitAccessoryData)
			returned.Data = newdata
		end)
		
		
		return returned
	end
	
	
end


-- Constructs a new OutfitAccessory from AssetId, aka factory defaults
function OutfitAccessories.fromAssetId(Player : Player, AssetId : number)
	
	if SERVER then
		local info = ItemUtils.GetItemDetails(AssetId)
		
		local GUID = Http:GenerateGUID()
		
		local Event , Invoke, Updated = CreateNetworkComms(GUID)
		
		local CachedRef = ServerHelpers.getOrCreateCached(AssetId)
		
		local MeshId, TextureId, Material, Transparency, Scale, Color, AttachmentType = GetAccessoryMainVals(CachedRef)
		
		local self : OutfitAccessory = setmetatable(
			{
				Data = {
					GUID = GUID,
					
					AssetId = AssetId,
					
					Name = info.Name,
					
					AccessoryType = AvaEditServ:GetAccessoryType(info.AssetType),
					
					MeshId = MeshId,
					OriginalMeshId = MeshId,
					
					TextureId = TextureId,
					OriginalTextureId = TextureId,
					
					IsLayered = ServerHelpers.isLayeredAsset(AssetId),
					
					Color = Color3.new(1,1,1),
					
					Transparency = Transparency,
					
					Material = Material,
					
					Electric = false,
					
					Offset = CFrame.new(),
					Scale = Scale,
					
					ItemType = info.ItemType,
					
					Particle = {
						Texture = 0
					}
				},
			
				Player = Player,
				
				Character = nil,
				
				Instance = nil,
				
				CachedRef = CachedRef,
				
				Event = Event,
				Updated = Updated,
				Invoke = Invoke,
			}, OutfitAccessories)
		
		Sanitize(self.Data)
		
		Invoke.OnServerInvoke = function(plr : Player, method : string, ...)
			return NetworkInvoke(self, plr, method, ...)
		end
		
		return self
	else
		local ClientNetwork = require(RepStorage:WaitForChild("ClientNetworking"))
		
		local success, returned = ClientNetwork.Invoke("OutfitAccessoriesInvoke", "fromAssetId", Player, AssetId)
		
		setmetatable(returned, OutfitAccessories)
		
		returned.Event.OnClientEvent:Connect(function(newdata : OutfitAccessoryData)
			returned.Data = newdata
		end)
		
		return returned
	end		
				
end

-- Reads a rig's actual accessories, creates OutfitAccessory objects for them, and returns them in a table
function OutfitAccessories.readRigAccessories(Player : Player, character : Model, returnDataOnly : boolean?) : {OutfitAccessoryData | OutfitAccessory}
	
	if SERVER then
		
		local heap : {OutfitAccessoryData | OutfitAccessory} = {}
		
		for i, v in character:GetChildren() do
			if v:IsA("Accessory") then
				local new = OutfitAccessories.fromInstance(Player, v)
				
				if returnDataOnly then
					new = new:Pack()
				end
				table.insert(heap, new)
			end
		end
		
		return heap
		
	else
		
		-- client
		local ClientNetwork = require(RepStorage:WaitForChild("ClientNetworking"))
		
		local success, returned = ClientNetwork.Invoke("OutfitAccessoriesInvoke", "readRigAccessories", character, returnDataOnly)
		
		return returned
	end
	
	
	
end

-- methods

-- batching

-- Reconciles the Accessory's appearance to its data. Also the method used to set the character.
function OutfitAccessories:Reconcile(newCharacter : Model?, dontping : boolean)
	local self = self :: OutfitAccessories
	
	if not SERVER then
		-- client passthrough
		local success, int, char = ClientCall(self, "Reconcile", newCharacter)
		if success then
			self.Instance = int; self.Character = char
			if self.Instance then
				self.Impostor = ServerHelpers.EnsureImpostor(self.Instance)
			end
		end
		return
	end
	
	
	if not self.Instance then
		self.Instance = self.CachedRef:Clone()
	elseif not self.Instance:IsDescendantOf(game) then
		self.Instance = self.CachedRef:Clone()
	end
	
	if newCharacter then
		local hum = ServerHelpers.resolveHumanoidForTarget(self.Player, newCharacter)
		if not hum then error("Invalid character presented.") end
		
		self.Character = newCharacter
		
		if self.Data.IsLayered then
			if not self.Data.LayerOrder then
				self.Data.LayerOrder = ServerHelpers.GetHighestLayer(self.Character) + 1
				local Handle = self.Instance.Handle :: BasePart
				local WrapLayer = Handle:FindFirstChildOfClass("WrapLayer")
				WrapLayer.Order = self.Data.LayerOrder
			end
			local Handle = self.Instance.Handle :: BasePart
			local WrapLayer = Handle:FindFirstChildOfClass("WrapLayer")
			WrapLayer.Order = self.Data.LayerOrder
		end
		
		local handle = self.Instance.Handle :: BasePart
		local Attachment = handle:FindFirstChildOfClass("Attachment")
		
		local acctype
		if not self.Data.AccessoryAttachmentType then
			print("attach name?", Attachment.Name)
			
			acctype = self.Instance:GetAttribute("AttachmentType") or Utils.GetAttachmentTypeFromAttachmentName(Attachment.Name)
			self.Data.AccessoryAttachmentType = acctype
			self.Data.OriginalAccessoryAttachmentType = acctype
		else
			acctype = self.Data.AccessoryAttachmentType
		end
		
		local attname, bp = Utils.GetAttachmentDetailsFromAttachmentType(acctype)
		Attachment.Name = attname
		
		self.Instance:SetAttribute("AttachmentType", acctype)
		
		self.Instance.Parent = workspace
		hum:AddAccessory(self.Instance)
		
		local Weld = handle:FindFirstChildOfClass("Weld") :: Weld
		
		Weld.Part1 = newCharacter:FindFirstChild(bp.Name)
		Attachment.Name = attname
		
		self.Impostor, self.Particle = ServerHelpers.reconcileImpostor(self.Instance, self.Data, self.Player)
		
	else
		local handle = self.Instance.Handle
		local Attachment = handle:FindFirstChildOfClass("Attachment")
		
		if self.Data.AccessoryAttachmentType then
			self.Instance.Parent = workspace
			
			local hum = ServerHelpers.resolveHumanoidForTarget(self.Player, newCharacter or self.Character)
			if not hum then error("Invalid character presented.") end
			
			local newattachname, bp = Utils.GetAttachmentDetailsFromAttachmentType(self.Data.AccessoryAttachmentType)
			Attachment.Name = newattachname
			hum:AddAccessory(self.Instance)
			
			local Weld = handle:FindFirstChildOfClass("Weld")
			Weld.Part1 = self.Character:FindFirstChild(bp.Name)
		end
		
		self.Impostor, self.Particle = ServerHelpers.reconcileImpostor(self.Instance, self.Data, self.Player)
	end
	
	self.Instance.Name = self.Data.Name
	
	-- single broadcast

	if not dontping then
		self.Updated:Fire()
		if self.Player then
			self.Event:FireClient(self.Player, self.Data)
		end
	end
	
	return self.Instance, self.Character
end



-- Sets the name of the accessory
function OutfitAccessories:SetName(Name : string)
	local self = self :: OutfitAccessories
	if SERVER then
		
		local text = FilterTextAPI(self.Player, Name)
		self.Data.Name = text
		
		self:Reconcile()
		return text
	else
		local success, res = ClientCall(self, "SetName", Name)
		
		if success then
			self.Data.Name = res
		end
		
		return
	end
end

-- Sets the Impostor's mesh id to the given MeshId number.
-- Note: MeshId and TextureId's are stored as strings in data.
function OutfitAccessories:SetMesh(MeshId : number)
	local self = self :: OutfitAccessories
	if SERVER then
		
		local s = "rbxassetid://" .. tostring(MeshId)
		self.Data.MeshId = s
		self:Reconcile()
		return s
	else
		local success, res = ClientCall(self, "SetMesh", MeshId)
		if success then
			self.Data.MeshId = res
		end
		
		return
	end
end

-- Set's the accessory's color to the selected color.
function OutfitAccessories:SetColor(color : Color3)
	local self = self :: OutfitAccessories
	if SERVER then
		self.Data.Color = color
		print("set color", color, self.Data.GUID)
		self:Reconcile()
		return color
	else
		local success, res = ClientCall(self, "SetColor", color)
		if success then
			self.Data.Color = res
		end
		
		return
	end
end


-- Previews a color client-side rather than posting to server
function OutfitAccessories:PreviewColor(color : Color3)
	local self = self :: OutfitAccessories
	
	if SERVER then
		return
	else
		if self.Data.IsLayered then
			local Handle : MeshPart = self.Instance:FindFirstChild("Handle")
			
			local SurfaceAppearance = Handle:FindFirstChildOfClass("SurfaceAppearance")
			if SurfaceAppearance then
				SurfaceAppearance.Color = color
			end
		else
			local Impostor = self.Impostor
			if Impostor then
				local mesh = Impostor:FindFirstChildOfClass("SpecialMesh")
				if mesh then
					mesh.VertexColor = Vector3.new(color.R, color.G, color.B)
					Impostor.Color = color
				end
			end
		end
		
	end
end

function OutfitAccessories:SetElectric(val : boolean)
	local self = self :: OutfitAccessories
	if SERVER then
		self.Data.Electric = val
		self:Reconcile()
		return val
	else
		local success, res = ClientCall(self, "SetElectric", val)
		if success then
			self.Data.Electric = res
		end
		
		return
	end
end

function OutfitAccessories:SetTexture(TextureId : number | string)
	local self = self :: OutfitAccessories
	if SERVER then
		local s
		if typeof(TextureId) == "number" then
			s = SolveDecal(self.Player, TextureId)
		else
			s = TextureId
		end
		self.Data.TextureId = s
		self:Reconcile()
		return s
	else
		local success, res = ClientCall(self, "SetTexture", TextureId)
		if success then
			self.Data.TextureId = res
		end
		
		return
	end
end

function OutfitAccessories:SetOffset(cf : CFrame)
	local self = self :: OutfitAccessories
	if SERVER then
		
		-- constrain it so it isn't super far away
		local max = Constants.MaxAccessoryDistanceFromCharacter
		
		cf = cf.Rotation + Vector3.new(
			math.clamp(cf.X, -max, max), 
			math.clamp(cf.Y, -max, max), 
			math.clamp(cf.Z, -max, max)
		)
		
		self.Data.Offset = cf
		self:Reconcile()
		return cf
	else
		local success, res = ClientCall(self, "SetOffset", cf)
		if success then
			self.Data.Offset = res
		end
		
		return
	end
end

-- A client-sided method to save the preview offset to the actual offset.
function OutfitAccessories:SavePreviewOffset()
	local self = self :: OutfitAccessories
	if SERVER then
		return
	else
		local success, res = ClientCall(self, "SetOffset", self.Data.PreviewOffset)
		if success then
			self.Data.Offset = res
			self.Data.PreviewOffset = nil
		end
		return
	end
end

-- A client-sided method to set the preview offset, which is useful of 3D handles manipulation.
function OutfitAccessories:SetPreviewOffset(cf : CFrame)
	local self = self :: OutfitAccessories
	
	if SERVER then
		return
	else
		self.Data.PreviewOffset = cf
		local Impostor = self.Impostor
		if not Impostor then
			return
		end
		
		local Weld = Impostor:FindFirstChildOfClass("Weld")
		if not Weld then 
			return
		end
		
		Weld.C0 = cf
	end
	
end

function OutfitAccessories:SetScale(scale : Vector3)
	local self = self :: OutfitAccessories
	if SERVER then
		
		local max = Constants.MaxAccessoryScale
		scale = Vector3.new(
			math.clamp(scale.X, 0, max),
			math.clamp(scale.Y, 0, max),
			math.clamp(scale.Z, 0, max)
		)
		
		self.Data.Scale = scale
		self:Reconcile()
		return scale
	else
		local success, res = ClientCall(self, "SetScale", scale)
		if success then
			self.Data.Scale = res
		end
		
		return
	end
end

function OutfitAccessories:SetPreviewScale(Scale : Vector3)
	local self = self :: OutfitAccessories
	
	if SERVER then
		return
	else
		local SelfInstance = self.Instance
		if SelfInstance then
			local Handle = SelfInstance.Handle :: BasePart
			local Impostor = self.Impostor
			if Impostor and Handle then
				local handlessm = Handle:FindFirstChildOfClass("SpecialMesh")
				local sm = Impostor:FindFirstChildOfClass("SpecialMesh")
				if sm and handlessm then
					local max = Constants.MaxAccessoryScale
					Scale = Vector3.new(
						math.clamp(Scale.X, 0, max),
						math.clamp(Scale.Y, 0, max),
						math.clamp(Scale.Z, 0, max)
					)
					sm.Scale = handlessm.Scale * Scale
					self.Data.PreviewScale = Scale
				end
			end
		end
		
	end
end

function OutfitAccessories:SavePreviewScale()
	local self = self :: OutfitAccessories
	if SERVER then
		return
	else
		local success, res = ClientCall(self, "SetScale", self.Data.PreviewScale)
		if success then
			self.Data.Scale = res
		end
		return
	end
end

function OutfitAccessories:SetTransparency(alpha : number)
	local self = self :: OutfitAccessories
	if SERVER then
		self.Data.Transparency = math.clamp(alpha, 0, 1)
		self:Reconcile()
		return self.Data.Transparency
	else
		local success, res = ClientCall(self, "SetTransparency", alpha)
		if success then
			self.Data.Transparency = res
		end
		return
	end
end

function OutfitAccessories:PreviewTransparency(alpha : number)
	local self = self :: OutfitAccessories
	alpha = math.clamp(alpha,0,1)
	if SERVER then
		return
	else
		local Impostor = self.Impostor
		if Impostor then
			Impostor.Transparency = alpha
		end
		return
	end
end

-- Sets the attachment type of the given accessory so that it attaches to the specific body part.
function OutfitAccessories:SetAttachmentType(Attachment : Types.AccessoryAttachmentType)
	local self = self :: OutfitAccessories
	if SERVER then
		self.Data.AccessoryAttachmentType = Attachment
		self:Reconcile()
		return self.Data.AccessoryAttachmentType
	else
		local success, res = ClientCall(self, "SetAttachmentType", Attachment)
		if success then
			self.Data.AccessoryAttachmentType = res
		end
		
		return
	end
end

function OutfitAccessories:PreviewParticleData(field : string, data : any)
	local self = self :: OutfitAccessories
	if SERVER then
		return
	else
		assert(self.Data.Particle[field], "invalid field")
		assert(typeof(data) == typeof(self.Data.Particle[field]), "invalid datatype")
		
		self.Data.Particle[field] = data
		
		local Particle = self.Particle
		if Particle then
			Particle[field] = data
		end
	end
end

-- Sets the provided field for Particle data to the given value
function OutfitAccessories:SetParticleData(field : string, data : any)
	local self = self :: OutfitAccessories
	
	if SERVER then
		assert(self.Data.Particle[field], "invalid field")
		
		
		if field == "Texture" then
			if typeof(data) == "number" then
				if data ~= 0 then
					data = SolveDecal(self.Player, data)
				else
					data = ""
				end
			end
		end
		
		assert(typeof(data) == typeof(self.Data.Particle[field]), "invalid datatype")
		
		self.Data.Particle[field] = data
		self:Reconcile()
		return self.Data.Particle
	else
		local success, res = ClientCall(self, "SetParticleData", field, data)
		if success then
			self.Data.Particle = res
		end
		return
	end
end

-- util

function OutfitAccessories:Clone() : OutfitAccessories
	local self = self :: OutfitAccessories
	local copy = Utils.DeepCopy(self)
	copy.Data.GUID = Http:GenerateGUID(false)
	local new = OutfitAccessories.fromData(self.Player, copy:Pack())
	return new
end

-- Returns a copy of the OutfitAccessoryData that's ready to save with Datastores
function OutfitAccessories:Pack() : OutfitAccessoryData
	local self = self :: OutfitAccessories
	
	local copy = Utils.DeepCopy(self)
	
	setmetatable(copy, nil)
	
	return copy.Data
end

-- Destroys the accessory and any relevant data in the table
function OutfitAccessories:Destroy()
	local self = self :: OutfitAccessories
	
	if SERVER then
		self.Instance:Destroy()
		
		local Event = self.Event
		local Invoke = self.Invoke
		
		local thread = coroutine.running()
		task.spawn(function()
			repeat task.wait() until coroutine.status(thread) ~= "running"
			Event:Destroy()
			Invoke:Destroy()
		end)
		table.clear(self.Data)
		table.clear(self)
		setmetatable(self, nil)
		self = nil
	else
		local success, err = ClientCall(self, "Destroy")
		if not success then
			error("Unable to complete request", err)
		end
		
		table.clear(self)	
		setmetatable(self, nil)
	end
end


return OutfitAccessories :: OutfitAccessories

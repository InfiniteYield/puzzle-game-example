
-- OutfitHandler aka the Multiverse Avatar Module
-- Written by mewow!

-- If you don't know what you're doing, 
-- I do not suggest touching anything here except what's in the 'consts' section. Thats basically ur config.

-- For my fellow coders:
--[[

 - OutfitHandler.luau - 
	- Main module, functional handler, not OOP 
	(its a bit deceptive cuz it uses metatables but its to separate behavior from state)
	- Shared logic with server authority and client replication, works by mirroring
	- Client methods call server methods that return state.
	- This is the file you should be editing for most cases unless ur going for accessories
]]

-- services
local RunS = game:GetService("RunService")
local RepStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Players = game:GetService("Players")
local HTTP = game:GetService("HttpService")

-- modules
local MRS = RepStorage:WaitForChild("MultiverseReplicatedStorage")

local Shared = MRS:WaitForChild("Shared")

local ServerHelpers = require(script:WaitForChild("ServerHelpers"))

local Util = require(Shared.Utility)
local Types = require(Shared.Types)
local Utils = require(Shared:WaitForChild("Utility"))
local Constants = require(Shared.Constants)
local ItemUtils = require(Shared.ItemUtils)

-- consts
local MAX_ACCESSORY_SIZE = 15
local MAX_ACCESSORIES = Constants.MaxAccessories

local SERVER = RunS:IsServer()

-- assets
local NetworkHeap : Folder?
if SERVER then
	NetworkHeap = Instance.new("Folder")
	NetworkHeap.Name = "NetworkHeap"
	NetworkHeap.Parent = RepStorage
end

-- this comes after cuz it uses NetworkHeap
local OutfitAccessories = require(script.OutfitAccessories)

-- types

type OutfitData = Types.OutfitData
type Outfit = Types.Outfit

type AvatarItemDetails = Types.AvatarItemDetails
export type OutfitAccessoriesObj = OutfitAccessories.OutfitAccessories

-- vars

local ActiveOutfits : {[Model] : OutfitHandler} = {}

-- module
local OutfitHandler = {}
OutfitHandler.__index = OutfitHandler

-- observe.
export type OutfitHandler = typeof(OutfitHandler) & Outfit

-- privates

-- Wrapper for network calls. 
-- First does the required server-sided function and fires the update event after 
-- the callback (last provided arg) is performed.
-- example: ClientCall(self, "TestMethod", TestArg, function(success, res) return "hi" end)
local function ClientCall(outfit : Outfit, method : string, ...)
	
	local args = {...}
	local callback = args[#args]
	
	local function wrap(success, ...)
		if not success then
			warn("Invalid call to OutfitHandler", outfit, ..., "error:", ...)
			return
		end
		
		local res = {callback(success, ...)}
		if outfit.Updated and not outfit._HaltUpdateSignal then
			outfit.Updated:Fire(outfit.Data)
		end
		return table.unpack(res)
	end
	return wrap(outfit.Invoke:InvokeServer(method, ...))
end

-- constructors

function OutfitHandler.new(Player : Player, data : OutfitData?, target : Model?) : OutfitHandler
	if SERVER then
		
		data = data or {
			Name = "New Outfit",
			DateCreated = os.time(),
			CreatorId = Player.UserId,
			GUID = HTTP:GenerateGUID(false),
			Accessories = {},
			BodyColors = {
				Head = Color3.new(1,1,1),
				LeftArm = Color3.new(1,1,1), 
				RightArm = Color3.new(1,1,1),
				LeftLeg = Color3.new(1,1,1), 
				RightLeg = Color3.new(1,1,1), 
				Torso = Color3.new(1,1,1),
			},
			BodyPartTransparency = {
				Head = 0,
				LeftUpperArm = 0,
				RightUpperArm = 0,
				LeftLowerArm = 0,
				RightLowerArm = 0,
				LeftLowerLeg = 0,
				RightLowerLeg = 0,
				LeftUpperLeg = 0,
				RightUpperLeg = 0,
				UpperTorso = 0,
				LowerTorso = 0,
				LeftFoot = 0,
				RightFoot = 0,
				RightHand = 0,
				LeftHand = 0,
			},
			
			BodyParts = {
				Face  = 0,
				Head  = 0, 
				LeftArm = 0,
				RightArm = 0,
				LeftLeg = 0, 
				RightLeg = 0, 
				Torso = 0,	
			},
			Animations = {
				ClimbAnimation = 0,
				FallAnimation = 0,
				IdleAnimation = 0,
				JumpAnimation = 0,
				MoodAnimation = 0,
				RunAnimation = 0,
				SwimAnimation = 0, 
				WalkAnimation = 0,
			},
			Scale = {
				BodyTypeScale = 0,
				DepthScale = 0, 
				HeadScale = 0, 
				HeightScale = 0,
				ProportionScale = 0, 
				WidthScale = 0,
			},
			ClassicShirt = 0,
			ClassicPants = 0
		}
		
		-- 10/13/25 addition
		if not data.BodyPartTransparency then
			data.BodyPartTransparency = {
				Head = 0,
				LeftUpperArm = 0,
				RightUpperArm = 0,
				LeftLowerArm = 0,
				RightLowerArm = 0,
				LeftLowerLeg = 0,
				RightLowerLeg = 0,
				LeftUpperLeg = 0,
				RightUpperLeg = 0,
				UpperTorso = 0,
				LowerTorso = 0,
				LeftFoot = 0,
				RightFoot = 0,
				RightHand = 0,
				LeftHand = 0,
			}
		end
		
		local Invoke = Instance.new("RemoteFunction")
		Invoke.Name = data.GUID
		Invoke.Parent = NetworkHeap
		
		local Event = Instance.new("RemoteEvent")
		Event.Name = "ToClient"
		Event.Parent = Invoke
		
		local Updated = Instance.new("BindableEvent")
		Updated.Name = "ClientUpdate"
		Updated.Parent = Invoke
		
		local self = setmetatable({
			Player = Player,
			Data = data,
			Character = target or Player.Character,
			Event = Event,
			Invoke = Invoke,
			Updated = Updated,
		}, OutfitHandler)
		
		-- init accessories
		for i, acc in data.Accessories do
			local new = OutfitAccessories.fromData(Player, acc)
			data.Accessories[i] = new
			new.Updated.Event:Connect(function()
				Event:FireClient(Player, self)
			end)
		end
		
		Invoke.OnServerInvoke = function(sendingPlayer : Player, method : string, ...)
			if sendingPlayer ~= self.Player then
				sendingPlayer:Kick("no")
				return
			end
			
			assert(self[method], `OutfitHandler: Invalid method {method}`)
			
			local success, ret = pcall(self[method], self, ...)
			
			if not success then
				warn("Unsuccessful Invoke:", self, method, ret, debug.traceback())
				return false, ret
			end
			
			return success, ret
		end
		
		--[[if self.Character then
			self:Reconcile(true)
		end]]
		
		self.Character.Destroying:Connect(function()
			self:Destroy()
		end)
		
		return self
	else
		-- client
		
		local ClientNetwork = require(MRS:WaitForChild("ClientNetworking"))
		
		local success, returned : OutfitHandler = ClientNetwork.Invoke("OutfitHandlerInvoke", "new", data, target)
		
		returned._NetworkConns = {}
		
		setmetatable(returned, OutfitHandler)
		
		for i, v in returned.Data.Accessories do
			setmetatable(v, OutfitAccessories)
		end
		
		returned.Event.OnClientEvent:Connect(function(...)
			if returned._HaltUpdateSignal then
				return
			end
			returned.Updated:Fire(...)
		end)
		
		return returned
	end
end

function OutfitHandler.newFromCharacter(Player : Player, target : Model?) : OutfitHandler
	if SERVER then
		local target = target or Player.Character
		local hum = ServerHelpers.resolveHumanoidForTarget(Player, target)
		if not hum then return nil end
		local hd = hum:FindFirstChildOfClass("HumanoidDescription")
		if not hd then return nil end
		
		local CustomFaceOverride = target:GetAttribute("CustomFaceOverride")
		
		local existent = ActiveOutfits[target] and ActiveOutfits[target]:Pack()
		
		local outfitdata : OutfitData = existent or {
			Name = "New Outfit",
			DateCreated = os.time(),
			CreatorId = Player.UserId,
		
			Accessories = OutfitAccessories.readRigAccessories(Player, target, true),
			BodyParts   = ServerHelpers.readBodyParts(hd),
			BodyPartTransparency = ServerHelpers.readBodyPartTransparency(target),
			BodyColors  = ServerHelpers.readBodyColors(hum.Parent),
			Animations  = ServerHelpers.readAnimations(hd),
			Scale       = ServerHelpers.readScale(hd),
			ClassicShirt = hd.Shirt, 
			ClassicPants = hd.Pants,
			
			CustomFaceOverride = CustomFaceOverride
		}
		
		outfitdata.GUID = HTTP:GenerateGUID()
		
		return OutfitHandler.new(Player, outfitdata, target)
	else
		local ClientNetwork = require(RepStorage:WaitForChild("ClientNetworking"))
		
		local success, returned = ClientNetwork.Invoke("OutfitHandlerInvoke", "newFromCharacter", target)
		return returned
	end
end

-- Finds the outfit assigned to the given player's character and destroys it
function OutfitHandler.cleanByCharacter(char : Model)
	local ActiveOutfit = ActiveOutfits[char]
	if ActiveOutfit then
		ActiveOutfit:Destroy()
	end
end

-- Finds the outfit with the given GUID and destroys it
function OutfitHandler.cleanByGUID(guid : string)
	for i, v in ActiveOutfits do
		if v.Data.GUID == guid then
			v:Destroy()
			return
		end
	end
end

-- methods

function OutfitHandler:SubscribeToUpdate(key : string, f : (any?) -> nil)
	
	local self = self :: OutfitHandler
	
	if SERVER then
		return
	end
	
	if self._NetworkConns[key] then
		for i, v in self._NetworkConns[key] do
			if v.Connected then
				v:Disconnect()
			end
		end
	end
	
	self._NetworkConns[key] = {}
	
	local Event, Updated = self.Event, self.Updated
	
	local con1
	
	con1 = Updated.Event:Connect(f)
	
	table.insert(self._NetworkConns[key], con1)
end

function OutfitHandler:UnsubscribeFromUpdate(key : string)
	local self = self :: OutfitHandler
	
	
	if self._NetworkConns[key] then
		for i, v in self._NetworkConns[key] do
			if v.Connected then
				v:Disconnect()
			end
		end
	end
	
	self._NetworkConns[key] = nil
end

-- Runs the provided function with Accessory signals turned off (to avoid repetitive UI updates), then does a single update at the end.
function OutfitHandler:BatchAccOperation(f : (any) -> any, DontPingAfter : boolean)
	local self = self :: OutfitHandler
	
	if SERVER then
		return
	else
		
		self._HaltUpdateSignal = true
		local res2 = f()

		task.defer(function()
			self._HaltUpdateSignal = nil
			if not DontPingAfter then
				self.Updated:Fire(self.Data)
			end
			
		end)
			
		
		return res2
	end
end

-- Reconciles Avatar appearance with the data in this OutfitHandler
-- also calls Reconcile on all accessories
-- "Reset" determines if we use ApplyDescriptionReset or ApplyDescription
function OutfitHandler:Reconcile(Reset : boolean)
	local self = self :: OutfitHandler
	
	if SERVER then
		
		if self.Character then
			local OtherActive = ActiveOutfits[self.Character]
			if OtherActive and OtherActive ~= self then
				-- means they different
				OtherActive:Destroy()
				ActiveOutfits[self.Character] = nil
			end
		end
		
		self.Character.HumanoidRootPart.Anchored = true
		
		
		local hum = ServerHelpers.resolveHumanoidForTarget(self.Player, self.Character)
		assert(hum, "No humanoid")
		
		local data = self.Data :: OutfitData
		
		local hd = Instance.new("HumanoidDescription") :: HumanoidDescription
		for k,v in data.BodyParts do hd[k] = v end
		for k, v in data.Animations do  hd[k] = v end
		for k,v in data.Scale do  hd[k] = v end
		hd.Shirt = data.ClassicShirt or 0
		hd.Pants = data.ClassicPants or 0
		
		if not data.CustomFaceOverride and Reset then
			local Head = self.Character:FindFirstChild("Head")
			if Head then
				local dec = Head:FindFirstChildOfClass("Decal")
				if dec then
					dec:Destroy()
				end
			end
		end
		
		if Reset then
			hum:ApplyDescriptionReset(hd)
			--hum:ApplyDescription(hd)
		else
			hum:ApplyDescription(hd)
		end
		
		if data.CustomFaceOverride then
			local Head = self.Character:FindFirstChild("Head")
			if Head then
				local dec = Head:FindFirstChildOfClass("Decal")
				if dec then
					dec.Texture = `rbxassetid://{data.CustomFaceOverride}`
					self.Character:SetAttribute("CustomFaceOverride", data.CustomFaceOverride)
				end
			end
			
		else
			if self.Data.BodyParts.Face == 0 then
				local Head = self.Character:FindFirstChild("Head")
				if Head then
					local dec = Head:FindFirstChildOfClass("Decal")
					if dec then
						dec.Texture = `rbxasset://textures/face.png`
					end
				end
			end
			self.Character:SetAttribute("CustomFaceOverride", nil)
		end
		
		local bc = ServerHelpers.getOrCreateBodyColors(hum.Parent);
		bc.HeadColor3 = data.BodyColors.Head;
		bc.TorsoColor3 = data.BodyColors.Torso;
		bc.LeftArmColor3 = data.BodyColors.LeftArm;
		bc.RightArmColor3 = data.BodyColors.RightArm;
		bc.LeftLegColor3 = data.BodyColors.LeftLeg;
		bc.RightLegColor3 = data.BodyColors.RightLeg;
		
		self.Character.HumanoidRootPart.Anchored = false
	
		for _, acc in self.Data.Accessories do
			acc:Reconcile(self.Character, true)
		end
		
		-- 10/13/2025 addition
		if not self.Data.BodyPartTransparency then
			self.Data.BodyPartTransparency = {
				Head = 0,
				LeftUpperArm = 0,
				RightUpperArm = 0,
				LeftLowerArm = 0,
				RightLowerArm = 0,
				LeftLowerLeg = 0,
				RightLowerLeg = 0,
				LeftUpperLeg = 0,
				RightUpperLeg = 0,
				UpperTorso = 0,
				LowerTorso = 0,
				LeftFoot = 0,
				RightFoot = 0,
				RightHand = 0,
				LeftHand = 0,
			}
		end
		
		for i, v in self.Data.BodyPartTransparency do
			local part = self.Character:FindFirstChild(i)
			if part then
				part.Transparency = v
			end
		end
		
		ActiveOutfits[self.Character] = self
		
		return self.Data.Accessories
	else
		ClientCall(self, "Reconcile", Reset, function(success, returned)
			if success then
				self.Data.Accessories = returned
				
				for i, v in self.Data.Accessories do
					setmetatable(v, OutfitAccessories)
					if v.Instance then
						v.Impostor = ServerHelpers.EnsureImpostor(v.Instance)
					end
				end
			end
		end)		
	end
	
end

-- customization methods

function OutfitHandler:SetFace(AssetId : number, custom : boolean)
	local self = self :: OutfitHandler
	
	if SERVER then
		assert(typeof(AssetId) == "number", "invalid asset id")
		
		if custom then
			self.Data.CustomFaceOverride = AssetId
			local character = self.Character
			assert(character, "No character present.")
			local face : Decal = character.Head:FindFirstChildOfClass("Decal")
			assert(face, "No face present.")
			
			face.Texture = "rbxassetid://" .. tostring(AssetId)
		else
			local hum = ServerHelpers.resolveHumanoidForTarget(self.Player, self.Character)
			assert(hum, "No humanoid")
			local hd = hum:GetAppliedDescription()
			assert(hd, "No HD")
			
			self.Data.BodyParts.Face = AssetId
			
			local hd = hum:GetAppliedDescription()
			hd[Enum.AvatarAssetType.Face.Name] = AssetId
			hum:ApplyDescription(hd); 
		end
		return AssetId
	else
		-- client
		ClientCall(self, "SetFace", AssetId, custom, function(success, res)
			if success then
				if custom then
					self.Data.CustomFaceOverride = res
				else
					self.Data.BodyParts.Face = res
				end
			end
		end)
	end
end

-- Adds an asset based on AssetId and optional AssetType
function OutfitHandler:AddAsset(AssetId : number, AssetType : Enum.AssetType?, DontReconcile : boolean?) : nil
	local self = self :: OutfitHandler
	assert(typeof(AssetId) == "number", "invalid asset id")
	
	if not AssetType then
		AssetType = ItemUtils.GetItemDetails(AssetId, Enum.AvatarItemType.Asset).AssetType
	end
	
	local cat = Util.GetAssetCategory(AssetType)
	
	if SERVER then
		if cat == "BodyPart" or cat == "Face" or cat == "DynamicHead" then
			local name = AssetType.Name
			if name == "DynamicHead" then
				name = "Head"
			end
			self.Data.BodyParts[name] = AssetId
		elseif cat == "Animation" then
			self.Data.Animations[AssetType.Name] = AssetId
		elseif cat == "ClassicShirt" then
			self.Data.ClassicShirt = AssetId
		elseif cat == "ClassicPants" then
			self.Data.ClassicPants = AssetId
		end
		
		if not DontReconcile then
			self:Reconcile()
		end
		
		return AssetId
	else
		ClientCall(self, "AddAsset", AssetId, AssetType, DontReconcile, function(success, res)
			if success then
				if cat == "BodyPart" or cat == "Face" or cat == "DynamicHead" then
					self.Data.BodyParts[AssetType.Name] = res
				elseif cat == "Animation" then
					self.Data.Animations[AssetType.Name] = res
				elseif cat == "ClassicShirt" then
					self.Data.ClassicShirt = res
				elseif cat == "ClassicPants" then
					self.Data.ClassicPants = res
				end
			end
		end)
	end
end

function OutfitHandler:AddBundle(AssetList : {{Id : number, AssetType : Enum.AssetType}})
	local self = self :: OutfitHandler
	assert(typeof(AssetList) == "table", "invalid asset list")
	
	local function transform(given)
		for _, v in AssetList do
			local actualtype = Util.GetAssetCategory(v.AssetType)
			if actualtype == "Accessory" then
				self:AddAccessoryFromAssetId(v.Id)
			else
				self:AddAsset(v.Id, v.AssetType, true)
			end
			
		end
		
	end
	
	if SERVER then
		transform(AssetList)
		
		self:Reconcile()
		return self.Data
	else
		ClientCall(self, "AddBundle", AssetList, function(success, res)
			if success then
				self.Data = res
				for i, v in self.Data.Accessories do
					setmetatable(v, OutfitAccessories)
				end
			end
		end)
		
	end
		
end

function OutfitHandler:DeleteAssets(AssetList : {number})
	local self = self :: OutfitHandler
	assert(typeof(AssetList) == "table", "invalid asset list")
	
	local function transform(given)
		for i, AssetId in given do
			AssetId = tonumber(AssetId)
			if not AssetId then
				continue
			end
			if self.Data.ClassicShirt == AssetId then
				self.Data.ClassicShirt = 0
			elseif self.Data.ClassicPants == AssetId then
				self.Data.ClassicPants = 0
			else
				for i, v in self.Data.Animations do
					if v == AssetId then
						self.Data.Animations[i] = 0
						break
					end
				end
				
				for i, v in self.Data.BodyParts do
					if v == AssetId then
						self.Data.BodyParts[i] = 0
						break
					end
				end
				
			end
		end
	end
	
	if SERVER then
		transform(AssetList)
		
		self:Reconcile()
		return AssetList
	else
		ClientCall(self, "DeleteAssets", AssetList, function(success, res)
			if success then
				transform(res)
			end
		end)
	end
end

-- Removes an asset via AssetId. Does not work with accessories due to duplicative nature.
function OutfitHandler:DeleteAsset(AssetId : number)
	local self = self :: OutfitHandler
	assert(typeof(AssetId) == "number", "invalid asset id")
	
	if SERVER then
		if self.Data.ClassicShirt == AssetId then
			self.Data.ClassicShirt = 0
		elseif self.Data.ClassicPants == AssetId then
			self.Data.ClassicPants = 0
		else
			for i, v in self.Data.Animations do
				if v == AssetId then
					self.Data.Animations[i] = 0
					break
				end
			end
			
			for i, v in self.Data.BodyParts do
				if v == AssetId then
					self.Data.BodyParts[i] = 0
					break
				end
			end
		
		end
		
		self:Reconcile()
		return AssetId
	else
		ClientCall(self, "DeleteAsset", AssetId, function(success, res)
			if success then
				if self.Data.ClassicShirt == AssetId then
					self.Data.ClassicShirt = 0
				elseif self.Data.ClassicPants == AssetId then
					self.Data.ClassicPants = 0
				else
					
					for i, v in self.Data.Animations do
						if v == res then
							self.Data.Animations[i] = 0
							break
						end
					end
					
					for i, v in self.Data.BodyParts do
						if v == res then
							self.Data.BodyParts[i] = 0
							break
						end
					end
				end
			end	
		end)
		
	end
end

function OutfitHandler:SetBodyPart(AssetId : number, BodyPart : string?)
	local self = self :: OutfitHandler
	assert(typeof(AssetId) == "number", "invalid asset id")
	
	if SERVER then
		if not BodyPart then
			local details = ItemUtils.GetItemDetails(AssetId, Enum.AvatarItemType.Asset)
			BodyPart = Util.GetBodyPartFromAssetType(details.AssetType)
		end
		
		self.Data.BodyParts[BodyPart] = AssetId
		self:Reconcile()
		
		return {BodyPart = BodyPart, AssetId = AssetId}
	else
		if not BodyPart then
			BodyPart = Util.GetBodyPartFromAssetType(ItemUtils.GetItemDetails(AssetId, Enum.AvatarItemType.Asset).AssetType)
		end
		
		ClientCall(self, "SetBodyPart", AssetId, BodyPart, function(success, res)
			if success then
				self.Data.BodyParts[res.BodyPart] = res.AssetId
			end
		end)
		
	end
end

function OutfitHandler:SetBodyPartTransparency(BodyPartList : {string}, value : number)
	value = math.clamp(value, 0, 1)
	
	local self = self :: OutfitHandler
	assert(typeof(BodyPartList) == "table", "invalid list")
	if SERVER then
		for _, v in BodyPartList do
			self.Data.BodyPartTransparency[v] = value
		end
		self:Reconcile()
		return self.Data.BodyPartTransparency
	else
		ClientCall(self, "SetBodyPartTransparency", BodyPartList, value, function(success, ret)
			if success then
				self.Data.BodyPartTransparency = ret
			end
		end)
	end
end

function OutfitHandler:PreviewBodyPartTransparency(BodyPartList : {string}, value : number)
	local self = self :: OutfitHandler
	assert(typeof(BodyPartList) == "table", "invalid list")
	value = math.clamp(value, 0, 1)
	
	if SERVER then
		return
	end
	
	local char = self.Character
	for i, v in BodyPartList do
		local part = char:FindFirstChild(v)
		if part then
			part.Transparency = value
		end
	end
end

function OutfitHandler:SetAnimation(AssetId : number, AnimName : string)
	local self = self :: OutfitHandler
	assert(typeof(AssetId) == "number", "invalid asset id")
	assert(typeof(AnimName) == "string", "invalid anim name")
	
	if SERVER then
		local hum = ServerHelpers.resolveHumanoidForTarget(self.Player, self.Character)
		assert(hum, "No humanoid")
		local hd = hum:GetAppliedDescription()
		assert(hd, "No HD")
		
		self.Data.Animations[AnimName] = AssetId
		hd[AnimName] = AssetId
		hum:ApplyDescription(hd)
		
		return AssetId
	else
		ClientCall(self, "SetAnimation", AssetId, AnimName, function(success, res)
			if success then
				self.Data.Animations[AnimName] = res
			end
		end)
	end
end

function OutfitHandler:SetClassicShirt(AssetId : number)
	local self = self :: OutfitHandler
	assert(typeof(AssetId) == "number", "invalid asset id")
	
	if SERVER then
		local hum = ServerHelpers.resolveHumanoidForTarget(self.Player, self.Character)
		assert(hum, "No humanoid")
		local hd = hum:GetAppliedDescription()
		assert(hd, "No HD")
		
		self.Data.ClassicShirt = AssetId
		hd["Shirt"] = AssetId
		hum:ApplyDescription(hd)
		
		return AssetId
	else
		ClientCall(self, "SetClassicShirt", AssetId, function(success, res)
			if success then
				self.Data.ClassicShirt = res
			end
		end)
	end
end

function OutfitHandler:SetClassicPants(AssetId : number)
	local self = self :: OutfitHandler
	assert(typeof(AssetId) == "number", "invalid asset id")
	
	if SERVER then
		local hum = ServerHelpers.resolveHumanoidForTarget(self.Player, self.Character)
		assert(hum, "No humanoid")
		local hd = hum:GetAppliedDescription()
		assert(hd, "No HD")
		
		self.Data.ClassicPants = AssetId
		hd["Pants"] = AssetId
		hum:ApplyDescription(hd)
		
		return AssetId
	else
		ClientCall(self, "SetClassicPants", AssetId, function(success, res)
			if success then
				self.Data.ClassicPants = res
			end
		end)
	end
end

function OutfitHandler:SetCustomFace(ClassicFaceId : number?)
	local self = self :: OutfitHandler
	
	if SERVER then
		
		self.Data.CustomFaceOverride = ClassicFaceId
	
		return {ClassicFaceId, self:Reconcile(true)}
	else
		ClientCall(self, "SetCustomFace", ClassicFaceId, function(success, res)
			if success then
				self.Data.CustomFaceOverride= res[1]
				self.Data.Accessories = res[2]
				for i, v in self.Data.Accessories do
					setmetatable(v, OutfitAccessories)
				end
			end
		end)
	end
end

function OutfitHandler:PreviewBodyColors(BodyPartColors : {[string] : Color3})
	local self = self :: OutfitHandler
	assert(typeof(BodyPartColors) == "table", "invalid colors")
	
	if SERVER then
		return
	else
		local bc = self.Character:FindFirstChildOfClass("BodyColors")
		if bc then
			for BodyPart, Color in BodyPartColors do
				bc[BodyPart.."Color3"] = Color
			end
		end
	end
end

function OutfitHandler:SetBodyColors(BodyPartColors : {[string] : Color3})
	local self = self :: OutfitHandler
	
	if SERVER then
		local hum = ServerHelpers.resolveHumanoidForTarget(self.Player, self.Character)
		assert(hum, "No humanoid")
		local hd = hum:GetAppliedDescription()
		assert(hd, "No HD")
		
		local bc = ServerHelpers.getOrCreateBodyColors(self.Character)
		print("bc colors:", BodyPartColors)
		for BodyPart, Color in BodyPartColors do
			print(BodyPart, Color)
			self.Data.BodyColors[BodyPart] = Color
			bc[BodyPart.."Color3"] = Color
		end
		
		--hum:ApplyDescription(hd)
		
		return self.Data.BodyColors
	else
		ClientCall(self, "SetBodyColors", BodyPartColors, function(success, res)
			if success then
				self.Data.BodyColors = res
			end
		end)
	end
end

function OutfitHandler:SetScale(Field : string, Value : number)
	local self = self :: OutfitHandler
	assert(typeof(Value) == "number", "invalid value")
	assert(typeof(Field) == "string", "invalid field")
	
	if SERVER then
		self.Data.Scale[Field] = Value
		
		self:Reconcile()
		
		return Value
	else
		return ClientCall(self, "SetScale", Field, Value, function(success, res)
			if success then
				self.Data.Scale[Field] = res
			end
		end)
	end
end

-- Sets the layer order for the listed layered accessories
function OutfitHandler:SetLayerOrder(OrderMap : {[string] : number})
	local self = self :: OutfitHandler
	assert(typeof(OrderMap) == "table", "invalid order map")
	
	if SERVER then
		for guid, order in OrderMap do
			local acc = self:GetAccessoryByGUID(guid)
			if acc then
				acc.Data.LayerOrder = order
			end
		end
		
		self:Reconcile()
		
		return OrderMap
	else
		return ClientCall(self, "SetLayerOrder", OrderMap, function(success, res)
			if success then
				for guid, order in res do
					local acc = self:GetAccessoryByGUID(guid)
					if acc then
						acc.Data.LayerOrder = order
					end
				end
				return res
			end
		end)
	end
end

function OutfitHandler:AddAccessoryFromInstance(Accessory : Accessory) : OutfitAccessories.OutfitAccessories
	local self = self :: OutfitHandler
	assert(Accessory:IsA("Accessory"), "invalid accessory")
	
	if #self.Data.Accessories >= MAX_ACCESSORIES then
		return
	end
	
	if SERVER then
		
		local new = OutfitAccessories.fromInstance(self.Player, Accessory)
		
		table.insert(self.Data.Accessories, new)
		
		new.Updated.Event:Connect(function()
			print("serv / sending client update")
			self.Event:FireClient(self.Player, self.Data)
		end)
		
		return new
		
	else
		return ClientCall(self, "AddAccessoryFromInstance", Accessory, function(success, res)
			if success then
				local new = setmetatable(res, OutfitAccessories)
				if new.Instance then
					new.Impostor = ServerHelpers.EnsureImpostor(new.Instance)
				end
				table.insert(self.Data.Accessories, new)
				return new
			end
		end)
		
	end
end

function OutfitHandler:AddAccessoryFromData(AccessoryData : Types.OutfitAccessoryData) : OutfitAccessories.OutfitAccessories
	local self = self :: OutfitHandler
	assert(typeof(AccessoryData) == "table", "invalid accessory data")
	
	if #self.Data.Accessories >= MAX_ACCESSORIES then
		return
	end
	
	if SERVER then
		local new = OutfitAccessories.fromData(self.Player, AccessoryData)
		
		if self.Character then
			new:Reconcile(self.Character)
		end
		
		new.Updated.Event:Connect(function()
			self.Event:FireClient(self.Player, self.Data)
		end)
		
		table.insert(self.Data.Accessories, new)
		
		return new
	else
		return ClientCall(self, "AddAccessoryFromData", AccessoryData, function(success, ret)
			if success then
				local new = setmetatable(ret, OutfitAccessories)
				if new.Instance then
					new.Impostor = ServerHelpers.EnsureImpostor(new.Instance)
				end
				
				table.insert(self.Data.Accessories, new)
				
				return new
			end
		end)
	end
end

function OutfitHandler:AddAccessoryFromAssetId(AssetId : number)
	local self = self :: OutfitHandler
	
	if SERVER then
		
		local new = OutfitAccessories.fromAssetId(self.Player, AssetId)
		
		if self.Character then
			new:Reconcile(self.Character)
		end
		
		new.Updated.Event:Connect(function()
			self.Event:FireClient(self.Player, self.Data)
		end)
		
		table.insert(self.Data.Accessories, new)
		
		return new
	else
		assert(typeof(AssetId) == "number", "invalid asset id")
		return ClientCall(self, "AddAccessoryFromAssetId", AssetId, function(success, res)
			if success then
				local new = setmetatable(res, OutfitAccessories)
				if new.Instance then
					new.Impostor = ServerHelpers.EnsureImpostor(new.Instance)
				end
				table.insert(self.Data.Accessories, new)
				return new
			end
		end)
	end
end

-- Removes the provided accessories from an outfit via guid list
function OutfitHandler:DeleteAccessories(guids : {string})
	local self = self :: OutfitHandler
	
	if SERVER then
		
		for i, guid in guids do
			assert(typeof(guid) == "string", "Invalid GUID format")
			local acc, index = self:GetAccessoryByGUID(guid)
			
			if acc and index then
				table.remove(self.Data.Accessories, index)
				acc:Destroy()
			end
			
		end
		
		return self.Data.Accessories
	else
		return ClientCall(self, "DeleteAccessories", guids, function(success, accs)
			if success then
				self.Data.Accessories = accs
				for i, v in self.Data.Accessories do
					setmetatable(v, OutfitAccessories)
				end
			end
		end)
		
	end
end

-- Clones the provided accessories from an outfit via guid list and reapplies them to the character
function OutfitHandler:CloneAccessories(guids : {string})
	local self = self :: OutfitHandler
	
	if SERVER then
		
		for i, guid in guids do
			local acc, index = self:GetAccessoryByGUID(guid)
			if acc then
				local new = acc:Clone()
				table.insert(self.Data.Accessories, new)
				
				if self.Character then
					new:Reconcile(self.Character)
				end
			end
			
		end
		
		return self.Data.Accessories
	else
		return ClientCall(self, "CloneAccessories", guids, function(success, accs)
			if success then
				self.Data.Accessories = accs
				for i, v in self.Data.Accessories do
					setmetatable(v, OutfitAccessories)
					if v.Instance then
						v.Impostor = ServerHelpers.EnsureImpostor(v.Instance)
					end
				end
				
				print("accs?", accs)
			else
				warn("Unsuccessful Clone:", accs)
			end
		end)
		
	end
end

-- HELPER METHODS --

-- Gets all body colors, returns table with strings to each. Second returned is the most prevalent color (mode).
function OutfitHandler:GetBodyColors(): ({[Enum.BodyPart] : Color3}, Color3)
	local t: {[string]: Color3} = {}
	local count: {[string]: number} = {}
	for limb: string, c: Color3 in self.Data.BodyColors do
		t[Enum.BodyPart[limb]] = c
		local hex = c:ToHex()
		count[hex] = (count[hex] or 0) + 1
	end
	local chosen: Color3 = Color3.new(1,1,1)
	local best = -1
	for hex, n in count do
		if n > best then best = n; chosen = Color3.fromHex(hex) end
	end
	return t, chosen
end

-- Returns if the avatar is wearing an item with the given asset id
function OutfitHandler:IsWearingItem(AssetIdOrUUID : string | number) : boolean
	
	local self = self :: OutfitHandler
	
	AssetIdOrUUID = tostring(AssetIdOrUUID)
	
	local maindata = self.Data
	
	-- check accessories first
	for _, acc in maindata.Accessories do
		local data = acc.Data
		if tostring(data.AssetId) == AssetIdOrUUID or data.GUID == AssetIdOrUUID then
			return true
		end
	end
	
	-- now check anims
	local Anims = maindata.Animations
	
	for name, id in Anims do
		if tostring(id) == AssetIdOrUUID then
			return true
		end
	end
	
	-- face
	for bp, val in maindata.BodyParts do
		if tostring(val) == AssetIdOrUUID then
			return true
		end
	end
	
	-- shirt/pants
	if tostring(maindata.ClassicShirt) == AssetIdOrUUID then
		return true
	end
	if tostring(maindata.ClassicPants) == AssetIdOrUUID then
		return true
	end
	
	-- custom face
	if tostring(maindata.CustomFaceOverride) == AssetIdOrUUID then
		return true
	end
	
	return false
	
end

-- Returns if the avatar is all items within the given bundle
function OutfitHandler:IsWearingFullBundle(Item : AvatarItemDetails)
	if not Item.BundleType then
		return false
	end
	
	for _, Asset in Item.BundledItems do
		if Asset.Type ~= "Asset" then continue end
		
		if not self:IsWearingItem(Asset.Id) then
			return false
		end
	end
	return true
end

-- Returns all accessories with the given asset id
function OutfitHandler:GetAccessoriesByAssetId(AssetId : number) : {OutfitAccessories.OutfitAccessories}
	local self = self :: OutfitHandler
	
	local accs = {}
	
	for _, acc in self.Data.Accessories do
		if acc.Data.AssetId == AssetId then
			table.insert(accs, acc)
		end
	end
	return accs
end

-- Returns the accessory with the given GUID and its index in the accessories table
function OutfitHandler:GetAccessoryByGUID(GUID : string) : (OutfitAccessoriesObj, number)
	local self = self :: OutfitHandler
	
	for index, acc in self.Data.Accessories do
		if acc.Data.GUID == GUID then
			return acc, index
		end
	end
	
end

-- JANITOR METHODS --

-- Returns a copy of the OutfitData that's Datastore safe
function OutfitHandler:Pack() : OutfitData
	local self = self :: OutfitHandler
	
	local copy = Util.DeepCopy(self)
	
	setmetatable(copy, nil)
	
	local data = copy.Data :: OutfitData
	
	for i, acc in data.Accessories do
		if not getmetatable(acc) then
			setmetatable(acc, OutfitAccessories)
		end
		data.Accessories[i] = acc:Pack()
	end
	
	return data
end

-- resets relevant accessory data to originals/defaults
function OutfitHandler:TransformResetAccessories(Accs : {string})
	local self = self :: OutfitHandler
	
	if SERVER then
		
		for i, v in Accs do
			local acc = self:GetAccessoryByGUID(v)
			if not acc then continue end
			--acc.Data.Color = Color3.new(1,1,1)
			--acc.Data.Transparency = 0
			--acc.Data.TextureId = acc.Data.OriginalTextureId
			acc.Data.Offset = CFrame.new(0,0,0)
			acc.Data.Scale = Vector3.one
			acc.Data.AccessoryAttachmentType = acc.Data.OriginalAccessoryAttachmentType
		end
		
		self:Reconcile()
		
		return self.Data.Accessories
	else
		return ClientCall(self, "TransformResetAccessories", Accs, function(success, res)
			if success then
				self.Data.Accessories = res
				for i, v in res do
					setmetatable(v, OutfitAccessories)
				end
			end
		end)
	end
end

-- resets relevant accessory data to originals/defaults
function OutfitHandler:AppearanceResetAccessories(Accs : {string})
	local self = self :: OutfitHandler
	
	if SERVER then
		
		for i, v in Accs do
			local acc = self:GetAccessoryByGUID(v)
			if not acc then continue end
			acc.Data.Color = Color3.new(1,1,1)
			acc.Data.Transparency = 0
			acc.Data.TextureId = acc.Data.OriginalTextureId
			acc.Data.MeshId = acc.Data.OriginalMeshId
		end
		
		self:Reconcile()
		
		return self.Data.Accessories
	else
		return ClientCall(self, "AppearanceResetAccessories", Accs, function(success, res)
			if success then
				self.Data.Accessories = res
				for i, v in res do
					setmetatable(v, OutfitAccessories)
				end
			end
		end)
	end
end

-- Completely overrides all data with new data to avoid new construction
function OutfitHandler:Override(NewData : OutfitData)
	local self = self :: OutfitHandler
	
	if SERVER then
		local data = self.Data :: OutfitData
		local accs = data.Accessories
		
		for i, v : OutfitAccessoriesObj in accs do
			v:Destroy()
		end
		
		data.Accessories = {}
		
		-- init accessories
		for i, acc in NewData.Accessories do
			local new = OutfitAccessories.fromData(self.Player, acc)
			NewData.Accessories[i] = new
			new.Updated.Event:Connect(function()
				self.Event:FireClient(self.Player, self)
			end)
		end
		
		self.Data = NewData
		
		self:Reconcile()
		
		return self.Data
	else
		return ClientCall(self, "Override", NewData, function(success, res)
			if success then
				self.Data = res
				for i, v in res.Accessories do
					setmetatable(v, OutfitAccessories)
				end
			end
		end)
	end
end

-- removes all instances and such from memory under an outfit, also calls :Destroy() on accessories
function OutfitHandler:Destroy()
	local self = self :: OutfitHandler
	
	if self.Character then
		ActiveOutfits[self.Character] = nil
	end
	
	if SERVER then
		local data = self.Data :: OutfitData
		local accs = data.Accessories
		
		for i, v in accs do
			task.defer(v.Destroy, v)
		end
		
		local thread = coroutine.running()
		
		local Event = self.Event
		local Invoke = self.Invoke
		
		task.spawn(function()
			repeat task.wait() until coroutine.status(thread) ~= "running"
			Event:Destroy()
			Invoke:Destroy()
		end)
		
		
		setmetatable(self, nil)
		
		table.clear(self)
		
		return self
		
	else
		-- client
		
		local data = self.Data :: OutfitData
		local accs = data.Accessories
		
		return ClientCall(self, "Destroy", function(success, res)
			if success then
				table.clear(accs)
				
				setmetatable(self, nil)
				
				table.clear(self)
			else
				warn(res)
			end
		end)
		
	end
	
end

return OutfitHandler :: OutfitHandler
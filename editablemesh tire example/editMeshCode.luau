local AssetService = game:GetService("AssetService")

-- consts
local RAY_ACCURACY = 1 -- deg of 360
local MERGE_THRESH = 0.01 -- decimation distance threshold for the merge algorithm
local Z_ADJUSTMENT = 0.01 -- const of how the tire resizes on the Z axis as it gets larger
local INV_Z_ADJUSTMENT = 0.03 -- same as above but strictly for downsizing
local INNER_RIM_ADJUSTMENT = 3.5  -- how the much the rim is scaled per the factor, this is a divider, so smaller means more

-- vars
local inwardCache : {[EditableMesh] : {number}} = {} -- this is used by the findAllInwardCaps func only 

-- read the function title and guess what it does
local function createEditableMesh(meshPart)
	return AssetService:CreateEditableMeshAsync(meshPart.MeshContent)
end

-- finds the polar (directional around a center, aka radial) direction perpendicular around given axis at degree
local function getPolarAngle(axis: Vector3, degrees: number): Vector3
	assert(axis.Magnitude > 0, "Axis must be non-zero")
	local axisUnit = axis.Unit
	
	-- choose or validate a base direction perpendicular to the axis
	local ref: Vector3
	
	-- pick world X or Y whichever isn't parallel
	local temp = math.abs(axisUnit:Dot(Vector3.new(1,0,0))) < 0.99 and Vector3.new(1,0,0) or Vector3.new(0,1,0)
	ref = axisUnit:Cross(temp).Unit
	
	-- rotate ref around axis by the given angle
	local rad = math.rad(degrees)
	local rotation = CFrame.fromAxisAngle(axisUnit, rad)
	local dir = (rotation * ref).Unit
	
	return dir
end

-- Returns the inner faces of a EditableMesh from the origin.
-- made specifically for the tires
local function findInwardCapFaces(mesh : EditableMesh) : {[number] : boolean}
	if inwardCache[mesh] then -- avoids needless caclulation
		return inwardCache[mesh]
	end
	
	local axis = (function()
		-- gets the central axis, aka the 'axle' of the tire. you can just use cframe lookvectors also but this is more concrete
		-- in case modelers get stupid
		local size = mesh:GetSize()
		local axisLocal
		if size.X < size.Y and size.X < size.Z then
			axisLocal = Vector3.new(1, 0, 0)
		elseif size.Y < size.Z then
			axisLocal = Vector3.new(0, 1, 0)
		else
			axisLocal = Vector3.new(0, 0, 1)
		end
		return axisLocal.Unit
	end)()
	
	local cands = {}
	local center = mesh:GetCenter()
	
	local faces = {}
	
	for deg = 0, 360, RAY_ACCURACY do 
		-- deg instead of rad for readability
		local fid, point, bary = mesh:RaycastLocal(center, getPolarAngle(axis, deg))
		if fid and point and bary then
			faces[fid] = true
		end
	end
	
	return faces
end

-- scales the inner verts of the rim inward to adjust for the increase in size of the overall mesh
local function scale(editableMesh : EditableMesh, scaleFactor : number, referenceMeshPart : MeshPart) : MeshPart
	
	-- Fix the dumbass mesh
	editableMesh:MergeVertices(MERGE_THRESH)

	local inwardCaps = findInwardCapFaces(editableMesh) -- this grabs the inside rim

	for fid in inwardCaps do
		for _, vid in editableMesh:GetFaceVertices(fid) do
			local pos = editableMesh:GetPosition(vid)
			local dist = pos.Magnitude
			local translationDiff = (dist * scaleFactor)-dist
			dist -= translationDiff/INNER_RIM_ADJUSTMENT
			local newPos = pos.Unit * dist
			
			editableMesh:SetPosition(vid, 
				Vector3.new(
					pos.X 
					- math.abs(
						if scaleFactor >= 1 then 
							scaleFactor * Z_ADJUSTMENT 
						else 
							scaleFactor * INV_Z_ADJUSTMENT
					), 
					newPos.Y, 
					newPos.Z
				)
			)
		end
	end

	-- return the new actual mesh
	local newMesh = AssetService:CreateMeshPartAsync(Content.fromObject(editableMesh))
	newMesh.TextureContent = referenceMeshPart.TextureContent
	return newMesh
end

-- Apply the scaled mesh back to the part and resize the mesh
local function applyScaledTire(meshPart : MeshPart, scaleFactor : number)
	local editMesh = createEditableMesh(meshPart)
	local returnedNewMesh = scale(editMesh, scaleFactor, meshPart)
	meshPart:ApplyMesh(returnedNewMesh)   
	meshPart.Size *= Vector3.new(1, scaleFactor, scaleFactor)
end

-- run
applyScaledTire(script.Parent:WaitForChild("TireSmall"), 0.95)
applyScaledTire(script.Parent:WaitForChild("TireMid"),  1.35)
applyScaledTire(script.Parent:WaitForChild("TireLarge"),1.5)
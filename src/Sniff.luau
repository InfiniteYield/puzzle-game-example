-- Sniff.luau
-- mewow!
-- parallel word-searcher for the word-search board generator

-- types
type Board = { { string } }
type WordDict = { [string]: true }
type WordModules = { [string]: WordDict }
type Visited = { [string]: boolean }

-- vars
local MaxLen: number = 8
local MinLen: number = script.Parent.Parent:GetAttribute("MinLen")
local NeededWords: number = script.Parent.Parent:GetAttribute("NeededWords")
local MaxCompletions: number = script.Parent.Parent:GetAttribute("MaxCompletions")
local JobActive: boolean = false
local Directions: { Vector2 } = {
	Vector2.new( 1,  0), Vector2.new(-1,  0),
	Vector2.new( 0,  1), Vector2.new( 0, -1),
	Vector2.new( 1,  1), Vector2.new(-1,  1),
	Vector2.new( 1, -1), Vector2.new(-1, -1),
}

-- main
local function Sniff(
	board: Board,
	modules: WordModules,
	x: number,
	y: number,
	prefix: string,
	visited: Visited,
	sharedd: SharedTable,
	yield: boolean?
): ()
	if yield then
		task.wait()
	end
	
	visited = visited or {}
	
	local key: string = x .. "," .. y
	if x < 1 or x > #board[1] or y < 1 or y > #board then return end
	if visited[key] then return end
	
	-- mark
	visited[key] = true
	
	-- cleanup helper
	local function cleanup(): ()
		visited[key] = nil
	end
	
	-- STOP conditions
	if sharedd.Words >= NeededWords then cleanup(); return end
	if sharedd.Completed >= MaxCompletions then sharedd.Stop = true; cleanup(); return end
	
	-- build our prefix
	local newStr: string = prefix .. board[y][x]
	if #newStr <= MaxLen then
		if #newStr >= MinLen then
			local dict: WordDict? = modules[newStr:sub(1, 1)]
			if dict and dict[newStr] and not sharedd.FoundWords[newStr] then
				sharedd.FoundWords[newStr] = true
				SharedTable.increment(sharedd, "Words", 1)
			end
		end
		
		for _, dir: Vector2 in Directions do
			Sniff(board, modules,
				x + dir.X, y + dir.Y,
				newStr, visited, sharedd)
			if sharedd.Stop then break end
		end
	end
	
	-- un-mark on the way out
	cleanup()
	SharedTable.increment(sharedd, "Completed", 1)
end

-- bind wrapper
script.Parent:BindToMessage("Sniff", function(
	board: Board,
	modules: WordModules,
	startX: number,
	startY: number,
	initialString: string?,
	initialVisited: Visited?,
	sharedd: SharedTable,
	yield: boolean?
): ()
	script.Parent:SetAttribute("JobActive", true)
	task.desynchronize()
	Sniff(
		board,
		modules,
		startX, startY,
		initialString or "",
		initialVisited or {},
		sharedd,
		yield
	)
	task.synchronize()
	script.Parent:SetAttribute("JobActive", false)
end)
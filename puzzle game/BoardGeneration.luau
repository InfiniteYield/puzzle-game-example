-- BoardGeneration.luau
-- mewow!
-- board generation algorithm that ensures a solvable word exists, includes some util functions

local RS = game:GetService("ReplicatedStorage")

local gtypes = require(RS:WaitForChild("Game"):WaitForChild("types"))

export type Board = gtypes.Board
export type VisitedGrid = { [number]: { [number]: boolean } }

-- consts
local BoardSize : number = 4
local CoreCount : number = 64
local RepeatLetterFavor : number = 0.01 -- 0 to 1, lower = avoid repeats, higher = allow repeats freely
local MinVowels : number = script:GetAttribute("MinVowels")
local WordsRequired : number = script:GetAttribute("NeededWords")
local MaxCompletions : number = script:GetAttribute("MaxCompletions")
local Directions = {
	Vector2.new(1, 0), Vector2.new(-1, 0), Vector2.new(0, 1), Vector2.new(0, -1),
	Vector2.new(1, 1), Vector2.new(-1, 1), Vector2.new(1, -1), Vector2.new(-1, -1)
}

local WordModules: { [string]: { [string]: true } } = {}

-- (still consts)

-- letter weighted generation

--[[
-- old frequencies prior to adding guaranteed vowels
local LetterFrequencies = {
	{ "E", 12.02 }, { "T", 9.10  }, { "A", 8.12  },
	{ "O", 7.68  }, { "I", 7.31  }, { "N", 6.95  },
	{ "S", 6.28  }, { "R", 6.02  }, { "H", 5.92  },
	{ "D", 4.32  }, { "L", 3.98  }, { "U", 2.88  },
	{ "C", 2.71  }, { "M", 2.61  }, { "F", 2.30  },
	{ "Y", 2.11  }, { "W", 2.09  }, { "G", 2.03  },
	{ "P", 1.82  }, { "B", 1.49  }, { "V", 1.11  },
	{ "K", 0.69  }, { "X", 0.17  }, { "Q", 0.11  },
	{ "J", 0.10  }, { "Z", 0.07  },
}
]]


local LetterFrequencies = {
	{ "E",  5.27 }, { "T", 5.24 }, { "A",  3.56 },
	{ "O",  3.37 }, { "I",  3.20 }, { "N",  9.35 },
	{ "S",  8.44 }, { "R",  8.09 }, { "H",  6.96 },
	{ "D",  5.81 }, { "L",  5.35 }, { "U",  1.26 },
	{ "C",  4.64 }, { "M",  4.51 }, { "F",  3.09 },
	{ "Y",  3.84 }, { "W",  4.81 }, { "G",  3.73 },
	{ "P",  2.45 }, { "B",  3.00 }, { "V",  2.49 },
	{ "K",  1.93 }, { "X",  0.23 }, { "Q",  0.15 },
	{ "J",  1.13 }, { "Z",  0.09 },
}

local VOWELS = { A=true, E=true, I=true, O=true, U=true }

-- get the words indexed
do
	local WordsFolder = RS:WaitForChild("Words")
	for _, Letter in {"A","B","C","D","E","F","G","H","I","J","K","L","M","N","O","P","Q","R","S","T","U","V","W","X","Y","Z"} do
		WordModules[Letter] = require(WordsFolder:WaitForChild(Letter))
	end
end
-- these are from the scrabble dictionary, i wrote a cpp program to turn them into luau hashmaps lol

-- vars
local CoresSetup = false
local Cumulative : { [number]: { Letter: string, Threshold: number } } = {}

-- build cumulative distribution
do
	local Total = 0
	for _, pair in LetterFrequencies do
		Total = Total + pair[2]
	end
	local Running = 0
	for _, pair in LetterFrequencies do
		Running = Running + pair[2]
		table.insert(Cumulative, {
			Letter    = pair[1],
			Threshold = Running / Total,
		})
	end
end

-- get the cores set up

-- private funcs
local function DeepCopy(orig, seen)
	-- only tables need copying
	if type(orig) ~= "table" then
		return orig
	end
	
	seen = seen or {}
	-- handle cycles/shared refs
	if seen[orig] then
		return seen[orig]
	end
	
	local copy = {}
	seen[orig] = copy
	
	-- copy all keys and values
	for key, value in next, orig do
		copy[DeepCopy(key, seen)] = DeepCopy(value, seen)
	end
	
	-- preserve metatable, if any
	return setmetatable(copy, getmetatable(orig))
end

-- returns a random letter weighted by English frequency
function GenerateRandomLetter(Board : Board)
	local R = math.random() -- [0,1]
	for _, Entry in Cumulative do
		if R <= Entry.Threshold then
			return Entry.Letter
		end
	end
	
	-- fallback (shouldn't happen)
	return Cumulative[#Cumulative].Letter
end

-- for our thread usage
-- finds an Actor that isnt being currently used
local function GetRandomActor() : Actor
	assert(
		CoresSetup, 
		"[BoardGeneration] BoardGeneration.SetupCores() must be ran prior to attempting any generative logic."
	)
	
	local function Perform()
		local children = script:GetChildren()
		for i, v in children do
			if not v:GetAttribute("JobActive") then
				return v
			end
		end
	end
	
	local Found
	repeat 
		Found = Perform(); 
		if not Found then task.wait() end 
	until Found -- i'd do recursion but im gonna avoid overflowing our call stack lol
	
	return Found
end

local function GenerateRandomBoard(): Board
	local Board: Board = {}
	for y = 1, BoardSize do
		Board[y] = {}
		for x = 1, BoardSize do
			Board[y][x] = GenerateRandomLetter()
		end
	end
	return Board
end

local function SetupCores()
	if CoresSetup then return end
	local ActorTemplate = script:WaitForChild("Template")
	for i = 1, CoreCount do
		local Clone = ActorTemplate:Clone()
		Clone.Name = `{i}`
		Clone.Parent = script
	end
	
	ActorTemplate:Destroy()
	CoresSetup = true
	print("[BoardGeneration] Cores are set up!")
end

local function InBounds(x: number, y: number): boolean
	return x >= 1 and y >= 1 and x <= BoardSize and y <= BoardSize
end

local function SearchFromCell(x: number, y: number, Board: Board, WordsFound : SharedTable, Yield : boolean?): boolean
	task.wait()
	local Current : string = ""
	
	Current = Board[y][x]
	
	for _, Dir in Directions do
		local nx, ny = x + Dir.X, y + Dir.Y
		if InBounds(nx, ny) then
			
			local RandomActor = GetRandomActor()
			
			RandomActor:SendMessage("Sniff",
				Board,
				WordModules,
				nx,     -- origin cell
				ny,
				"",         -- prefix
				{},         -- visited
				WordsFound, Yield)
		end
	end
end

-- checks to see if a board is solvable, aka verifies
local function BoardIsSolvable(Board: Board, Yield : boolean?): boolean
	local WordsFound = SharedTable.new({Words = 0, Completed = 0, FoundWords = {}})
	
	local size  = BoardSize
	local total = size * size
	local half  = math.ceil(total / 2)
	
	for i = 1, half do
		local j = total - i + 1
		
		-- front index → (fy, fx)
		local fy = math.floor((i - 1) / size) + 1
		local fx = ((i - 1) % size) + 1
		SearchFromCell(fx, fy, Board, WordsFound, Yield)
		
		-- if j ≠ i, do the “back” index too
		if j ~= i then
			local by = math.floor((j - 1) / size) + 1
			local bx = ((j - 1) % size) + 1
			SearchFromCell(bx, by, Board, WordsFound, Yield)
		end
	end
	
	repeat 
		task.wait()
	until 
		WordsFound.Words >= WordsRequired 
	or 
		WordsFound.Completed >= MaxCompletions
	or 
		WordsFound.Stop
	
	if WordsFound.Words >= WordsRequired then
		warn("[BoardGeneration] Words found:", WordsFound.FoundWords)
		return true
	else
		return false
	end
end

-- takes a board with missing strings
local function FillBoardGaps(Board: Board): Board
	repeat
		for y = 1, BoardSize do
			for x = 1, BoardSize do
				if Board[y][x] == "" then
					Board[y][x] = GenerateRandomLetter()
				end
			end
		end
	until BoardIsSolvable(Board)
	
	return Board
end

-- generates a new board
-- GenerateBoard: returns {{string}}
function GenerateBoard(Yield : boolean?)
	print("[Board] Generating Board")
	local function Perform()
		local TotalCells = BoardSize * BoardSize
		local BoardFlat  = {}
		local LetterCounts = {}
		
		local PlannedVowelIndexes = {}
		
		-- Plan out where vowels will be
		local PlannedVowels = 0
		local NeededVowels = MinVowels
		
		-- At least 1 vowel per row if NeededVowels allows
		for Y = 1, BoardSize do
			if PlannedVowels < NeededVowels then
				local X = math.random(1, BoardSize)
				local Index = (Y - 1) * BoardSize + X
				PlannedVowelIndexes[Index] = true
				PlannedVowels += 1
			end
		end
		
		-- If still more vowels needed, sprinkle them randomly
		while PlannedVowels < NeededVowels do
			local Index = math.random(1, TotalCells)
			if not PlannedVowelIndexes[Index] then
				PlannedVowelIndexes[Index] = true
				PlannedVowels += 1
			end
		end
		
		for I = 1, TotalCells do
			local Ltr
			local IsVowelSpot = PlannedVowelIndexes[I]
			
			if IsVowelSpot then
				repeat
					Ltr = GenerateRandomLetter()
				until VOWELS[Ltr]
			else
				local Attempts = 0
				repeat
					Ltr = GenerateRandomLetter()
					Attempts += 1
					local Count = LetterCounts[Ltr] or 0
					local Probability = math.random()
					local AcceptThreshold = RepeatLetterFavor + (Count / TotalCells)
					if Probability > AcceptThreshold or Attempts > 5 then
						break
					end
				until false
			end
			
			BoardFlat[I] = Ltr
			LetterCounts[Ltr] = (LetterCounts[Ltr] or 0) + 1
		end
		
		-- Turn flat list into 2D array
		local Board2D = {}
		for Y = 1, BoardSize do
			Board2D[Y] = {}
			for X = 1, BoardSize do
				Board2D[Y][X] = BoardFlat[(Y - 1) * BoardSize + X]
			end
		end
		
		return Board2D
	end
	
	-- validate
	local Board : Board
	repeat
		Board = Perform() 
		
		-- test board
		--[[
		{
			{"A", "Q", "X","X"},
			{"O", "N", "X","X"},
			{"X", "X", "X","X"},
			{"X", "X", "X","X"},
		}
		]]
	until BoardIsSolvable(Board, Yield)
	
	return Board
	
end

-- Turns a Board into a string
local function Serialize(Board : Board) : string
	local Result = {}
	for y = 1, BoardSize do
		for x = 1, BoardSize do
			local Char = Board[y][x]
			table.insert(Result, Char ~= "" and Char or " ") -- Use space for empty
		end
	end
	return table.concat(Result)
end

local function Deserialize(Data : string) : Board
	
	assert(#Data == BoardSize * BoardSize, "Invalid Board String Length")
	
	local Board = {}
	local Index = 1
	
	for y = 1, BoardSize do
		Board[y] = {}
		for x = 1, BoardSize do
			local Char = Data:sub(Index, Index)
			Board[y][x] = (Char ~= " " and Char or "")
			Index += 1
		end
	end
	
	return Board

end

SetupCores()
-- public func key-val

return {
	GenerateBoard = GenerateBoard,
	FillBoardGaps = FillBoardGaps,
	Serialize = Serialize,
	Deserialize = Deserialize,
	Words = WordModules,
	MinLen = script:GetAttribute("MinLen"),
}

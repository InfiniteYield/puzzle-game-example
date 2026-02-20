-- Game.luau
-- mewow!
-- server
-- handles all game logic and player handling in relation to the core game loop

local module = {}

-- services
	local RS = game:GetService("ReplicatedStorage")
	local SSS = game:GetService("ServerScriptService")

-- events
	local GameEvent = RS:WaitForChild("Game")

-- modules
	local BoardGeneration = require(script:WaitForChild("BoardGeneration"))
	local Util = require(RS:WaitForChild("Essentials"):WaitForChild("Util"))
	local MainData = require(SSS:WaitForChild("Data"))
	local ScoreGuide = require(RS:WaitForChild("ScoreGuide"))

-- types
	local qtypes = require(RS:WaitForChild("Queue"):WaitForChild("types"))
	local gtypes = require(GameEvent:WaitForChild("types"))

	export type GameMode = gtypes.GameMode
	export type Board = BoardGeneration.Board

	export type PlayerData = gtypes.PlayerData
	export type GameData = gtypes.GameData

-- consts
	local GENERATE_PASSIVE_BOARDS = false -- THIS IS THE ONE THAT LAGS STUDIO
	local GAME_TIME_LEN = 60
	local CASUAL_COIN_REWARD = 5
	local COMPETITIVE_COIN_REWARD = 10
	local OTHER_COIN_REWARD = 0

	-- game moderation consts
	local _DAYINSECS = 86400
	local LEAVE_COOLDOWN = _DAYINSECS * 3 
	-- ^ 3 days in seconds, so if u wanna change the days, change the 3
	local LEAVE_PUNISHMENT_MAP = {
		[1] = 60 * 15, -- 15 mins
		[2] = 60 * 30, -- 30 mins
		[3] = 60 * 60, -- 1 hour
		[4] = 60 * 180, -- 3 hours
		[5] = _DAYINSECS, -- 1 day
		[6] = _DAYINSECS * 3, -- 3 days
		[7] = _DAYINSECS * 7, -- 1 week
		-- anything more is just a ban
	} -- ^ index is amount of leaves in a row, value is the amount of time in seconds they're banned from play
	
	
-- vars
	local MinLen = BoardGeneration.MinLen
	local CompletionMinLen = 3
	local ActiveGames : {GameData} = {
	
}

	local Boards : {Board} = {}

-- private funcs

-- Logic to grant players wins, does basic ELO equation
local function GrantWin(Winner : number, Loser : number) -- number is UserId
	Winner = game.Players:GetPlayerByUserId(Winner) or Winner
	Loser = game.Players:GetPlayerByUserId(Loser) or Loser
	
	local WinnerData, LoserData
	
	if typeof(Winner) == "number" then
		WinnerData = MainData.Get(Winner)
	else
		WinnerData = MainData.Profiles[Winner].Data
	end
	
	if typeof(Loser) == "number" then
		LoserData = MainData.Get(Loser)
	else
		LoserData = MainData.Profiles[Loser].Data
	end
	
	if not LoserData or not WinnerData then
		-- means we cant adjust anything, not really anything this function has to do to handle that
		warn("Game:GrantWin unable to find WinnerData or LoserData!", WinnerData, LoserData)
		return
	end
	
	-- consts
	local K = 30.0
	local B = 1000.0 -- baseline
	
	-- calculates win probability
	local function Prob(e1 : number, e2 : number)
		return 1 / (1 + 10^((e2-e1)/B))
	end
	
	local Rating1 = WinnerData.ELO
	local Rating2 = LoserData.ELO
	
	local P1 = Prob(Rating1, Rating2) -- winner winning
	local P2 = Prob(Rating2, Rating1) -- winner losing
	
	-- grant winner
	
	local WinnerAdjustment = Rating1+K*(1-P1)
	local LoserAdjustment = Rating2+K*(0-P2)
	
	WinnerData.ELO = math.round(WinnerAdjustment)
	LoserData.ELO = math.round(LoserAdjustment)
end

-- checks if the given player is already in a game
local function IsPlayerOccupied(Player : Player)
	return not not Player:GetAttribute("Occupied")
end

-- Creates a new PlayerData object thats used in GameData
local function CreatePlayerData(Player : Player) : PlayerData
	return {
		UserId = Player.UserId,
		Score = 0,
		Streak = 0,
		SolvedWords = {}
	}
end

-- Replicates game data to their respective clients
local function Replicate(GameData : GameData | QueueFoundData)
	local p1 = game.Players:GetPlayerByUserId(GameData.Player1Data.UserId)
	local p2 = game.Players:GetPlayerByUserId(GameData.Player2Data.UserId)
	GameEvent:FireClient(p1, GameData)
	GameEvent:FireClient(p2, GameData)
end

-- Ends a game
local function Stop(GameData : GameData)
	local p1 = game.Players:GetPlayerByUserId(GameData.Player1Data.UserId)
	local p2 = game.Players:GetPlayerByUserId(GameData.Player2Data.UserId)
	
	--TODO: handle leaving mid-match logic
	
	-- we do not award the winner if someone leaves
	-- the leaver does get a leave penalty in the Data module though
	
	if not p1 then
		-- means P1 left
		
		p2:SetAttribute("Occupied", false)
		GameEvent:FireClient(p2, false)
		MainData.Replicate(p2)
		return
	elseif not p2 then
		p1:SetAttribute("Occupied", false)

		GameEvent:FireClient(p1, false)
		MainData.Replicate(p1)
		return
		
	end
	
	local Winner : Player
	local Loser : Player
	
	-- calculate score and assign winner
	if GameData.Player1Data.Score > GameData.Player2Data.Score then
		Winner = p1
		Loser = p2
	elseif GameData.Player2Data.Score > GameData.Player1Data.Score then
		Winner = p2
		Loser = p1
	end
	
	if Winner then
		local Data = MainData.Profiles[Winner]
		if Data then
			Data.Data.Wins += 1
			Data.Data.Coins += 
				if GameData.GameType == "Casual" then
					CASUAL_COIN_REWARD
				elseif GameData.GameType == "Competitive" then
					COMPETITIVE_COIN_REWARD
				else
					OTHER_COIN_REWARD
		end
		
		if GameData.GameType == "Competitive" then
			GrantWin(Winner.UserId, Loser.UserId)
		end
	else
		-- its a tie
		
	end
	
	p1:SetAttribute("Occupied", false)
	p2:SetAttribute("Occupied", false)
	
	-- replicate new state
	GameEvent:FireClient(p1, false)
	GameEvent:FireClient(p2, false)
	
	MainData.Replicate(p1)
	MainData.Replicate(p2)
end

-- Initializes a new game by adding it to ActiveGames
local function InitGame(GameData : GameData)
	
	-- check for sanity
	local p1 = game.Players:GetPlayerByUserId(GameData.Player1Data.UserId)
	local p2 = game.Players:GetPlayerByUserId(GameData.Player2Data.UserId)
	
	assert(not IsPlayerOccupied(p1), "Player is occupied.")
	assert(not IsPlayerOccupied(p2), "Player is occupied.")
	
	table.insert(ActiveGames, GameData)
	
	p1:SetAttribute("Occupied", GameData.GameType)
	p2:SetAttribute("Occupied", GameData.GameType)
	
	Replicate(GameData)
	
	print("Init done")
	
end

-- public funcs

-- Initiates a game between the two players.
function module.Match(
	GameMode : GameMode,
	GameType : qtypes.SearchMode, 
	Player1 : Player, 
	Player2 : Player,
	DelayNum : number
) : GameData
	
	task.delay(DelayNum, function()
		print("Game Module Matching", Player1, Player2)
		-- check sanity, aka any ongoing games with either player
		
		local P1Present = Player1:IsDescendantOf(game)
		local P2Present = Player2:IsDescendantOf(game)
		
		if not P1Present or not P2Present then
			-- means someone dced
			if P1Present then
				GameEvent:FireClient(Player1, false)
				MainData.Replicate(Player1)
			end
			
			if P2Present then
				GameEvent:FireClient(Player2, false)
				MainData.Replicate(Player2)
			end
			
			return
		end
		
		assert(not IsPlayerOccupied(Player1), "Player is occupied")
		assert(not IsPlayerOccupied(Player2), "Player is occupied")
		
		local Board = Boards[1] or BoardGeneration.GenerateBoard()
		table.remove(Boards, 1)
		
		print("Board gathered:", Board)
		
		local CurrentTime = workspace:GetServerTimeNow()
		
		local GameData : GameData = {
			GameMode = GameMode,
			GameType = GameType,
			Player1Data = CreatePlayerData(Player1),
			Player2Data = CreatePlayerData(Player2),
			TimeStart = CurrentTime,
			TimeEnd = CurrentTime + GAME_TIME_LEN,
			Board = Board
		}
		
		InitGame(GameData)
	end)
	
end

function module.GetMatchFromPlayer(Player : Player) : (GameData?, PlayerData?)
	for i, match in ActiveGames do
		if match.Player1Data.UserId == Player.UserId then
			return match, match.Player1Data
		elseif match.Player2Data.UserId == Player.UserId then
			return match, match.Player2Data
		end
	end
end

-- Assesses the Leave Punishment for a player given their last leave event and strikes
function module.AssessLeavePunishment(LastLeaveEvent : number, LastLeaveStrike : number) : (number | false, number?)
	-- LeaveEvent is a timestamp of the last time they left mid-match, 
	-- LastLeaveStrike is how many offenses occurred within the LEAVE_COOLDOWN period
	
	local CurrentTime = workspace:GetServerTimeNow()
	
	if LastLeaveEvent == 0 then
		-- never left a game before, edge case
		return CurrentTime, 1
	end
	
	-- check if we need to update the strikes
	if CurrentTime - LastLeaveEvent > LEAVE_COOLDOWN then
		-- its past the cooldown so the previous strikes are forgiven
		LastLeaveStrike = 1
	else
		-- not past cooldown, increment it
		LastLeaveStrike += 1
	end
	
	if LastLeaveStrike >= #LEAVE_PUNISHMENT_MAP then
		 -- means they are in the maximum punishment, no need to increment
		 -- a false return means to ban them
		 return false
	end
	
	local ExpectedPunishment = LEAVE_PUNISHMENT_MAP[math.clamp(LastLeaveStrike, 1, #LEAVE_PUNISHMENT_MAP)]
	
	return workspace:GetServerTimeNow(), LastLeaveStrike
	
	-- yes ik tick and os.time exist
end

-- network funcs

local t = {}

function t.AddWord(Player : Player, Array : { { x : number, y : number} })
	assert(typeof(Array) == "table", "Invalid argument.")
	local Match, PlayerData = module.GetMatchFromPlayer(Player)
	assert(Match and PlayerData, "No match present.")
	local Board = Match.Board
	local Word = ""
	
	for i, v in Array do
		local Letter = Board[v.y][v.x]
		Word ..= Letter
	end
	
	print("[Game] Given word:", Word, "\n Solved words:", PlayerData.SolvedWords)
	
	if #Word >= CompletionMinLen then
		if BoardGeneration.Words[Word:sub(1,1)][Word] and not table.find(PlayerData.SolvedWords, Word) then
			-- its a word!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!! !!!!!!!!!! *inhales* !!!!!!
			table.insert(PlayerData.SolvedWords, Word)
			local Scores = ScoreGuide
			
			local WordLen = math.min(#Scores, #Word)
			local ScoreToGrant = Scores[WordLen]
			
			PlayerData.Score += ScoreToGrant
			Replicate(Match)
			
			print("score set", Player, PlayerData.Score)
			
		end
	end
	
end

-- network events

GameEvent.OnServerEvent:Connect(function(Player : Player, Request : gtypes.NetworkRequest, ...)
	assert(t[Request], "Invalid request.")
	print("Request", Player, Request, ...)
	t[Request](Player, ...)
end)

-- core loops


task.spawn(function() -- counts the active games timer down
	while true do
		-- note this is just the clock, has nothing to do with replication beyond that
		for i, data in ActiveGames do
			local P1 = game.Players:GetPlayerByUserId(data.Player1Data.UserId)
			local P2 = game.Players:GetPlayerByUserId(data.Player2Data.UserId)
			
			if not P1 or not P2 then
				-- means someone left
				Stop(data)
				table.remove(ActiveGames, i)
			end
			
			if workspace:GetServerTimeNow() >= data.TimeEnd then
				Stop(data)
				table.remove(ActiveGames, i)
			end
		end
		task.wait()
	end
end)

-- passively generates boards so they're ready for play, not required to test though cuz itll lag
task.spawn(function()
	if not GENERATE_PASSIVE_BOARDS then return end
	while true do
		local NewBoard = BoardGeneration.GenerateBoard(true)
		table.insert(Boards, NewBoard)
		print("New board generated:", NewBoard, Boards)
		task.wait(2)
	end
end)

print("Game mod returned")
return module

-- Beta-compatible, single-body-quad ESP.
-- Requires the Drawing API supplied by the host environment.

local RuntimeEnvironment = _G
if type(getgenv) == "function" then
	local success, environment = pcall(getgenv)
	if success and type(environment) == "table" then RuntimeEnvironment = environment end
end
local RuntimeKey = "__ESP_Library_Fixed_Instance"
local PreviousInstance = RuntimeEnvironment[RuntimeKey]
if type(PreviousInstance) == "table" and type(PreviousInstance.Destroy) == "function" then
	pcall(PreviousInstance.Destroy, PreviousInstance)
end

local ESP = {
	Enabled = false,
	Boxes = true,
	VisibleColor = Color3.fromRGB(255, 0, 4),
	HiddenColor = Color3.fromRGB(0, 120, 255),
	ShowHidden = true,
	TeamCheck = true,
	TeamAttributeNames = {
		"Team", "TeamId", "TeamID", "Team_ID", "TeamName", "Team_Name", "TeamColor",
		"Faction", "FactionId", "FactionID", "Faction_ID", "FactionName", "Faction_Name",
		"Side", "SideId", "SideID", "Side_ID", "Allegiance", "Alignment", "Squad",
	},
	-- Override GetTeam when this simulation stores allegiance under another name.
	-- Example: ESP.Overrides.GetTeam = function(subject) return subject:GetAttribute("Side") end
	ShowDiagnostics = true,
	DiagnosticsInterval = 5,
	MaxTrackedModels = 192, -- Safety ceiling; nearest models to the camera are kept.
	MaxRenderDistanceMeters = 500,
	DiscoveryBatchSize = 128, -- Spread large scene loads over multiple frames.
	CleanupInterval = 5,
	CleanupBatchSize = 24,
	PooledQuadReserve = 16,
	PoolTrimBatch = 2,
	ShowTargetDistance = true,
	StudsPerMeter = 3.5714286, -- Approximate Roblox scale: 1 stud = 0.28 m.
	TargetDistanceMax = 1000, -- meters
	TargetDistanceInterval = 0.1,
	TargetDistanceOffset = 24,
	BoxShift = CFrame.new(0, -1.5, 0),
	BoxSize = Vector3.new(4, 6, 0),
	RenderFOVDegrees = 120, -- Full view-cone angle; set 180 for the whole forward hemisphere.
	RenderInterval = 1 / 30,
	PruneInterval = 2,
	Thickness = 2,
	Players = true,
	player = true, -- beta compatibility: IsEnabled = "player"
	RaycastInterval = 0.2,
	RaycastsPerBatch = 8, -- Hard cap: at most 160 visibility rays per second.
	ObjectsPerBatch = 32,
	Objects = setmetatable({}, { __mode = "k" }),
	Overrides = {},
	AutoRemove = true,
}

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = workspace
local LocalPlayer = Players.LocalPlayer
local RayParams = RaycastParams.new()
RayParams.FilterType = Enum.RaycastFilterType.Exclude
RayParams.IgnoreWater = true
-- Character body parts are often non-collidable. RespectCanCollide=true would
-- skip them, causing the ray to hit the floor behind a visible character.
RayParams.RespectCanCollide = false
local TargetRayParams = RaycastParams.new()
TargetRayParams.FilterType = Enum.RaycastFilterType.Exclude
TargetRayParams.IgnoreWater = true
local LastRayCharacter, LastTargetRayCharacter

local Boxes = {}
local QuadPool = {}
local GlobalConnections = {}
local PlayerConnections = setmetatable({}, { __mode = "k" })
local Destroyed = false
local RenderWasActive = false
local NextRenderAt = 0
local NextPruneAt = 0
local PruneCursor = 1
local NextCleanupAt = 0
local CleanupRemaining = 0
local PoolTrimRemaining = 0
local LastRenderMilliseconds = 0
local LastRenderCandidates = 0
local LastVisibleBoxes = 0
local LastTeamMatches = 0
local LastTeamUnknown = 0
local RaycastsSinceDiagnostics = 0
local LastDiagnosticsAt = os.clock()

local function draw(kind, properties)
	local object = Drawing.new(kind)
	for key, value in pairs(properties or {}) do object[key] = value end
	return object
end

local function acquireQuad(color)
	local quad = table.remove(QuadPool)
	if not quad then
		quad = Drawing.new("Quad")
	end
	quad.Thickness = ESP.Thickness
	quad.Color = color
	quad.Transparency = 1
	quad.Filled = false
	quad.Visible = false
	return quad
end

local function releaseQuad(quad)
	if not quad then return end
	quad.Visible = false
	QuadPool[#QuadPool + 1] = quad
end

local TargetDistanceText = draw("Text", {
	Text = "",
	Size = 16,
	Center = true,
	Outline = true,
	Color = Color3.new(1, 1, 1),
	Position = Vector2.new(0, 0),
	Visible = false,
})
local DiagnosticsText = draw("Text", {
	Text = "",
	Size = 14,
	Center = false,
	Outline = true,
	Color = Color3.new(1, 1, 1),
	Position = Vector2.new(8, 8),
	Visible = false,
})

local function getHumanoid(model)
	-- NPC rigs have a direct Humanoid child. Recursive lookup accidentally
	-- registers wrapper/container Models around multiple NPCs as extra boxes.
	return model:FindFirstChildOfClass("Humanoid")
end

local function getPrimaryPart(object)
	if object:IsA("BasePart") then return object end
	if not object:IsA("Model") then return nil end
	return object.PrimaryPart
		or object:FindFirstChild("HumanoidRootPart", true)
		or object:FindFirstChildWhichIsA("BasePart", true)
end

local function getBoxPart(model, fallback)
	return model:FindFirstChild("UpperTorso", true)
		or model:FindFirstChild("Torso", true)
		or fallback
end

local function getVisibilityPart(model, fallback)
	-- A head-point ray catches peeking NPCs that a torso-center ray misses.
	return model:FindFirstChild("Head", true) or getBoxPart(model, fallback)
end

local function inWorkspace(object)
	return object ~= nil and object:IsDescendantOf(Workspace)
end

local function disconnectAll(connections)
	for _, connection in ipairs(connections) do connection:Disconnect() end
	table.clear(connections)
end

local function disconnectOne(connections, target)
	if target then target:Disconnect() end
	for index = #connections, 1, -1 do
		if connections[index] == target then
			table.remove(connections, index)
			return
		end
	end
end

local function removeFromArray(box)
	local index = box._index
	if not index then return end
	local last = Boxes[#Boxes]
	Boxes[index] = last
	Boxes[#Boxes] = nil
	if last and last ~= box then last._index = index end
	box._index = nil
end

function ESP:GetPlrFromChar(character)
	local override = self.Overrides.GetPlrFromChar
	if override then return override(character) end
	if not character or not character:IsA("Model") then return nil end
	return Players:GetPlayerFromCharacter(character)
end

function ESP:GetColor(object)
	local override = self.Overrides.GetColor
	if override then return override(object) end
	return self.VisibleColor
end

local function teamAttributeRank(candidate)
	if type(candidate) ~= "string" then return nil end
	local normalized = string.lower(candidate)
	for index, name in ipairs(ESP.TeamAttributeNames) do
		if string.lower(name) == normalized then return index end
	end
	return nil
end

local function getTeamAttribute(instance)
	if not instance then return nil end
	for _, name in ipairs(ESP.TeamAttributeNames) do
		local value = instance:GetAttribute(name)
		if value ~= nil then return value end
	end
	local bestRank, bestValue
	for name, value in pairs(instance:GetAttributes()) do
		local rank = teamAttributeRank(name)
		if rank and value ~= nil and (not bestRank or rank < bestRank) then
			bestRank, bestValue = rank, value
		end
	end
	return bestValue
end

local function getModelTeam(model)
	if not model then return nil end
	local value = getTeamAttribute(model)
	if value ~= nil then return value end
	local humanoid = model:FindFirstChildWhichIsA("Humanoid")
	value = getTeamAttribute(humanoid)
	if value ~= nil then return value end
	local bestRank, bestValue
	for _, descendant in ipairs(model:GetDescendants()) do
		if descendant:IsA("ValueBase") then
			local rank = teamAttributeRank(descendant.Name)
			if rank and descendant.Value ~= nil and (not bestRank or rank < bestRank) then
				bestRank, bestValue = rank, descendant.Value
			end
		end
	end
	return bestValue
end

local function getModelTeamColor(model)
	if not model then return nil end
	local color = model:GetAttribute("TeamColor")
	if color ~= nil then return color end
	local valueObject = model:FindFirstChild("TeamColor", true)
	if valueObject and valueObject:IsA("ValueBase") then return valueObject.Value end
	return nil
end

local function teamKey(value)
	if value == nil then return nil end
	local kind = typeof(value)
	if kind == "Instance" then
		if value:IsA("Team") then value = value.Name
		elseif value:IsA("ValueBase") then value = value.Value
		else return nil end
	elseif kind == "BrickColor" then
		value = value.Name
	elseif kind == "Color3" then
		value = BrickColor.new(value).Name
	end
	if type(value) == "string" then return string.lower(value) end
	if type(value) == "number" then return tostring(value) end
	return nil
end

local CachedLocalTeam = false
local LocalCharacterTeamConnections = {}
local LocalCharacterTeamValueConnections = setmetatable({}, { __mode = "k" })

local function refreshCachedLocalTeam()
	CachedLocalTeam = ESP:GetTeam(LocalPlayer) or false
end

local function bindLocalCharacterTeam(character)
	disconnectAll(LocalCharacterTeamConnections)
	table.clear(LocalCharacterTeamValueConnections)
	refreshCachedLocalTeam()
	if not character then return end
	table.insert(LocalCharacterTeamConnections, character.AttributeChanged:Connect(refreshCachedLocalTeam))
	local function watchTeamValue(instance)
		if not instance:IsA("ValueBase") or LocalCharacterTeamValueConnections[instance]
			or not teamAttributeRank(instance.Name) then return end
		local connection = instance.Changed:Connect(refreshCachedLocalTeam)
		LocalCharacterTeamValueConnections[instance] = connection
		table.insert(LocalCharacterTeamConnections, connection)
	end
	local function watchTeamSource(instance)
		watchTeamValue(instance)
		if instance:IsA("Humanoid") then
			table.insert(LocalCharacterTeamConnections, instance.AttributeChanged:Connect(refreshCachedLocalTeam))
		end
	end
	for _, instance in ipairs(character:GetDescendants()) do watchTeamSource(instance) end
	table.insert(LocalCharacterTeamConnections, character.DescendantAdded:Connect(function(instance)
		watchTeamSource(instance)
		refreshCachedLocalTeam()
	end))
	table.insert(LocalCharacterTeamConnections, character.DescendantRemoving:Connect(function(instance)
		local connection = LocalCharacterTeamValueConnections[instance]
		if connection then
			disconnectOne(LocalCharacterTeamConnections, connection)
			LocalCharacterTeamValueConnections[instance] = nil
			task.defer(refreshCachedLocalTeam)
		end
	end))
end

function ESP:GetTeam(subject)
	if not subject then return nil end
	local override = self.Overrides.GetTeam
	if override then return override(subject) end
	if typeof(subject) == "Instance" and subject:IsA("Player") then
		-- The native Teams service is authoritative for player characters.
		if subject.Team then return subject.Team end
		if not subject.Neutral and subject.TeamColor then return subject.TeamColor end
		local value = getTeamAttribute(subject)
		if value ~= nil then return value end
		value = getModelTeam(subject.Character)
		if value ~= nil then return value end
		return nil
	end
	if typeof(subject) == "Instance" and subject:IsA("Model") then
		return getModelTeam(subject)
	end
	return nil
end

CachedLocalTeam = ESP:GetTeam(LocalPlayer) or false

-- Bind only after GetTeam exists; calling refresh sooner would abort startup.
if LocalPlayer then
	table.insert(GlobalConnections, LocalPlayer:GetPropertyChangedSignal("Team"):Connect(refreshCachedLocalTeam))
	table.insert(GlobalConnections, LocalPlayer:GetPropertyChangedSignal("TeamColor"):Connect(refreshCachedLocalTeam))
	table.insert(GlobalConnections, LocalPlayer.AttributeChanged:Connect(refreshCachedLocalTeam))
	bindLocalCharacterTeam(LocalPlayer.Character)
	table.insert(GlobalConnections, LocalPlayer.CharacterAdded:Connect(bindLocalCharacterTeam))
end

function ESP:IsTeamMate(player, model, cachedModelTeam, cachedPlayerTeam)
	if not self.TeamCheck then return false, false end
	local override = self.Overrides.IsTeamMate
	if override then return override(player, model) == true, true end
	if not LocalPlayer then return false, false end
	if player == LocalPlayer or model == LocalPlayer.Character then return false, true end
	local localTeam = CachedLocalTeam
	if self.Overrides.GetTeam then localTeam = self:GetTeam(LocalPlayer) end
	local localKey = teamKey(localTeam)
	-- The render loop passes cached tokens. This avoids repeatedly searching
	-- player characters and their descendants once per frame.
	local targetTeam = cachedPlayerTeam
	if targetTeam == nil or targetTeam == false then targetTeam = cachedModelTeam end
	if (targetTeam == nil or targetTeam == false) and (self.Overrides.GetTeam or cachedModelTeam == nil) then
		targetTeam = self:GetTeam(player) or self:GetTeam(model)
	end
	local targetKey = teamKey(targetTeam)
	local comparable = localKey ~= nil and targetKey ~= nil
	if comparable and localKey == targetKey then return true, true end
	local localColor = LocalPlayer.Team and LocalPlayer.Team.TeamColor or LocalPlayer.TeamColor
	local targetColor = player and player.Team and player.Team.TeamColor
		or (player and player.TeamColor)
		or getModelTeamColor(model)
	local localColorKey, targetColorKey = teamKey(localColor), teamKey(targetColor)
	local colorComparable = localColorKey ~= nil and targetColorKey ~= nil
	if model and not player and colorComparable then
		comparable = true
		if localColorKey == targetColorKey then return true, true end
	end
	-- TeamColor is a useful fallback when a game assigns colors but leaves
	-- Player.Team unset or gives Team instances different names.
	if player and not player.Neutral and not LocalPlayer.Neutral and colorComparable then
		comparable = true
		if localColorKey == targetColorKey then return true, true end
	end
	return false, comparable
end

function ESP:GetBox(object)
	return self.Objects[object]
end

function ESP:GetTrackedCount()
	return #Boxes
end

local BoxBase = {}
BoxBase.__index = BoxBase

function BoxBase:Remove()
	if self._removed then return end
	self._removed = true
	ESP.Objects[self.Object] = nil
	removeFromArray(self)
	local quad = self.Components.BodyQuad
	if quad then
		releaseQuad(quad)
		self.Components.BodyQuad = nil
	end
	disconnectAll(self.PlayerCharacterConnections)
	table.clear(self.PlayerTeamValueConnections)
	disconnectAll(self.Connections)
end

function ESP:Toggle(enabled)
	self.Enabled = enabled == true
	if not self.Enabled or not self.ShowTargetDistance then
		TargetDistanceText.Visible = false
	end
	for _, box in ipairs(Boxes) do
		local quad = box.Components.BodyQuad
		if quad then
			quad.Visible = self.Enabled and self.Boxes and box._onScreen
				and (self.ShowHidden or box.LastVisible == true)
				and not self:IsTeamMate(box.Player, box.Object, box.TeamToken, box.PlayerTeamToken)
		end
	end
end

local function getHumanoidModelFromHit(instance)
	local current = instance
	while current and current ~= Workspace do
		if current:IsA("Model") and getHumanoid(current) then
			return current
		end
		current = current.Parent
	end
	return nil
end

local function resolvePrimary(object, option)
	if typeof(option) == "Instance" then return option end
	if type(option) == "function" then return option(object) end
	if type(option) == "string" then return object:FindFirstChild(option, true) end
	return getPrimaryPart(object)
end

function ESP:Add(object, options)
	options = options or {}
	if not object or (not object.Parent and not options.RenderInNil) then return nil end
	local primary = resolvePrimary(object, options.PrimaryPart)
	if not primary or not primary:IsA("BasePart") then return nil end

	local old = self.Objects[object]
	local color = options.Color or self:GetColor(object) or self.VisibleColor
	if old and not old._removed and old.PrimaryPart == primary then
		old.Color = color
		old.VisibleColor = color
		old.Player = options.Player or old.Player
		old.PlayerTeamToken = old.Player and (self:GetTeam(old.Player) or false) or false
		old.IsEnabled = options.IsEnabled or old.IsEnabled
		old.TeamToken = object:IsA("Model") and (getModelTeam(object) or false) or false
		return old
	end
	if old then old:Remove() end

	local box = setmetatable({
		Type = "Box",
		Object = object,
		Player = options.Player or self:GetPlrFromChar(object),
		PrimaryPart = primary,
		Humanoid = object:IsA("Model") and getHumanoid(object) or nil,
		TeamToken = object:IsA("Model") and (getModelTeam(object) or false) or false,
		PlayerTeamToken = nil,
		TeamValueConnections = {},
		PlayerTeamValueConnections = {},
		PlayerCharacterConnections = {},
		BoxPart = object:IsA("Model") and getBoxPart(object, primary) or primary,
		VisibilityPart = object:IsA("Model") and getVisibilityPart(object, primary) or primary,
		Size = options.Size or self.BoxSize,
		Color = color,
		VisibleColor = color,
		HiddenColor = options.HiddenColor or self.HiddenColor,
		Components = {},
		Connections = {},
		IsEnabled = options.IsEnabled,
		Temporary = options.Temporary,
		ColorDynamic = options.ColorDynamic,
		RenderInNil = options.RenderInNil,
		LastVisible = nil,
		LastPartCFrame = nil,
		_onScreen = false,
		_removed = false,
	}, BoxBase)
	box.PlayerTeamToken = box.Player and (self:GetTeam(box.Player) or false) or false

	box.Components.BodyQuad = acquireQuad(box.HiddenColor)
	self.Objects[object] = box
	box._index = #Boxes + 1
	Boxes[box._index] = box

	local function removeIfDetached()
		if self.AutoRemove ~= false and not box.RenderInNil and not inWorkspace(object) then
			box:Remove()
		end
	end
	table.insert(box.Connections, object.AncestryChanged:Connect(removeIfDetached))
	if object:IsA("Model") then
		local function refreshTeamToken()
			if not box._removed then box.TeamToken = getModelTeam(object) or false end
		end
		local function watchTeamValue(instance)
			if not instance:IsA("ValueBase") or box.TeamValueConnections[instance]
				or not teamAttributeRank(instance.Name) then return end
			local connection = instance.Changed:Connect(refreshTeamToken)
			box.TeamValueConnections[instance] = connection
			table.insert(box.Connections, connection)
		end
		table.insert(box.Connections, object.AttributeChanged:Connect(function()
			refreshTeamToken()
		end))
		for _, descendant in ipairs(object:GetDescendants()) do
			watchTeamValue(descendant)
		end
		table.insert(box.Connections, object.DescendantAdded:Connect(function(instance)
			if instance:IsA("ValueBase") then
				watchTeamValue(instance)
				refreshTeamToken()
			end
			if instance:IsA("BasePart") and (instance.Name == "UpperTorso" or instance.Name == "Torso" or instance.Name == "Head") then
				box.BoxPart = getBoxPart(object, primary)
				box.VisibilityPart = getVisibilityPart(object, primary)
				box.LastPartCFrame = nil
			end
		end))
		table.insert(box.Connections, object.DescendantRemoving:Connect(function(instance)
			local valueConnection = box.TeamValueConnections[instance]
			if valueConnection then
				disconnectOne(box.Connections, valueConnection)
				box.TeamValueConnections[instance] = nil
				task.defer(refreshTeamToken)
			end
			if instance == box.BoxPart or instance == box.VisibilityPart then
				task.defer(function()
					if not box._removed then
						box.BoxPart = getBoxPart(object, primary)
						box.VisibilityPart = getVisibilityPart(object, primary)
						box.LastPartCFrame = nil
					end
				end)
			end
		end))
	end
	if box.Player then
		local function refreshPlayerTeam()
			if not box._removed then
				box.PlayerTeamToken = self:GetTeam(box.Player) or false
			end
		end
		local function watchPlayerCharacter(character)
			disconnectAll(box.PlayerCharacterConnections)
			table.clear(box.PlayerTeamValueConnections)
			if character then
				table.insert(box.PlayerCharacterConnections, character.AttributeChanged:Connect(refreshPlayerTeam))
				local function watchPlayerTeamValue(instance)
					if not instance:IsA("ValueBase") or box.PlayerTeamValueConnections[instance]
						or not teamAttributeRank(instance.Name) then return end
					local connection = instance.Changed:Connect(refreshPlayerTeam)
					box.PlayerTeamValueConnections[instance] = connection
					table.insert(box.PlayerCharacterConnections, connection)
				end
				local function watchPlayerTeamSource(instance)
					watchPlayerTeamValue(instance)
					if instance:IsA("Humanoid") then
						table.insert(box.PlayerCharacterConnections, instance.AttributeChanged:Connect(refreshPlayerTeam))
					end
				end
				for _, instance in ipairs(character:GetDescendants()) do watchPlayerTeamSource(instance) end
				table.insert(box.PlayerCharacterConnections, character.DescendantAdded:Connect(function(instance)
					watchPlayerTeamSource(instance)
					refreshPlayerTeam()
				end))
				table.insert(box.PlayerCharacterConnections, character.DescendantRemoving:Connect(function(instance)
					local valueConnection = box.PlayerTeamValueConnections[instance]
					if valueConnection then
						disconnectOne(box.PlayerCharacterConnections, valueConnection)
						box.PlayerTeamValueConnections[instance] = nil
						refreshPlayerTeam()
					end
				end))
			end
		end
		table.insert(box.Connections, box.Player:GetPropertyChangedSignal("Team"):Connect(refreshPlayerTeam))
		table.insert(box.Connections, box.Player:GetPropertyChangedSignal("TeamColor"):Connect(refreshPlayerTeam))
		table.insert(box.Connections, box.Player.AttributeChanged:Connect(refreshPlayerTeam))
		watchPlayerCharacter(box.Player.Character)
		table.insert(box.Connections, box.Player.CharacterAdded:Connect(function(character)
			watchPlayerCharacter(character)
			refreshPlayerTeam()
		end))
	end
	if primary ~= object then
		table.insert(box.Connections, primary.AncestryChanged:Connect(function()
			if self.AutoRemove ~= false and not inWorkspace(primary) then box:Remove() end
		end))
	end
	local humanoid = object:IsA("Model") and getHumanoid(object)
	if humanoid then
		table.insert(box.Connections, humanoid.AttributeChanged:Connect(function()
			if not box._removed then box.TeamToken = getModelTeam(object) or false end
		end))
		-- Some games set Health to zero without firing Died reliably, and some
		-- destroy/remove the Humanoid while leaving the corpse Model in Workspace.
		table.insert(box.Connections, humanoid.HealthChanged:Connect(function(health)
			if health <= 0 and self.AutoRemove ~= false then box:Remove() end
		end))
		table.insert(box.Connections, humanoid.Died:Connect(function()
			if self.AutoRemove ~= false then box:Remove() end
		end))
		table.insert(box.Connections, humanoid.AncestryChanged:Connect(function(_, parent)
			if parent == nil and self.AutoRemove ~= false then box:Remove() end
		end))
		table.insert(box.Connections, humanoid.Destroying:Connect(function()
			if self.AutoRemove ~= false then box:Remove() end
		end))
	end
	return box
end

function ESP:AddObjectListener(parent, options)
	if not parent then return end
	options = options or {}
	local pending = setmetatable({}, { __mode = "k" })
	local function newListener(instance)
		if Destroyed or pending[instance] then return end
		if options.Type and (type(options.Type) ~= "string" or not instance:IsA(options.Type)) then return end
		if options.Name and instance.Name ~= options.Name then return end
		if options.Recursive then
			if not instance:IsDescendantOf(parent) then return end
		elseif instance.Parent ~= parent then
			return
		end
		pending[instance] = true
		local function finish(valid)
			pending[instance] = nil
			if not valid or Destroyed or not instance.Parent then return end
			local color = type(options.Color) == "function" and options.Color(instance) or options.Color
			local box = ESP:Add(instance, {
				PrimaryPart = resolvePrimary(instance, options.PrimaryPart),
				Color = color,
				ColorDynamic = options.ColorDynamic,
				IsEnabled = options.IsEnabled,
				RenderInNil = options.RenderInNil,
			})
			if box and options.OnAdded then task.spawn(options.OnAdded, box) end
		end
		if options.Validator then
			task.spawn(function()
				local success, valid = pcall(options.Validator, instance)
				finish(success and valid)
			end)
		else
			finish(true)
		end
	end
	local signal = options.Recursive and parent.DescendantAdded or parent.ChildAdded
	table.insert(GlobalConnections, signal:Connect(newListener))
	local initial = options.Recursive and parent:GetDescendants() or parent:GetChildren()
	for _, instance in ipairs(initial) do newListener(instance) end
end

-- Resolve and track a character model once even when Roblox streams its parts
-- in separately. This avoids repeatedly scanning the same model per part.
local function trackModel(model)
	if not model or not inWorkspace(model) then return end
	local humanoid = getHumanoid(model)
	if not humanoid or humanoid.Health <= 0 then return end
	local player = ESP:GetPlrFromChar(model)
	if player == LocalPlayer then return end
	local primary = getPrimaryPart(model)
	local current = ESP.Objects[model]
	if primary and (not current or current.PrimaryPart ~= primary) then
		local maximum = math.max(1, math.floor(ESP.MaxTrackedModels or 192))
		if not current and #Boxes >= maximum then
			local camera = Workspace.CurrentCamera
			if not camera then return end
			local cameraPosition = camera.CFrame.Position
			local candidateOffset = primary.Position - cameraPosition
			local candidateDistanceSquared = candidateOffset:Dot(candidateOffset)
			local farthest, farthestDistanceSquared = nil, candidateDistanceSquared
			for _, tracked in ipairs(Boxes) do
				local trackedPart = tracked.PrimaryPart
				if trackedPart and trackedPart.Parent then
					local offset = trackedPart.Position - cameraPosition
					local distanceSquared = offset:Dot(offset)
					if distanceSquared > farthestDistanceSquared then
						farthest, farthestDistanceSquared = tracked, distanceSquared
					end
				end
			end
			-- Keep a bounded set of nearest models. A distant, newly spawned NPC
			-- cannot grow the Drawing/connection count indefinitely.
			if not farthest then return end
			farthest:Remove()
		end
		ESP:Add(model, { PrimaryPart = primary, Player = player })
	end
end

local PendingModels = setmetatable({}, { __mode = "k" })
local PendingTrackQueue = {}
local TrackFlushScheduled = false
local TrackQueueHead, TrackQueueTail = 1, 0
local function flushTrackQueue()
	while not Destroyed do
		local processed = 0
		local batchSize = math.max(1, math.floor(ESP.DiscoveryBatchSize or 128))
		while TrackQueueHead <= TrackQueueTail and processed < batchSize do
			local pendingModel = PendingTrackQueue[TrackQueueHead]
			PendingTrackQueue[TrackQueueHead] = nil
			TrackQueueHead += 1
			PendingModels[pendingModel] = nil
			if pendingModel then trackModel(pendingModel) end
			processed += 1
		end
		if TrackQueueHead > TrackQueueTail then
			table.clear(PendingTrackQueue)
			TrackQueueHead, TrackQueueTail = 1, 0
			TrackFlushScheduled = false
			return
		end
		task.wait()
	end
	table.clear(PendingTrackQueue)
	TrackQueueHead, TrackQueueTail = 1, 0
	TrackFlushScheduled = false
end
local function queueTrack(instance)
	if not instance:IsA("Model") and not instance:IsA("Humanoid") and not instance:IsA("BasePart") then return end
	local model
	if instance:IsA("Model") then
		model = instance
	elseif instance:IsA("Humanoid") then
		model = instance.Parent and instance.Parent:IsA("Model") and instance.Parent or nil
	else
		model = instance:FindFirstAncestorWhichIsA("Model")
	end
	if not model or PendingModels[model] then return end
	PendingModels[model] = true
	TrackQueueTail += 1
	PendingTrackQueue[TrackQueueTail] = model
	if TrackFlushScheduled then return end
	TrackFlushScheduled = true
	task.spawn(flushTrackQueue)
end

table.insert(GlobalConnections, Workspace.DescendantAdded:Connect(queueTrack))

-- GetDescendants is one unavoidable snapshot; process that snapshot in small
-- slices so joining a large pre-populated world does not stall one frame.
local InitialDescendants = Workspace:GetDescendants()
local InitialDescendantCount = #InitialDescendants
task.spawn(function()
	local batchSize = math.max(1, math.floor(ESP.DiscoveryBatchSize or 128))
	for index = 1, InitialDescendantCount do
		local instance = InitialDescendants[index]
		InitialDescendants[index] = nil
		if not Destroyed and instance:IsA("Humanoid") and instance.Parent and instance.Parent:IsA("Model") then
			trackModel(instance.Parent)
		end
		if index % batchSize == 0 then
			task.wait()
			if Destroyed then break end
		end
	end
	table.clear(InitialDescendants)
end)

local function characterAdded(character)
	if character ~= (LocalPlayer and LocalPlayer.Character) then trackModel(character) end
end
local function connectPlayer(player)
	if player == LocalPlayer or PlayerConnections[player] then return end
	PlayerConnections[player] = player.CharacterAdded:Connect(characterAdded)
	if player.Character then characterAdded(player.Character) end
end
table.insert(GlobalConnections, Players.PlayerAdded:Connect(connectPlayer))
table.insert(GlobalConnections, Players.PlayerRemoving:Connect(function(player)
	local connection = PlayerConnections[player]
	if connection then
		connection:Disconnect()
		PlayerConnections[player] = nil
	end
	local character = player.Character
	local box = character and ESP.Objects[character]
	if box then box:Remove() end
end))
for _, player in ipairs(Players:GetPlayers()) do
	connectPlayer(player)
end

local function projectPoint(camera, point, cameraPosition, lookVector)
	if (point - cameraPosition):Dot(lookVector) <= 0 then return nil, nil end
	local screen = camera:WorldToViewportPoint(point)
	if screen.Z <= 0 then return nil, nil end
	return screen.X, screen.Y
end

local function projectBox(box, camera, cameraCF, viewport, fieldOfView)
	local quad = box.Components.BodyQuad
	local part = box.BoxPart
	if not part or not part.Parent then
		box._onScreen = false
		quad.Visible = false
		return
	end
	local partCF = part.CFrame
	if box._camera == camera and box._cameraCF == cameraCF and box._viewport == viewport
		and box._fieldOfView == fieldOfView and box._size == box.Size and box._shift == ESP.BoxShift
		and box.LastPartCFrame == partCF then
		quad.Visible = ESP.Enabled and ESP.Boxes and box._onScreen
			and (ESP.ShowHidden or box.LastVisible == true)
		return
	end
	box._camera, box._cameraCF, box._viewport = camera, cameraCF, viewport
	box._fieldOfView, box._size, box._shift = fieldOfView, box.Size, ESP.BoxShift
	box.LastPartCFrame = partCF

	local cameraPosition, lookVector = cameraCF.Position, cameraCF.LookVector
	local shifted = partCF * ESP.BoxShift
	local center = shifted.Position
	if (center - cameraPosition):Dot(lookVector) <= 0 then
		box._onScreen = false
		quad.Visible = false
		return
	end
	local halfX, halfY = box.Size.X / 2, box.Size.Y / 2
	local right = shifted.RightVector * halfX
	local up = shifted.UpVector * halfY
	local x1, y1 = projectPoint(camera, center + right + up, cameraPosition, lookVector)
	local x2, y2 = projectPoint(camera, center - right + up, cameraPosition, lookVector)
	local x3, y3 = projectPoint(camera, center + right - up, cameraPosition, lookVector)
	local x4, y4 = projectPoint(camera, center - right - up, cameraPosition, lookVector)
	if not x1 or not x2 or not x3 or not x4 then
		box._onScreen = false
		quad.Visible = false
		return
	end
	local minX = math.min(x1, x2, x3, x4)
	local maxX = math.max(x1, x2, x3, x4)
	local minY = math.min(y1, y2, y3, y4)
	local maxY = math.max(y1, y2, y3, y4)
	local onScreen = maxX >= 0 and minX <= viewport.X and maxY >= 0 and minY <= viewport.Y
	box._onScreen = onScreen
	quad.Visible = ESP.Enabled and ESP.Boxes and onScreen
		and (ESP.ShowHidden or box.LastVisible == true)
	if onScreen then
		quad.PointA, quad.PointB = Vector2.new(x2, y2), Vector2.new(x1, y1)
		quad.PointC, quad.PointD = Vector2.new(x3, y3), Vector2.new(x4, y4)
	end
end

local function isInsideRenderFOV(box, cameraCF, cosHalfFOV, maxDistanceSquared)
	local part = box.BoxPart or box.PrimaryPart
	if not part or not part.Parent then return false end
	local offset = part.Position - cameraCF.Position
	local distanceSquared = offset:Dot(offset)
	if distanceSquared > maxDistanceSquared then return false end
	local forwardDistance = offset:Dot(cameraCF.LookVector)
	if forwardDistance <= 0 then return false end
	return forwardDistance * forwardDistance >= distanceSquared * cosHalfFOV * cosHalfFOV
end

local function pruneBatch(maxChecks)
	local checked = 0
	while checked < maxChecks and #Boxes > 0 do
		if PruneCursor > #Boxes then PruneCursor = 1 end
		local box = Boxes[PruneCursor]
		local humanoid = box.Humanoid
		local stale = not box.RenderInNil and (not inWorkspace(box.Object) or not inWorkspace(box.PrimaryPart)
			or (humanoid and (not humanoid.Parent or humanoid.Health <= 0)))
		checked += 1
		if stale then
			box:Remove() -- swap-removal keeps the cursor on the moved entry
		else
			PruneCursor += 1
		end
	end
	return checked
end

local function updateDiagnostics(now)
	if not ESP.ShowDiagnostics then
		DiagnosticsText.Visible = false
		return
	end
	local interval = math.max(1, ESP.DiagnosticsInterval or 5)
	if now - LastDiagnosticsAt < interval then return end
	local elapsed = math.max(0.001, now - LastDiagnosticsAt)
	local rayRate = RaycastsSinceDiagnostics / elapsed
	local queued = math.max(0, TrackQueueTail - TrackQueueHead + 1)
	local localTeam = teamKey(ESP:GetTeam(LocalPlayer)) or "unknown"
	DiagnosticsText.Text = string.format(
		"ESP\nTracked: %d / %d   On-screen: %d\nCandidates: %d   Queue: %d\nRays: %.1f/s   Render: %.2f ms\nTeam matches: %d   Unknown: %d   Local: %s",
		#Boxes,
		math.max(1, math.floor(ESP.MaxTrackedModels or 192)),
		LastVisibleBoxes,
		LastRenderCandidates,
		queued,
		rayRate,
		LastRenderMilliseconds,
		LastTeamMatches,
		LastTeamUnknown,
		localTeam
	)
	DiagnosticsText.Visible = true
	RaycastsSinceDiagnostics = 0
	LastDiagnosticsAt = now
end

table.insert(GlobalConnections, RunService.RenderStepped:Connect(function()
	if Destroyed then return end
	local now = os.clock()
	if now >= NextCleanupAt then
		CleanupRemaining = #Boxes
		PoolTrimRemaining = 0
		NextCleanupAt = now + math.max(1, ESP.CleanupInterval or 5)
		if CleanupRemaining == 0 then
			PoolTrimRemaining = math.max(0, #QuadPool - (ESP.PooledQuadReserve or 16))
		end
	end
	if CleanupRemaining > 0 then
		local batchSize = math.max(1, math.floor(ESP.CleanupBatchSize or 24))
		local checked = pruneBatch(math.min(batchSize, CleanupRemaining))
		CleanupRemaining = math.max(0, CleanupRemaining - checked)
		if #Boxes == 0 or CleanupRemaining == 0 then
			CleanupRemaining = 0
			PoolTrimRemaining = math.max(0, #QuadPool - (ESP.PooledQuadReserve or 16))
		end
	end
	if PoolTrimRemaining > 0 then
		local trimCount = math.min(
			math.max(1, math.floor(ESP.PoolTrimBatch or 2)),
			PoolTrimRemaining,
			#QuadPool
		)
		for _ = 1, trimCount do
			local quad = table.remove(QuadPool)
			if quad then pcall(function() quad:Remove() end) end
		end
		PoolTrimRemaining = math.max(0, PoolTrimRemaining - trimCount)
	end
	updateDiagnostics(now)
	if now >= NextPruneAt then
		CachedLocalTeam = ESP:GetTeam(LocalPlayer) or false
		NextPruneAt = now + math.max(0.5, ESP.PruneInterval or 2)
	end
	local renderInterval = math.max(1 / 120, math.min(0.25, ESP.RenderInterval or (1 / 30)))
	if now < NextRenderAt then return end
	NextRenderAt = now + renderInterval
	if not ESP.Enabled or not ESP.Boxes then
		if RenderWasActive then
			for _, box in ipairs(Boxes) do
				local quad = box.Components.BodyQuad
				if quad then quad.Visible = false end
				box._onScreen = false
				box.LastPartCFrame = nil
			end
		end
		RenderWasActive = false
		return
	end
	local camera = Workspace.CurrentCamera
	if not camera then
		if RenderWasActive then
			for _, box in ipairs(Boxes) do
				box._onScreen = false
				box.Components.BodyQuad.Visible = false
				box.LastPartCFrame = nil
			end
		end
		RenderWasActive = false
		return
	end
	RenderWasActive = true
	local cameraCF, viewport, fieldOfView = camera.CFrame, camera.ViewportSize, camera.FieldOfView
	local renderFOV = math.max(1, math.min(180, ESP.RenderFOVDegrees or 180))
	local cosHalfFOV = math.cos(math.rad(renderFOV * 0.5))
	local maxDistance = (ESP.MaxRenderDistanceMeters or math.huge) * (ESP.StudsPerMeter or 3.5714286)
	local maxDistanceSquared = maxDistance * maxDistance
	local renderStartedAt = os.clock()
	local candidateCount, visibleCount, teamMatchCount, teamUnknownCount = 0, 0, 0, 0
	for _, box in ipairs(Boxes) do
		if not isInsideRenderFOV(box, cameraCF, cosHalfFOV, maxDistanceSquared) then
			box._insideRenderFOV = false
			box.LastPartCFrame = nil
			box._onScreen = false
			box.Components.BodyQuad.Visible = false
		else
			candidateCount += 1
			if box._insideRenderFOV == false then box.LastPartCFrame = nil end
			box._insideRenderFOV = true
			local isTeammate, teamComparable = ESP:IsTeamMate(
				box.Player, box.Object, box.TeamToken, box.PlayerTeamToken
			)
			if isTeammate then
				teamMatchCount += 1
			elseif not teamComparable then
				teamUnknownCount += 1
			end
			local allow = (not box.Player or ESP.Players)
				and not isTeammate
			if box.IsEnabled then
				if type(box.IsEnabled) == "string" then
					allow = allow and ESP[box.IsEnabled] == true
				elseif type(box.IsEnabled) == "function" then
					allow = allow and box:IsEnabled() ~= false
				end
			end
			if ESP.Overrides.UpdateAllow and not ESP.Overrides.UpdateAllow(box) then allow = false end
			if not allow then
				box.Components.BodyQuad.Visible = false
			elseif box._removed or (not box.RenderInNil and not inWorkspace(box.PrimaryPart)) then
				box._onScreen = false
				box.Components.BodyQuad.Visible = false
			else
				projectBox(box, camera, cameraCF, viewport, fieldOfView)
				if box._onScreen and box.Components.BodyQuad.Visible then
					visibleCount += 1
				end
			end
		end
	end
	LastRenderMilliseconds = (os.clock() - renderStartedAt) * 1000
	LastRenderCandidates = candidateCount
	LastVisibleBoxes = visibleCount
	LastTeamMatches = teamMatchCount
	LastTeamUnknown = teamUnknownCount
end))

-- A single visibility ray per box interval; batches cap per-wakeup work.
task.spawn(function()
	local cursor = 1
	while not Destroyed do
		task.wait(0.05)
		if not ESP.Enabled or not ESP.Boxes or #Boxes == 0 then
			cursor = 1
			continue
		end
		local camera = Workspace.CurrentCamera
		if not camera then continue end
		local character = LocalPlayer and LocalPlayer.Character
		if LastRayCharacter ~= character then
			RayParams.FilterDescendantsInstances = character and { character } or {}
			LastRayCharacter = character
		end
		local origin, now = camera.CFrame.Position, os.clock()
		local limit = math.min(#Boxes, ESP.ObjectsPerBatch)
		local checked, rays = 0, 0
		while checked < limit and rays < ESP.RaycastsPerBatch and #Boxes > 0 do
			if cursor > #Boxes then cursor = 1 end
			local box = Boxes[cursor]
			cursor += 1
			checked += 1
			local part = box.VisibilityPart or box.BoxPart
			if not box._removed and part and part.Parent and box._onScreen
				and (not box.Player or ESP.Players)
				and not ESP:IsTeamMate(box.Player, box.Object, box.TeamToken, box.PlayerTeamToken)
				and now >= (box._nextRaycast or 0) then
				box._nextRaycast = now + ESP.RaycastInterval
				local result = Workspace:Raycast(origin, part.Position - origin, RayParams)
				RaycastsSinceDiagnostics += 1
				local visible = result == nil or result.Instance:IsDescendantOf(box.Object)
				if box.LastVisible ~= visible then
					box.LastVisible = visible
					box.Components.BodyQuad.Color = visible and box.VisibleColor or box.HiddenColor
					box.Components.BodyQuad.Visible = ESP.Enabled and ESP.Boxes and box._onScreen
						and (visible or ESP.ShowHidden)
				end
				rays += 1
			end
		end
	end
end)

function ESP:Destroy()
	if Destroyed then return end
	Destroyed = true
	while #Boxes > 0 do Boxes[#Boxes]:Remove() end
	for index = #QuadPool, 1, -1 do
		local quad = QuadPool[index]
		QuadPool[index] = nil
		pcall(function() quad:Remove() end)
	end
	TargetDistanceText.Visible = false
	TargetDistanceText:Remove()
	DiagnosticsText.Visible = false
	DiagnosticsText:Remove()
	for player, connection in pairs(PlayerConnections) do
		connection:Disconnect()
		PlayerConnections[player] = nil
	end
	disconnectAll(LocalCharacterTeamConnections)
	disconnectAll(GlobalConnections)
	if RuntimeEnvironment[RuntimeKey] == self then RuntimeEnvironment[RuntimeKey] = nil end
end

-- If this is running as a Roblox Script/LocalScript, destroying the script
-- also stops its loops and releases Drawing objects.
local ScriptInstance = script
if typeof(ScriptInstance) == "Instance" then
	local success, destroyingSignal = pcall(function() return ScriptInstance.Destroying end)
	if success and destroyingSignal then
		table.insert(GlobalConnections, destroyingSignal:Connect(function() ESP:Destroy() end))
	end
end

-- Center-screen target check is independent from RenderStepped and runs at a
-- low fixed rate. It shows distance only when the ray directly hits a Humanoid.
task.spawn(function()
	local lastText, lastPosition
	while not Destroyed do
		task.wait(ESP.TargetDistanceInterval)
		if not ESP.Enabled or not ESP.ShowTargetDistance then
			TargetDistanceText.Visible = false
			continue
		end
		local camera = Workspace.CurrentCamera
		if not camera then
			TargetDistanceText.Visible = false
			continue
		end

		local viewport = camera.ViewportSize
		local centerX, centerY = viewport.X / 2, viewport.Y / 2
		local cameraRay = camera:ViewportPointToRay(centerX, centerY)
		local character = LocalPlayer and LocalPlayer.Character
		if LastTargetRayCharacter ~= character then
			TargetRayParams.FilterDescendantsInstances = character and { character } or {}
			LastTargetRayCharacter = character
		end
		local result = Workspace:Raycast(
			cameraRay.Origin,
			cameraRay.Direction * ESP.TargetDistanceMax * ESP.StudsPerMeter,
			TargetRayParams
		)
		RaycastsSinceDiagnostics += 1
		local model = result and getHumanoidModelFromHit(result.Instance)
		local player = model and ESP:GetPlrFromChar(model)
		if not model or (player == LocalPlayer) or ESP:IsTeamMate(player, model) then
			TargetDistanceText.Visible = false
			lastText = nil
			continue
		end

		local distance = (result.Position - cameraRay.Origin).Magnitude
		local text = string.format("%d m", math.floor(distance / ESP.StudsPerMeter + 0.5))
		local position = Vector2.new(centerX, centerY + ESP.TargetDistanceOffset)
		if text ~= lastText then
			TargetDistanceText.Text = text
			lastText = text
		end
		if position ~= lastPosition then
			TargetDistanceText.Position = position
			lastPosition = position
		end
		TargetDistanceText.Visible = true
	end
end)

ESP:Toggle(true)

RuntimeEnvironment[RuntimeKey] = ESP
return ESP

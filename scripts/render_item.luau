-- Sky render: transparent-background render of one item, done with viewport screenshots.
-- Paste this whole file into execute_luau (Edit datamodel) after editing CONFIG.
-- Everything it changes in the place is put back before it returns, even on error.
-- The finished image is kept in CoreGui.SkyRenderResults (not saved with the place).

local CONFIG = {
	target = nil, -- Instance to render: Model, BasePart, Tool, Accessory, Folder... (nil = just install shared.SkyRender)
	name = "render", -- label for the result; reuse a name to replace an earlier result

	-- Camera, described relative to the item as it currently sits in the world.
	viewDir = Vector3.new(-1, 0.6, -1), -- from the item TOWARD the camera
	up = Vector3.yAxis, -- which way is "up" in the picture
	fov = 20, -- narrow = flat, icon-like; 50-70 = dramatic perspective
	size = 512, -- output is size x size pixels (limited by the viewport's shorter side)
	padding = 0.08, -- empty margin around the item, as a fraction of the image

	-- Where the shot is staged.
	lookStraightUp = false, -- true: rotate the copy so the camera points at +Y (see SKILL.md, lighting caveat)
	altitude = nil, -- force a world Y for the staging spot; nil = find clear sky automatically
	clearance = 400, -- studs of empty space required around the staging spot
	backdrop = "neon", -- how the flat backdrop is made: "neon" (Neon plane, bloom zeroed) or "fog" (plane hidden in fog)

	-- Look.
	lighting = "studio", -- "studio": temporary sun over the camera's left shoulder + raised ambient; "world": the place's own lighting
	particles = false, -- true: keep particles/beams/trails (frozen while shooting); false: switch them off on the copy
	refit = true, -- take a quick test shot and re-frame so the visible pixels fill the image
	keepLook = true, -- colour comes from a shot with the place's own bloom/colour correction on
	bleed = 4, -- pixels of colour bleed into transparent areas (stops dark halos when scaled); 0 = off
	settle = 0.6, -- seconds to let lighting/textures settle after staging
}

--------------------------------------------------------------------------------

local Lighting = game:GetService("Lighting")
local RunService = game:GetService("RunService")
local AssetService = game:GetService("AssetService")
local CaptureService = game:GetService("CaptureService")
local StarterGui = game:GetService("StarterGui")
local Selection = game:GetService("Selection")
local CoreGui = game:GetService("CoreGui")

local STORE = "SkyRenderResults"
local BOARD = "__SkyRenderBoard"
local lastStage = Vector3.new(0, 6000, 0)

local notes = {}
local function note(s)
	table.insert(notes, s)
end

local undo = {}
local function onCleanup(fn)
	table.insert(undo, fn)
end
local function setProp(inst, prop, value)
	local old = inst[prop]
	inst[prop] = value
	onCleanup(function()
		inst[prop] = old
	end)
end
local function unparent(inst)
	local parent = inst.Parent
	inst.Parent = nil
	onCleanup(function()
		inst.Parent = parent
	end)
end

local function frames(n)
	for _ = 1, n do
		RunService.PreRender:Wait()
		RunService.Heartbeat:Wait()
	end
end

local function screenshot(rectMin, rectSize)
	local uri
	CaptureService:CaptureScreenshot(function(u)
		uri = u
	end)
	local t0 = os.clock()
	while not uri do
		if os.clock() - t0 > 10 then
			error("CaptureScreenshot timed out (is the Studio viewport visible?)", 0)
		end
		task.wait()
	end
	local img = AssetService:CreateEditableImageAsync(Content.fromUri(uri))
	local buf = img:ReadPixelsBuffer(rectMin, rectSize)
	img:Destroy()
	return buf
end

local function main()
	assert(RunService:IsEdit(), "Run this in Edit mode (stop the playtest first).")
	local target = CONFIG.target
	assert(typeof(target) == "Instance", "CONFIG.target is not an Instance - fix the path.")
	if settings().Rendering.GraphicsMode == Enum.GraphicsMode.OpenGL then
		error("Graphics Mode = OpenGL breaks viewport screenshots; switch Studio to another mode.", 0)
	end

	local camera = workspace.CurrentCamera

	-- 1. Work on a copy so the real item never moves.
	local holder = Instance.new("Model")
	holder.Name = "__SkyRenderStage"
	holder.Archivable = false
	onCleanup(function()
		holder:Destroy()
	end)

	local wasArchivable = target.Archivable
	target.Archivable = true
	local copy = target:Clone()
	target.Archivable = wasArchivable
	assert(copy, "Could not clone the target.")
	copy.Parent = holder

	local points, visibleParts = {}, 0
	local effects = {}
	for _, d in holder:GetDescendants() do
		if d:IsA("ParticleEmitter") or d:IsA("Fire") or d:IsA("Smoke") or d:IsA("Sparkles") or d:IsA("Beam") or d:IsA("Trail") then
			if CONFIG.particles then
				table.insert(effects, d)
			else
				d.Enabled = false
			end
		end
		if d:IsA("BasePart") then
			d.Anchored = true
			if d.Transparency < 1 then
				visibleParts += 1
				local cf, s = d.CFrame, d.Size / 2
				for x = -1, 1, 2 do
					for y = -1, 1, 2 do
						for z = -1, 1, 2 do
							table.insert(points, cf * Vector3.new(s.X * x, s.Y * y, s.Z * z))
						end
					end
				end
			end
		elseif d:IsA("LuaSourceContainer") then
			d:Destroy()
		end
	end
	assert(visibleParts > 0, "The target has no visible parts to render.")

	-- 2. Frame it: build the camera around the item where it sits, fit distance to the pixels wanted.
	local lo, hi = points[1], points[1]
	for _, p in points do
		lo, hi = lo:Min(p), hi:Max(p)
	end
	local center = (lo + hi) / 2
	local radius = math.max((hi - lo).Magnitude / 2, 0.05)

	local viewport = camera.ViewportSize
	local fullW, fullH -- real screenshot size; differs from ViewportSize when the OS display is scaled
	do
		local uri
		CaptureService:CaptureScreenshot(function(u)
			uri = u
		end)
		while not uri do
			task.wait()
		end
		local img = AssetService:CreateEditableImageAsync(Content.fromUri(uri))
		fullW, fullH = img.Size.X, img.Size.Y
		img:Destroy()
	end
	local osScale = fullW / viewport.X
	local side = math.min(CONFIG.size, math.floor(math.min(fullW, fullH)) - 2) -- output pixels
	if side < CONFIG.size then
		note(`viewport is only {fullW}x{fullH}px, so output is {side}px instead of {CONFIG.size}px (enlarge the Studio viewport for more)`)
	end

	local back = CONFIG.viewDir.Unit
	local right = CONFIG.up:Cross(back)
	if right.Magnitude < 1e-3 then
		right = Vector3.xAxis:Cross(back)
		if right.Magnitude < 1e-3 then
			right = Vector3.zAxis:Cross(back)
		end
	end
	right = right.Unit
	local upv = back:Cross(right).Unit

	local fovRad = math.rad(CONFIG.fov)
	local focal = (fullH / 2) / math.tan(fovRad / 2) -- pixels per unit of (x / depth)
	local wantHalf = side * (1 - 2 * CONFIG.padding) / 2

	local dist = radius / math.sin(fovRad / 2) + 0.5
	local aim = center
	local camCF, nearDepth, farDepth
	for _ = 1, 8 do
		camCF = CFrame.fromMatrix(aim + back * dist, right, upv, back)
		local minX, maxX, minY, maxY = math.huge, -math.huge, math.huge, -math.huge
		nearDepth, farDepth = math.huge, 0
		for _, p in points do
			local l = camCF:PointToObjectSpace(p)
			local depth = math.max(-l.Z, 0.01)
			local sx, sy = l.X / depth * focal, l.Y / depth * focal
			minX, maxX = math.min(minX, sx), math.max(maxX, sx)
			minY, maxY = math.min(minY, sy), math.max(maxY, sy)
			nearDepth, farDepth = math.min(nearDepth, depth), math.max(farDepth, depth)
		end
		local half = math.max(maxX - minX, maxY - minY) / 2
		local midX, midY = (minX + maxX) / 2, (minY + maxY) / 2
		aim += (right * midX + upv * midY) * (dist / focal)
		dist = math.max(dist * half / wantHalf, radius * 1.05)
	end
	camCF = CFrame.fromMatrix(aim + back * dist, right, upv, back)
	farDepth = dist + radius
	if nearDepth < 0.3 then
		note("camera is very close to the item; raise fov or padding if the near side looks clipped")
	end

	-- 3. Pick a staging spot in open sky: nothing nearby, nothing between it and the sun.
	local sunDir = Lighting:GetSunDirection()
	if sunDir.Y < 0 then
		sunDir = -sunDir -- at night the moon is the light
	end
	local clearRadius = math.max(CONFIG.clearance, dist + radius * 4 + 100)
	local overlap = OverlapParams.new()
	overlap.FilterDescendantsInstances = { holder }
	local rayParams = RaycastParams.new()
	rayParams.FilterDescendantsInstances = { holder }

	local function blockers(pos)
		local near = workspace:GetPartBoundsInRadius(pos, clearRadius, overlap)
		if #near > 0 then
			return `{#near} part(s) within {math.floor(clearRadius)} studs, e.g. {near[1]:GetFullName()}`
		end
		for _, dir in { sunDir, Vector3.yAxis, -Vector3.yAxis } do
			if dir == sunDir and CONFIG.lighting == "studio" then
				continue -- the sun gets moved; its line of sight is checked after that
			end
			local hit = workspace:Raycast(pos, dir * 4000, rayParams)
			-- straight down is allowed to hit ground, but only if it is far away
			if hit and not (dir.Y < 0 and hit.Distance > clearRadius) then
				return `{hit.Instance:GetFullName()} is {math.floor(hit.Distance)} studs away toward {dir.Y < 0 and "the ground" or (dir == sunDir and "the sun" or "straight up")}`
			end
		end
		return nil
	end

	local stagePos
	if CONFIG.altitude then
		stagePos = Vector3.new(center.X, CONFIG.altitude, center.Z)
		local why = blockers(stagePos)
		if why then
			note("forced altitude is NOT clear: " .. why)
		end
	else
		local y = math.max(center.Y, 0) + 1500
		for attempt = 1, 12 do
			stagePos = Vector3.new(center.X, y, center.Z)
			local why = blockers(stagePos)
			if not why then
				break
			end
			if attempt == 12 then
				error("Could not find clear sky up to Y=" .. math.floor(y) .. ": " .. why .. ". Set CONFIG.altitude yourself.", 0)
			end
			y += 1500
		end
	end

	-- 4. Move the copy so the same framing happens at the staging spot.
	local skyCam
	if CONFIG.lookStraightUp then
		skyCam = CFrame.fromMatrix(stagePos - Vector3.yAxis * dist, Vector3.xAxis, Vector3.zAxis, -Vector3.yAxis)
	else
		skyCam = camCF.Rotation + (stagePos + back * dist)
	end
	holder.Parent = workspace
	holder:PivotTo(skyCam * camCF:Inverse() * holder:GetPivot())
	lastStage = stagePos

	-- Lighting. The sun (or moon) is the only directional light and it is always above the horizon,
	-- so "studio" picks the time of day that best puts it over the camera's left shoulder.
	local lightReport = "world lighting"
	if CONFIG.lighting == "studio" then
		local want = skyCam:VectorToWorldSpace(Vector3.new(-0.5, 0.7, 0.6).Unit)
		setProp(Lighting, "GeographicLatitude", Lighting.GeographicLatitude)
		setProp(Lighting, "ClockTime", Lighting.ClockTime)
		local best, bestLat, bestTime = -2, Lighting.GeographicLatitude, Lighting.ClockTime
		for lat = -90, 90, 7.5 do
			Lighting.GeographicLatitude = lat
			for t = 0, 23.75, 0.25 do
				Lighting.ClockTime = t
				local s = Lighting:GetSunDirection()
				if s.Y > 0.25 then
					local score = s:Dot(want)
					if score > best then
						best, bestLat, bestTime = score, lat, t
					end
				end
			end
		end
		Lighting.GeographicLatitude = bestLat
		Lighting.ClockTime = bestTime
		setProp(Lighting, "Brightness", 3)
		setProp(Lighting, "OutdoorAmbient", Color3.fromRGB(150, 150, 150))
		sunDir = Lighting:GetSunDirection()
		lightReport = `studio lighting, key light alignment {string.format("%.2f", best)} (1 = ideal)`
		if best < 0.6 then
			note(`the sun cannot get behind this camera (alignment {string.format("%.2f", best)}), so the visible side is lit mostly by ambient light and will look flat`)
		end
		local hit = workspace:Raycast(stagePos, sunDir * 4000, rayParams)
		if hit then
			note(`{hit.Instance:GetFullName()} sits between the item and the sun and may shadow it`)
		end
	else
		local facing = sunDir:Dot(skyCam:VectorToWorldSpace(Vector3.zAxis))
		lightReport = `world lighting, sun is {facing > 0.2 and "in front of" or (facing < -0.2 and "BEHIND" or "beside")} the visible side`
	end

	-- 5. Take over the viewport.
	local prevCF, prevFocus = camera.CFrame, camera.Focus
	setProp(camera, "CameraType", Enum.CameraType.Scriptable)
	setProp(camera, "FieldOfView", CONFIG.fov)
	onCleanup(function()
		camera.CFrame = prevCF
		camera.Focus = prevFocus
	end)

	local prevSelection = Selection:Get()
	Selection:Set({})
	onCleanup(function()
		Selection:Set(prevSelection)
	end)
	setProp(StarterGui, "ShowDevelopmentGui", false)
	pcall(function()
		setProp(settings().Studio, "Show Hover Over", false)
	end)
	-- Things that would put haze, glare or blur between the camera and the backdrop.
	for _, c in Lighting:GetChildren() do
		if c:IsA("Atmosphere") then
			unparent(c)
		elseif c:IsA("SunRaysEffect") or c:IsA("DepthOfFieldEffect") or c:IsA("BlurEffect") then
			if c.Enabled then
				setProp(c, "Enabled", false)
			end
		end
	end
	for _, c in workspace.Terrain:GetChildren() do
		if c:IsA("Clouds") then
			unparent(c)
		end
	end

	-- 6. Backdrop: a plane just behind the item that renders as one exact flat colour, no shading.
	-- "neon": a Neon part ignores lighting and shadows. Neon also GLOWS, and that glow spills over
	--   thin parts of the item and makes them read as see-through. Disabling BloomEffects does not
	--   stop it (the engine falls back to a default glow); an enabled BloomEffect with Intensity 0
	--   and Size 0 does. That zeroed bloom is added below for the measuring shots.
	-- "fog": a plain plane sitting inside solid fog of its own colour. Only exact under the Retro
	--   tonemapper, and needs the Atmosphere removed (fog is ignored while one exists).
	local plane = Instance.new("Part")
	plane.Name = "__SkyRenderBackdrop"
	plane.Archivable = false
	plane.Anchored = true
	plane.CanCollide, plane.CanTouch, plane.CanQuery = false, false, false
	plane.CastShadow = false
	plane.Locked = true
	local neon = CONFIG.backdrop == "neon"
	plane.Material = neon and Enum.Material.Neon or Enum.Material.SmoothPlastic
	plane.Size = Vector3.one
	local mesh = Instance.new("SpecialMesh")
	mesh.MeshType = Enum.MeshType.Brick
	local span = (dist * 3 + radius * 8 + 200) * math.tan(fovRad / 2) * (fullW / fullH) * 6 + 50
	mesh.Scale = Vector3.new(span, span, 0)
	mesh.Parent = plane
	plane.Parent = workspace
	onCleanup(function()
		plane:Destroy()
	end)

	setProp(Lighting, "FogStart", Lighting.FogStart)
	setProp(Lighting, "FogEnd", Lighting.FogEnd)
	setProp(Lighting, "FogColor", Lighting.FogColor)
	-- Camera, backdrop and fog move together: fog switches on between the item's far side and the plane.
	local camShift = Vector3.zero
	local function placeCamera()
		local cf = skyCam * CFrame.new(camShift)
		camera.CFrame = cf
		camera.Focus = cf * CFrame.new(0, 0, -dist)
		farDepth = dist + radius
		local planeDepth = farDepth + math.max(60, radius * 3)
		plane.CFrame = cf * CFrame.new(0, 0, -planeDepth)
		local fogAt = neon and 1e6 or (farDepth + planeDepth) / 2
		Lighting.FogStart = fogAt
		Lighting.FogEnd = fogAt
	end
	placeCamera()
	local function backdrop(c)
		plane.Color = c
		Lighting.FogColor = c
	end

	local rectSize = Vector2.new(side, side)
	local rectMin = Vector2.new(math.floor((fullW - side) / 2), math.floor((fullH - side) / 2))

	-- 7. Shots.
	backdrop(Color3.new(0, 0, 0))
	task.wait(CONFIG.settle)
	-- Anything that animates must hold still, or the white and black shots will not line up.
	for _, e in effects do
		if e:IsA("Beam") then
			e.TextureSpeed = 0
		elseif not e:IsA("Trail") then
			e.TimeScale = 0
		end
	end


	if CONFIG.refit then
		frames(3)
		local b = screenshot(rectMin, rectSize)
		backdrop(Color3.new(1, 1, 1))
		frames(3)
		local w = screenshot(rectMin, rectSize)
		backdrop(Color3.new(0, 0, 0))
		-- The top-left pixel is background: anything that changes clearly less than it does is item.
		local cut = {}
		for k = 0, 2 do
			cut[k] = (buffer.readu8(w, k) - buffer.readu8(b, k)) * 0.9
		end
		local x0, x1, y0, y1 = side, -1, side, -1
		for i = 0, side * side - 1 do
			local j = i * 4
			if
				buffer.readu8(w, j) - buffer.readu8(b, j) < cut[0]
				or buffer.readu8(w, j + 1) - buffer.readu8(b, j + 1) < cut[1]
				or buffer.readu8(w, j + 2) - buffer.readu8(b, j + 2) < cut[2]
			then
				local px, py = i % side, i // side
				if px < x0 then x0 = px end
				if px > x1 then x1 = px end
				if py < y0 then y0 = py end
				if py > y1 then y1 = py end
			end
		end
		if x1 >= 0 then
			local perPixel = dist / focal
			local offX = (x0 + x1) / 2 - (side - 1) / 2
			local offY = (y0 + y1) / 2 - (side - 1) / 2
			local newDist = math.max(dist * (math.max(x1 - x0, y1 - y0) + 1) / 2 / wantHalf, dist * 0.3)
			camShift += Vector3.new(offX * perPixel, -offY * perPixel, newDist - dist)
			dist = newDist
			placeCamera()
		end
	end

	frames(3)
	local lookBuf = CONFIG.keepLook and screenshot(rectMin, rectSize) or nil

	-- Neutral, linear pair for measuring transparency.
	for _, c in Lighting:GetChildren() do
		if c:IsA("PostEffect") and c.Enabled then
			setProp(c, "Enabled", false)
		elseif c.ClassName == "ColorGradingEffect" then
			unparent(c)
		end
	end
	setProp(Lighting, "ExposureCompensation", 0)
	-- With no enabled BloomEffect the engine falls back to its default glow, so add one forced to zero
	-- (measured on a thin bar in front of white Neon: 0 solid pixels without this, all solid with it).
	local noBloom = Instance.new("BloomEffect")
	noBloom.Name = "__SkyRenderNoBloom"
	noBloom.Intensity = 0
	noBloom.Size = 0
	noBloom.Threshold = 4
	noBloom.Parent = Lighting
	onCleanup(function()
		noBloom:Destroy()
	end)
	local retroOk = pcall(function()
		local grading = Instance.new("ColorGradingEffect")
		grading.Name = "__SkyRenderRetro"
		grading.TonemapperPreset = Enum.TonemapperPreset.Retro
		grading.Parent = Lighting
		onCleanup(function()
			grading:Destroy()
		end)
	end)
	if not retroOk then
		note("ColorGradingEffect unavailable; soft edges and glass may be slightly off")
	end

	frames(3)
	local blackBuf = screenshot(rectMin, rectSize)
	backdrop(Color3.new(1, 1, 1))
	frames(3)
	local whiteBuf = screenshot(rectMin, rectSize)
	if not lookBuf then
		lookBuf = blackBuf
	end

	-- 8. Composite. The four corners are known background, so calibrate against them.
	local n = side * side
	local function cornerAvg(buf)
		local sum = { 0, 0, 0 }
		for _, idx in { 0, side - 1, n - side, n - 1 } do
			for k = 0, 2 do
				sum[k + 1] += buffer.readu8(buf, idx * 4 + k) / 4
			end
		end
		return sum
	end
	local bgW, bgB, bgL = cornerAvg(whiteBuf), cornerAvg(blackBuf), cornerAvg(lookBuf)
	local span3 = {}
	for k = 1, 3 do
		span3[k] = bgW[k] - bgB[k]
	end
	if math.min(span3[1], span3[2], span3[3]) < 200 then
		note(`backdrop did not come out flat (white={math.floor(bgW[1])},{math.floor(bgW[2])},{math.floor(bgW[3])} black={math.floor(bgB[1])},{math.floor(bgB[2])},{math.floor(bgB[3])}); the item may be touching the corners, or a lighting effect is tinting the backdrop`)
	end

	local out = buffer.create(n * 4)
	local opaque, partial = 0, 0
	local minPX, maxPX, minPY, maxPY = side, -1, side, -1
	for i = 0, n - 1 do
		local j = i * 4
		local a = 0
		for k = 0, 2 do
			local ak = 1 - (buffer.readu8(whiteBuf, j + k) - buffer.readu8(blackBuf, j + k)) / span3[k + 1]
			if ak > a then
				a = ak
			end
		end
		if a > 0.985 then
			a = 1
		end
		if a >= 0.012 then
			for k = 0, 2 do
				local c = (buffer.readu8(lookBuf, j + k) - (1 - a) * bgL[k + 1]) / a
				buffer.writeu8(out, j + k, math.clamp(math.floor(c + 0.5), 0, 255))
			end
			buffer.writeu8(out, j + 3, math.floor(a * 255 + 0.5))
			if a == 1 then
				opaque += 1
			else
				partial += 1
			end
			local px, py = i % side, i // side
			if px < minPX then minPX = px end
			if px > maxPX then maxPX = px end
			if py < minPY then minPY = py end
			if py > maxPY then maxPY = py end
		end
		if i % 60000 == 59999 then
			task.wait()
		end
	end

	-- Colour bleed: copy edge colours outward into fully transparent pixels (alpha stays 0).
	if CONFIG.bleed > 0 then
		local filled = buffer.create(n)
		for i = 0, n - 1 do
			if buffer.readu8(out, i * 4 + 3) > 0 then
				buffer.writeu8(filled, i, 1)
			end
		end
		for pass = 1, CONFIG.bleed do
			local mark = pass + 1
			for y = 0, side - 1 do
				for x = 0, side - 1 do
					local i = y * side + x
					if buffer.readu8(filled, i) == 0 then
						local src
						if x > 0 and buffer.readu8(filled, i - 1) ~= 0 and buffer.readu8(filled, i - 1) <= pass then
							src = i - 1
						elseif x < side - 1 and buffer.readu8(filled, i + 1) ~= 0 and buffer.readu8(filled, i + 1) <= pass then
							src = i + 1
						elseif y > 0 and buffer.readu8(filled, i - side) ~= 0 and buffer.readu8(filled, i - side) <= pass then
							src = i - side
						elseif y < side - 1 and buffer.readu8(filled, i + side) ~= 0 and buffer.readu8(filled, i + side) <= pass then
							src = i + side
						end
						if src then
							buffer.writeu8(out, i * 4, buffer.readu8(out, src * 4))
							buffer.writeu8(out, i * 4 + 1, buffer.readu8(out, src * 4 + 1))
							buffer.writeu8(out, i * 4 + 2, buffer.readu8(out, src * 4 + 2))
							buffer.writeu8(filled, i, mark)
						end
					end
				end
			end
			task.wait()
		end
	end

	local result = AssetService:CreateEditableImage({ Size = rectSize })
	result:WritePixelsBuffer(Vector2.zero, rectSize, out)

	-- 9. Keep the result alive in a hidden store (an EditableImage only lives while something holds it).
	local store = CoreGui:FindFirstChild(STORE)
	if not store then
		store = Instance.new("ScreenGui")
		store.Name = STORE
		store.Archivable = false
		store.Enabled = false
		store.Parent = CoreGui
	end
	local old = store:FindFirstChild(CONFIG.name)
	if old then
		old:Destroy()
	end
	local label = Instance.new("ImageLabel")
	label.Name = CONFIG.name
	label.Size = UDim2.fromOffset(side, side)
	label.BackgroundTransparency = 1
	label.ImageContent = Content.fromObject(result)
	label.Parent = store

	local edge = (minPX <= 0 or minPY <= 0 or maxPX >= side - 1 or maxPY >= side - 1)
	if maxPX < 0 then
		note("RESULT IS EMPTY: nothing differed between the white and black shots")
	elseif edge then
		note("the item touches the image edge (clipped) - increase padding, or particles/attachments extend past the parts")
	end
	if opaque + partial > 0 and partial / (opaque + partial) > 0.5 then
		note("more than half of the item is semi-transparent; expected for glass, otherwise check for haze")
	end

	return table.concat({
		`OK {side}x{side}px "{CONFIG.name}" -> CoreGui.{STORE}.{CONFIG.name}`,
		`item radius {string.format("%.2f", radius)} studs, camera {string.format("%.1f", dist)} studs away, staged at Y={math.floor(stagePos.Y)}{CONFIG.lookStraightUp and " looking straight up" or ""}`,
		lightReport,
		`coverage: {string.format("%.1f", opaque / n * 100)}% opaque, {string.format("%.1f", partial / n * 100)}% semi-transparent, bounds x {minPX}-{maxPX} y {minPY}-{maxPY}`,
		`backdrop ({CONFIG.backdrop}) calibration white={math.floor(bgW[1])},{math.floor(bgW[2])},{math.floor(bgW[3])} black={math.floor(bgB[1])},{math.floor(bgB[2])},{math.floor(bgB[3])} osScale={osScale}`,
	}, "\n")
end

local DEFAULTS = table.clone(CONFIG)
local busy = false

-- render(overrides) -> report string. Never throws; always restores the place.
local function render(overrides)
	if busy then
		return "FAILED: a render is already running"
	end
	busy = true
	table.clear(CONFIG)
	for k, v in DEFAULTS do
		CONFIG[k] = v
	end
	for k, v in overrides or {} do
		CONFIG[k] = v
	end
	table.clear(notes)
	table.clear(undo)

	-- Wall-clock time (not os.clock, which ignores the frame waits this render depends on).
	local started = time()
	local ok, result = xpcall(main, function(e)
		return tostring(e) .. "\n" .. debug.traceback()
	end)
	for i = #undo, 1, -1 do
		pcall(undo[i])
	end
	busy = false

	local text = (ok and result or ("FAILED: " .. tostring(result)))
	text ..= string.format("\ntime %.2fs (wall clock: staging, shots, composite and restore)", time() - started)
	if #notes > 0 then
		text ..= "\nNOTES:\n- " .. table.concat(notes, "\n- ")
	end
	return text
end

-- board(names) puts results on a temporary board in the sky, each one over magenta and over dark grey,
-- and returns the camera_position / look_at_position to give screen_capture. (screen_capture does not
-- draw GUIs, so the images are shown as decals on parts.) board(nil) removes it.
local function board(names)
	local old = workspace:FindFirstChild(BOARD)
	if old then
		old:Destroy()
	end
	if names == nil then
		return "board removed"
	end
	local store = CoreGui:FindFirstChild(STORE)
	if not store then
		return "FAILED: there are no renders yet"
	end
	if #names == 0 then
		for _, c in store:GetChildren() do
			table.insert(names, c.Name)
		end
	end
	local cols = math.max(1, math.ceil(math.sqrt(#names / 2)))
	local rows = math.ceil(#names / cols)
	local cell = 20
	local origin = CFrame.new(lastStage + Vector3.new(0, 600, 0))

	local model = Instance.new("Model")
	model.Name = BOARD
	model.Archivable = false
	local layout = {}
	for i, name in names do
		local label = store:FindFirstChild(name)
		local col, row = (i - 1) % cols, (i - 1) // cols
		-- the camera looks along +Z, so its left is +X
		local cx = ((cols - 1) / 2 - col) * cell * 2
		local cy = ((rows - 1) / 2 - row) * cell
		for half, bg in { Color3.fromRGB(255, 0, 255), Color3.fromRGB(24, 24, 24) } do
			local p = Instance.new("Part")
			p.Anchored = true
			p.CanCollide, p.CanTouch, p.CanQuery = false, false, false
			p.CastShadow = false
			p.Material = Enum.Material.SmoothPlastic -- not Neon: Neon glows over the image
			p.Color = bg
			p.Size = Vector3.new(cell, cell, 0.2)
			p.CFrame = origin * CFrame.new(cx + (half == 1 and cell / 2 or -cell / 2), cy, 0)
			if label then
				local d = Instance.new("Decal")
				d.Face = Enum.NormalId.Front
				d.TextureContent = label.ImageContent
				d.Parent = p
			end
			p.Parent = model
		end
		table.insert(layout, `row {row + 1} col {col + 1}: {name}{label and "" or " (MISSING)"}`)
	end
	model.Parent = workspace

	local cam = workspace.CurrentCamera
	local vp = cam.ViewportSize
	local t = math.tan(math.rad(cam.FieldOfView) / 2)
	local w, h = cols * cell * 2, rows * cell
	local d = math.max(h / 2 / t, w / 2 / (t * vp.X / vp.Y)) * 1.06
	local c, o = origin.Position - Vector3.zAxis * d, origin.Position
	return string.format(
		"board up. screen_capture with camera_position=[%.1f, %.1f, %.1f] look_at_position=[%.1f, %.1f, %.1f]\n%s",
		c.X, c.Y, c.Z, o.X, o.Y, o.Z, table.concat(layout, "\n")
	)
end

-- clear() removes the board and every stored result.
local function clear()
	board(nil)
	local store = CoreGui:FindFirstChild(STORE)
	if store then
		store:Destroy()
	end
	return "cleared"
end

-- Later execute_luau calls in the same Studio session can skip the paste:
--   return shared.SkyRender({ target = workspace.Sword, name = "sword" })
shared.SkyRender = render
shared.SkyRenderBoard = board
shared.SkyRenderClear = clear
-- Bump this whenever this file changes, and the matching number in SKILL.md, so a Studio session
-- still holding an older copy gets re-pasted instead of reused.
shared.SkyRenderVersion = 1

if typeof(CONFIG.target) ~= "Instance" then
	return "SkyRender installed: shared.SkyRender(config), shared.SkyRenderBoard(names), shared.SkyRenderClear()"
end
return render({})

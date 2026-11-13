-- No-HTTP PNG export for roblox-sky-render.
-- Paste this whole file into execute_luau (Edit datamodel) once per Studio session. It installs:
--   shared.SkyExportPrepare(names)  -> short manifest (names = {} for every stored render)
--   shared.SkyExportPart(name, part) -> one fixed-size text piece; call once per part
--   shared.SkyExportClear()          -> frees the prepared data
--
-- How it travels: each piece is exactly PIECE characters, which is too big for Claude Code to show,
-- so Claude Code saves it to a file under tool-results/. scripts/assemble_png.py finds those files
-- and rebuilds the PNGs. Nothing is ever copied by hand, and no HTTP permission is needed.
--
-- Encoding (assemble_png.py undoes it in reverse):
--   1. "Sub" filter: each byte minus the same channel of the pixel to its left (smooth shading -> ~0)
--   2. LZW with growing codes (9..16 bits). 256 = clear, 257 = end, dictionary resets when full
--   3. bits packed LSB-first into 7-bit characters (all 128 ASCII codes survive execute_luau intact)
-- Checks: CRC-32 of the raw RGBA pixels, and of each piece's payload.

local HttpService = game:GetService("HttpService")
local CoreGui = game:GetService("CoreGui")

local PIECE = 99900 -- characters per returned piece; execute_luau results are cut at 100,000
local HEADER_ROOM = 300 -- the header line always fits in this
local MAGIC = "SKYB128 1"
local CLEAR, STOP, FIRST, LIMIT = 256, 257, 258, 65536

local crcTable = {}
for i = 0, 255 do
	local c = i
	for _ = 1, 8 do
		if bit32.band(c, 1) == 1 then
			c = bit32.bxor(0xEDB88320, bit32.rshift(c, 1))
		else
			c = bit32.rshift(c, 1)
		end
	end
	crcTable[i] = c
end

local function crc32(buf)
	local crc = 0xFFFFFFFF
	for i = 0, buffer.len(buf) - 1 do
		crc = bit32.bxor(crcTable[bit32.band(bit32.bxor(crc, buffer.readu8(buf, i)), 0xFF)], bit32.rshift(crc, 8))
		if i % 262144 == 262143 then
			task.wait()
		end
	end
	return bit32.bxor(crc, 0xFFFFFFFF)
end

local function subFilter(px, width)
	local n = buffer.len(px)
	local out = buffer.create(n)
	local row = width * 4
	for i = 0, n - 1 do
		local v = buffer.readu8(px, i)
		if i % row >= 4 then
			v = (v - buffer.readu8(px, i - 4)) % 256
		end
		buffer.writeu8(out, i, v)
		if i % 262144 == 262143 then
			task.wait()
		end
	end
	return out
end

-- LZW-compress `data` and pack the codes into 7-bit characters. Returns the string.
local function lzw7(data)
	local n = buffer.len(data)
	local out = buffer.create(math.ceil((n + 4) * 16 / 7) + 4) -- worst case: every byte its own code
	local pos, acc, nacc = 0, 0, 0
	local width, nextCode = 9, FIRST
	local dict = {}

	local function put(code)
		acc += code * 2 ^ nacc
		nacc += width
		while nacc >= 7 do
			buffer.writeu8(out, pos, acc % 128)
			pos += 1
			acc //= 128
			nacc -= 7
		end
	end

	-- Write one data code, then do the dictionary bookkeeping the decoder mirrors exactly.
	-- Returns true if the dictionary was full and got reset.
	local function emit(code)
		put(code)
		if nextCode < LIMIT then
			nextCode += 1
		end
		if nextCode == 2 ^ width and width < 16 then
			width += 1
		end
		if nextCode == LIMIT then
			put(CLEAR)
			table.clear(dict)
			nextCode, width = FIRST, 9
			return true
		end
		return false
	end

	if n > 0 then
		local prefix = buffer.readu8(data, 0)
		for i = 1, n - 1 do
			local c = buffer.readu8(data, i)
			local key = prefix * 256 + c
			local code = dict[key]
			if code then
				prefix = code
			else
				local slot = nextCode
				if not emit(prefix) then
					dict[key] = slot
				end
				prefix = c
			end
			if i % 262144 == 0 then
				task.wait()
			end
		end
		emit(prefix)
	end
	put(STOP)
	if nacc > 0 then
		buffer.writeu8(out, pos, acc % 128)
		pos += 1
	end
	return buffer.readstring(out, 0, pos)
end

local prepared = {}
local run = nil

local function prepare(names)
	local store = CoreGui:FindFirstChild("SkyRenderResults")
	if not store then
		return "FAILED: no renders found (CoreGui.SkyRenderResults is missing)"
	end
	names = names or {}
	if #names == 0 then
		for _, c in store:GetChildren() do
			table.insert(names, c.Name)
		end
	end
	table.clear(prepared)
	run = string.lower(string.sub(HttpService:GenerateGUID(false), 1, 8))
	local lines = { `run={run}` }
	local room = PIECE - HEADER_ROOM
	local totalParts = 0
	for _, name in names do
		local label = store:FindFirstChild(name)
		local img = label and label.ImageContent.Object
		if not img then
			table.insert(lines, `{name}: not found`)
			continue
		end
		if #name > 150 or string.find(name, "[\r\n]") then
			table.insert(lines, `{name}: name too long or has a line break; rename the result first`)
			continue
		end
		local size = img.Size
		local px = img:ReadPixelsBuffer(Vector2.zero, size)
		local chars = lzw7(subFilter(px, size.X))
		local parts = math.max(1, math.ceil(#chars / room))
		prepared[name] = { w = size.X, h = size.Y, crc = crc32(px), chars = chars, parts = parts }
		totalParts += parts
		table.insert(lines, `{name}: {size.X}x{size.Y}, {buffer.len(px)} bytes -> {#chars} chars, {parts} part(s)`)
		task.wait()
	end
	table.insert(lines, `{totalParts} part(s) in total. Next, one execute_luau call per part:`)
	table.insert(lines, `return shared.SkyExportPart("<name>", <part>)`)
	return table.concat(lines, "\n")
end

local function filler(len, seed)
	-- Printable noise after the payload, so every piece is the same large size and always gets saved
	-- to a file. The assembler ignores it (plen in the header says where the payload ends).
	local t = table.create(len)
	local x = seed % 2147483646 + 1
	for i = 1, len do
		x = (x * 48271) % 2147483647
		t[i] = string.char(0x21 + x % 94)
	end
	return table.concat(t)
end

local function part(name, i)
	local p = prepared[name]
	if not p then
		return `FAILED: "{name}" is not prepared; call shared.SkyExportPrepare first`
	end
	if type(i) ~= "number" or i < 1 or i > p.parts or i % 1 ~= 0 then
		return `FAILED: part must be a whole number from 1 to {p.parts}`
	end
	local per = math.ceil(#p.chars / p.parts)
	local payload = string.sub(p.chars, (i - 1) * per + 1, math.min(i * per, #p.chars))
	local header = string.format(
		"%s run=%s part=%d of=%d w=%d h=%d crc=%08x plen=%d pcrc=%08x name=%s\n",
		MAGIC, run, i, p.parts, p.w, p.h, p.crc, #payload, crc32(buffer.fromstring(payload)), name
	)
	return header .. payload .. filler(PIECE - #header - #payload, i * 7919 + #payload)
end

shared.SkyExportPrepare = prepare
shared.SkyExportPart = part
shared.SkyExportClear = function()
	table.clear(prepared)
	return "cleared"
end
-- Bump this whenever this file changes, and the matching number in SKILL.md.
shared.SkyExportVersion = 1

return "SkyExport installed: shared.SkyExportPrepare(names), shared.SkyExportPart(name, part), shared.SkyExportClear()"

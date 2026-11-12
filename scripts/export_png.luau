-- Send finished renders from CoreGui.SkyRenderResults to png_receiver.py, which writes PNG files.
-- Start the receiver first:  python png_receiver.py <output_dir> 8765
-- Needs 127.0.0.1:8765 in Studio's Assistant Settings > MCP Permissions > HTTP domain allow list.
local NAMES = { "render" } -- result names to export; {} = every result
local PORT = 8765

local HttpService = game:GetService("HttpService")
local EncodingService = game:GetService("EncodingService")
local preview = game:GetService("CoreGui"):FindFirstChild("SkyRenderResults")
if not preview then
	return "FAILED: no renders found (CoreGui.SkyRenderResults is missing)"
end
if #NAMES == 0 then
	for _, c in preview:GetChildren() do
		table.insert(NAMES, c.Name)
	end
end

local CHUNK = 256 * 1024 -- raw bytes per request, keeps each body well under HttpService's 1 MB limit
local report = {}
for _, name in NAMES do
	local label = preview:FindFirstChild(name)
	local img = label and label.ImageContent.Object
	if not img then
		table.insert(report, `{name}: not found`)
		continue
	end
	local size = img.Size
	local pixels = img:ReadPixelsBuffer(Vector2.zero, size)
	local total = buffer.len(pixels)
	local count = math.ceil(total / CHUNK)
	local last = ""
	local ok, err = pcall(function()
		for i = 0, count - 1 do
			local len = math.min(CHUNK, total - i * CHUNK)
			local part = buffer.create(len)
			buffer.copy(part, 0, pixels, i * CHUNK, len)
			local res = HttpService:RequestAsync({
				Url = `http://127.0.0.1:{PORT}/chunk?name={HttpService:UrlEncode(name)}&w={size.X}&h={size.Y}&i={i}&n={count}`,
				Method = "POST",
				Headers = { ["Content-Type"] = "text/plain" },
				Body = buffer.tostring(EncodingService:Base64Encode(part)),
			})
			assert(res.Success, `HTTP {res.StatusCode}: {res.Body}`)
			last = res.Body
		end
	end)
	table.insert(report, `{name}: {ok and last or ("FAILED " .. tostring(err))}`)
end
return table.concat(report, "\n")

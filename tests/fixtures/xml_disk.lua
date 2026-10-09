-- Engine stand-in: the GIANTS XML API (XMLFile objects and the raw handle functions) over real
-- files on disk. Paths use the engine's "root.child(i).grandchild#attr" form (no index = 0);
-- attribute values are escaped on save and unescaped on load; a file that does not parse as XML
-- (for example truncated) loads as nil, as loadXMLFile returns 0. This is no proof of the engine's
-- own writer: it is how the tests put real bytes on disk, damage them and read them back.
--
-- Fault injection: XMLDisk.onSave(filename) may error (the save throws), return false (the
-- save fails) or return "truncate" (the file is written half and the save reports success).

XMLDisk = { onSave = nil, saves = {} }

local Doc = {}
Doc.__index = Doc

local function newNode(name) return { name = name, attrs = {}, order = {}, children = {} } end

local function parsePath(path)
    local elements, attr = path:match("^([^#]*)#?(.*)$")
    local segments = {}
    for part in elements:gmatch("[^%.]+") do
        local name, index = part:match("^([%w_]+)%((%d+)%)$")
        if name == nil then name, index = part, 0 end
        segments[#segments + 1] = { name = name, index = tonumber(index) }
    end
    return segments, attr ~= "" and attr or nil
end

local function locate(doc, segments, create)
    if segments[1] == nil or segments[1].name ~= doc.root.name or segments[1].index ~= 0 then return nil end
    local node = doc.root
    for i = 2, #segments do
        local seg, seen, found = segments[i], -1, nil
        for _, child in ipairs(node.children) do
            if child.name == seg.name then
                seen = seen + 1
                if seen == seg.index then found = child break end
            end
        end
        if found == nil then
            if not create then return nil end
            while seen < seg.index do
                found = newNode(seg.name)
                node.children[#node.children + 1] = found
                seen = seen + 1
            end
        end
        node = found
    end
    return node
end

function Doc:setString(path, value)
    local segments, attr = parsePath(path)
    local node = locate(self, segments, true)
    assert(node ~= nil, "bad xml path " .. path)
    if attr == nil then node.text = tostring(value) return end
    if node.attrs[attr] == nil then node.order[#node.order + 1] = attr end
    node.attrs[attr] = tostring(value)
end
function Doc:getString(path, default)
    local segments, attr = parsePath(path)
    local node = locate(self, segments, false)
    if node == nil then return default end
    if attr == nil then return node.text or default end
    if node.attrs[attr] == nil then return default end
    return node.attrs[attr]
end
function Doc:setInt(path, v) self:setString(path, string.format("%d", v)) end
function Doc:getInt(path, d) local v = tonumber(self:getString(path)) return v ~= nil and math.floor(v) or d end
function Doc:setFloat(path, v) self:setString(path, string.format("%.17g", v)) end
function Doc:getFloat(path, d) return tonumber(self:getString(path)) or d end
function Doc:setBool(path, v) self:setString(path, v and "true" or "false") end
function Doc:getBool(path, d) local v = self:getString(path) if v == nil then return d end return v == "true" end
function Doc:hasProperty(path)
    local segments, attr = parsePath(path)
    local node = locate(self, segments, false)
    return node ~= nil and (attr == nil or node.attrs[attr] ~= nil)
end
function Doc:iterate(path, closure)
    local segments = parsePath(path)
    local last = table.remove(segments)
    local parent = locate(self, segments, false)
    if parent == nil then return end
    local i = 0
    for _, child in ipairs(parent.children) do
        if child.name == last.name then
            i = i + 1
            if closure(i, string.format("%s(%d)", path, i - 1)) == false then break end
        end
    end
end
function Doc:delete() end

local function escape(text)
    return (text:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub('"', "&quot;")
        :gsub("\n", "&#10;"):gsub("\r", "&#13;"):gsub("\t", "&#9;"))
end
local function unescape(text)
    return (text:gsub("&#(%d+);", function(n) return string.char(tonumber(n)) end)
        :gsub("&quot;", '"'):gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&amp;", "&"))
end

local function serialize(node, depth, out)
    local pad = string.rep("    ", depth)
    local attrs = {}
    for _, name in ipairs(node.order) do attrs[#attrs + 1] = string.format(' %s="%s"', name, escape(node.attrs[name])) end
    if #node.children == 0 and node.text ~= nil then
        out[#out + 1] = string.format("%s<%s%s>%s</%s>", pad, node.name, table.concat(attrs), escape(node.text), node.name)
    elseif #node.children == 0 then
        out[#out + 1] = string.format("%s<%s%s/>", pad, node.name, table.concat(attrs))
    else
        out[#out + 1] = string.format("%s<%s%s>", pad, node.name, table.concat(attrs))
        for _, child in ipairs(node.children) do serialize(child, depth + 1, out) end
        out[#out + 1] = string.format("%s</%s>", pad, node.name)
    end
end

function Doc:toText()
    local text = { '<?xml version="1.0" encoding="utf-8" standalone="no"?>' }
    serialize(self.root, 0, text)
    return table.concat(text, "\n") .. "\n"
end
--- Write bytes as a save does, through the fault injection. The engine's own writes (the career
--- file at the end of a save) use this too.
function XMLDisk.save(filename, body)
    local fault = nil
    if XMLDisk.onSave ~= nil then fault = XMLDisk.onSave(filename) end
    if fault == false then return false end
    if fault == "truncate" then body = body:sub(1, math.floor(#body / 2)) end
    local handle = io.open(filename, "wb")
    if handle == nil then return false end
    handle:write(body)
    handle:close()
    XMLDisk.saves[#XMLDisk.saves + 1] = filename
    return true
end
function Doc:save()
    -- A document created without a filename (the career document) cannot be saved by path.
    if self.filename == nil or self.filename == "" then return false end
    return XMLDisk.save(self.filename, self:toText())
end

local function parse(text, filename)
    text = text:gsub("<!%-%-.-%-%->", ""):gsub("<%?.-%?>", "")
    local stack, root = {}, nil
    local pos = 1
    while true do
        local s, e, closing, name, rest, selfClosing = text:find("<(/?)([%w_]+)([^<>]-)(/?)>", pos)
        if s == nil then break end
        if text:sub(pos, s - 1):find("[<>]") then return nil end
        pos = e + 1
        if closing == "/" then
            local top = table.remove(stack)
            if top == nil or top.name ~= name then return nil end
        else
            local node = newNode(name)
            for attr, value in rest:gmatch('([%w_:%-]+)%s*=%s*"([^"]*)"') do
                if node.attrs[attr] == nil then node.order[#node.order + 1] = attr end
                node.attrs[attr] = unescape(value)
            end
            if #stack == 0 then
                if root ~= nil then return nil end
                root = node
            else
                local parent = stack[#stack]
                parent.children[#parent.children + 1] = node
            end
            if selfClosing ~= "/" then stack[#stack + 1] = node end
        end
    end
    if root == nil or #stack > 0 or text:sub(pos):find("[<>]") then return nil end
    return setmetatable({ root = root, filename = filename }, Doc)
end

function fileExists(path)
    local handle = io.open(path, "rb")
    if handle == nil then return false end
    handle:close()
    return true
end

XMLFile = XMLFile or {}
-- A document also answers XMLFile's own methods (setTable), as the engine's objects do.
setmetatable(Doc, { __index = function(_, key) return XMLFile[key] end })
function XMLFile.create(_, filename, rootName) return setmetatable({ root = newNode(rootName), filename = filename }, Doc) end
function XMLFile.load(_, filename)
    local handle = io.open(filename, "rb")
    if handle == nil then return nil end
    local text = handle:read("*a")
    handle:close()
    return parse(text, filename)
end
function XMLFile.loadIfExists(name, filename)
    if filename == nil or not fileExists(filename) then return nil end
    return XMLFile.load(name, filename)
end

-- Raw handle functions (the career file is written through them).
function createXMLFile(_, filename, rootName) return XMLFile.create(nil, filename, rootName) end
function loadXMLFile(_, filename) return XMLFile.load(nil, filename) or 0 end
function setXMLString(h, path, v) h:setString(path, v) end
function setXMLInt(h, path, v) h:setInt(path, v) end
function setXMLBool(h, path, v) h:setBool(path, v) end
function setXMLFloat(h, path, v) h:setFloat(path, v) end
function getXMLString(h, path) return h:getString(path) end
function saveXMLFile(h) return h:save() end
function saveXMLFileToMemory(h) return h:toText() end

--- Read a file's bytes, write bytes (for damaging files in tests).
function XMLDisk.read(path)
    local handle = io.open(path, "rb")
    if handle == nil then return nil end
    local text = handle:read("*a")
    handle:close()
    return text
end
function XMLDisk.write(path, text)
    local handle = assert(io.open(path, "wb"))
    handle:write(text)
    handle:close()
end

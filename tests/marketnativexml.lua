-- An XMLFile over XML text with the engine's enumeration calls (getNumOfChildren,
-- getElementName with ".*(i)", getString, hasProperty), for the native animal
-- inspector. Elements and attributes only; comments and declarations dropped.
MarketNativeXml = {}

function MarketNativeXml.parse(text)
    text = text:gsub("<!%-%-.-%-%->", ""):gsub("<%?.-%?>", "")
    local root, stack = nil, {}
    for closing, name, attrText, selfClosing in text:gmatch("<(/?)([%w_%-%.]+)([^>]-)(/?)>") do
        if closing == "/" then
            table.remove(stack)
        else
            local node = { name = name, attrs = {}, children = {} }
            for attr, value in attrText:gmatch('([%w_%-%.]+)="([^"]*)"') do node.attrs[attr] = value end
            local parent = stack[#stack]
            if parent == nil then root = node else table.insert(parent.children, node) end
            if selfClosing ~= "/" then table.insert(stack, node) end
        end
    end
    return MarketNativeXml.wrap(root)
end

function MarketNativeXml.wrap(root)
    -- Resolve "a.b(1).*(2).c" to a node: named segments index among same-name
    -- children (no index = 0), "*" among all children.
    local function find(path)
        local node
        for segment in path:gmatch("[^%.]+") do
            local name, index = segment:match("^([^%(]+)%((%d+)%)$")
            if name == nil then name, index = segment, "0" end
            index = tonumber(index)
            if node == nil then
                if name ~= root.name or index ~= 0 then return nil end
                node = root
            else
                local found, seen = nil, 0
                for _, child in ipairs(node.children) do
                    if name == "*" or child.name == name then
                        if seen == index then found = child break end
                        seen = seen + 1
                    end
                end
                if found == nil then return nil end
                node = found
            end
        end
        return node
    end
    local x = { root = root, reads = 0 }
    function x:hasProperty(path)
        local node, attr = path:match("^(.-)#(.+)$")
        if node == nil then return find(path) ~= nil end
        local n = find(node)
        return n ~= nil and n.attrs[attr] ~= nil
    end
    function x:getNumOfChildren(path) local n = find(path); return n ~= nil and #n.children or 0 end
    function x:getElementName(path) local n = find(path); return n ~= nil and n.name or nil end
    function x:getString(key)
        self.reads = self.reads + 1
        local node, attr = key:match("^(.-)#(.+)$")
        local n = find(node)
        return n ~= nil and n.attrs[attr] or nil
    end
    return x
end

-- Load a mod script written for GIANTS Lua, whose loops may use `continue`, in stock Lua 5.1/5.4.
-- Each loop body that uses `continue` is wrapped in `repeat ... until true` and its `continue`
-- becomes `break`, which then leaves only that one pass. A loop that uses both `continue` and
-- its own `break` cannot be rewritten this way and is refused. Strings and comments are skipped;
-- the rest of the file is passed through unchanged, so the real code runs.

local KEYWORDS = { ["for"] = true, ["while"] = true, ["repeat"] = true, ["until"] = true, ["function"] = true,
    ["if"] = true, ["do"] = true, ["end"] = true, ["continue"] = true, ["break"] = true }

--- Positions of the keywords that open and close blocks, outside strings and comments.
local function tokens(text)
    local list, i, n = {}, 1, #text
    while i <= n do
        local c = text:sub(i, i)
        if c == "-" and text:sub(i, i + 1) == "--" then
            local level = text:match("^%-%-%[(=*)%[", i)
            if level ~= nil then
                local close = text:find("]" .. level .. "]", i, true)
                i = (close or n) + #level + 2
            else
                local eol = text:find("\n", i, true)
                i = (eol or n) + 1
            end
        elseif c == '"' or c == "'" then
            local j = i + 1
            while j <= n do
                local d = text:sub(j, j)
                if d == "\\" then j = j + 2
                elseif d == c then break
                else j = j + 1 end
            end
            i = j + 1
        elseif c == "[" and text:match("^%[=*%[", i) then
            local level = text:match("^%[(=*)%[", i)
            local close = text:find("]" .. level .. "]", i, true)
            i = (close or n) + #level + 2
        elseif c:match("[%a_]") then
            local word = text:match("^[%w_]+", i)
            local before = i > 1 and text:sub(i - 1, i - 1) or ""
            if KEYWORDS[word] and before ~= "." and before ~= ":" then
                list[#list + 1] = { word = word, from = i, to = i + #word - 1 }
            end
            i = i + #word
        else
            i = i + 1
        end
    end
    return list
end


--- The script with `continue` rewritten.
function rewriteGiantsLua(text, name)
    local stack, edits = {}, {}
    for _, token in ipairs(tokens(text)) do
        local word = token.word
        if word == "for" or word == "while" then
            stack[#stack + 1] = { kind = "loop", awaitingDo = true }
        elseif word == "do" then
            local top = stack[#stack]
            if top ~= nil and top.kind == "loop" and top.awaitingDo then
                top.awaitingDo, top.bodyFrom = false, token.to + 1
            else
                stack[#stack + 1] = { kind = "do" }
            end
        elseif word == "function" or word == "if" then
            stack[#stack + 1] = { kind = word }
        elseif word == "repeat" then
            stack[#stack + 1] = { kind = "repeat" }
        elseif word == "until" then
            table.remove(stack)
        elseif word == "continue" or word == "break" then
            local loop
            for k = #stack, 1, -1 do
                local kind = stack[k].kind
                if kind == "loop" or kind == "repeat" then loop = stack[k] break end
                if kind == "function" then break end
            end
            assert(loop ~= nil, string.format("%s: %s outside a loop", name, word))
            if word == "continue" then
                assert(loop.kind == "loop", string.format("%s: continue in repeat is not rewritten", name))
                loop.hasContinue = true
                edits[#edits + 1] = { from = token.from, to = token.to, text = "break" }
            else
                loop.hasBreak = true
            end
        elseif word == "end" then
            local block = table.remove(stack)
            if block ~= nil and block.kind == "loop" and block.hasContinue then
                assert(not block.hasBreak, string.format("%s: a loop with both continue and break", name))
                edits[#edits + 1] = { from = block.bodyFrom, to = block.bodyFrom - 1, text = " repeat " }
                edits[#edits + 1] = { from = token.from, to = token.from - 1, text = " until true " }
            end
        end
    end
    table.sort(edits, function(a, b) return a.from > b.from end)
    for _, edit in ipairs(edits) do
        text = text:sub(1, edit.from - 1) .. edit.text .. text:sub(edit.to + 1)
    end
    return text
end


--- Run a repository script written for GIANTS Lua.
function loadGiantsMod(path)
    local handle = assert(io.open(REPO .. path, "r"))
    local text = handle:read("*a")
    handle:close()
    local chunk, err = (loadstring or load)(rewriteGiantsLua(text, path), "@" .. path)
    assert(chunk, err)
    chunk()
end

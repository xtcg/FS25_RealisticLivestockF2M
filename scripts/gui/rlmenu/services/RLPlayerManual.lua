-- Frozen, author-supplied handbook. This is presentation data, never settings:
-- reading the manual must not enable experimental models or send MP events.
RLPlayerManual = {}

-- FS25 calls Simplified Chinese "cs", Traditional Chinese "ct", and Czech
-- "cz". All non-Chinese game languages deliberately use the English guide.
function RLPlayerManual.getLanguage(gameLanguage)
    local language = string.lower(tostring(gameLanguage or ""))
    return (language == "cs" or language == "ct") and "cs" or "en"
end

function RLPlayerManual.getTabTitle(gameLanguage)
    return RLPlayerManual.getLanguage(gameLanguage) == "cs" and "玩家指南" or "Player guide"
end

function RLPlayerManual.parse(xml)
    local chapters = {}
    xml:iterate("playerManual.chapter", function(_, key)
        local chapter = {
            title = xml:getString(key .. "#navTitle", xml:getString(key .. "#title", "")),
            paragraphs = {}
        }
        xml:iterate(key .. ".paragraph", function(_, paragraphKey)
            local text = xml:getString(paragraphKey .. "#text", "")
            if text ~= "" then
                table.insert(chapter.paragraphs, {
                    text = text,
                    isHeading = xml:getBool(paragraphKey .. "#heading", false),
                    image = xml:getString(paragraphKey .. "#image"),
                    imageY = xml:getInt(paragraphKey .. "#imageY", 0),
                    imageHeight = xml:getInt(paragraphKey .. "#imageHeight", 0)
                })
            end
        end)
        if chapter.title ~= "" and #chapter.paragraphs > 0 then
            table.insert(chapters, chapter)
        end
    end)
    return chapters
end

function RLPlayerManual.load(filename)
    local xml = XMLFile.load("rlPlayerManual", filename)
    if xml == nil and filename:match("playerManual_cs%.xml$") then
        xml = XMLFile.load("rlPlayerManual", filename:gsub("playerManual_cs%.xml$", "playerManual_en.xml"))
    end
    if xml == nil then
        return { { title = "Player guide", paragraphs = {
            { text = "The player guide could not be loaded. Please check the installed xml/playerManual files." }
        } } }
    end
    local chapters = RLPlayerManual.parse(xml)
    xml:delete()
    if #chapters == 0 then
        return { { title = "Player guide", paragraphs = {
            { text = "The player guide contains no readable chapters. Please check the installed XML file." }
        } } }
    end
    return chapters
end

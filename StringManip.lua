--[[
	© Justin Snelgrove

	Permission to use, copy, modify, and distribute this software for any
	purpose with or without fee is hereby granted, provided that the above
	copyright notice and this permission notice appear in all copies.

	THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
	WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
	MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY
	SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
	WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN ACTION
	OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF OR IN
	CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
]]

if not __chomp_internal or not __chomp_internal.LOADING then
	return
end

local Internal = __chomp_internal

local SAFE_BYTES = {
	[10] = true, -- newline
	[61] = true, -- equals
	[92] = true, -- backslash
	[124] = true, -- pipe
}

-- Realm part matching is greedy, as realm names will rarely have dashes, but
-- player names will never.
local FULL_PLAYER_SPLIT = FULL_PLAYER_NAME:gsub("-", "%%%%-"):format("^(.-)", "(.+)$")
local FULL_PLAYER_FIND = FULL_PLAYER_NAME:gsub("-", "%%%%-"):format("^.-", ".+$")

function AddOn_Chomp.NameMergedRealm(name, realm)
	if type(name) ~= "string" then
		error("AddOn_Chomp.NameMergedRealm(): name: expected string, got " .. type(name), 2)
	elseif name == "" then
		error("AddOn_Chomp.NameMergedRealm(): name: expected non-empty string", 2)
	elseif not realm or realm == "" then
		-- Normally you'd just return the full input name without reformatting,
		-- but Blizzard has started returning an occasional "Name-Realm Name"
		-- combination with spaces and hyphens in the realm name.
		local splitName, splitRealm = name:match(FULL_PLAYER_SPLIT)
		if splitName and splitRealm then
			name = splitName
			realm = splitRealm
		else
			realm = GetRealmName()
		end
	elseif name:find(FULL_PLAYER_FIND) then
		error("AddOn_Chomp.NameMergedRealm(): name already has a realm name, but realm name also provided")
	end
	return FULL_PLAYER_NAME:format(name, (realm:gsub("[%s%-]", "")))
end

local Serialize = setmetatable({}, {
	__index = function(self) return self["default"] end
})

-- This is a meta-type used as a default handler for unknown value types
-- which always errors; no need to explicitly check types elsewhere.
Serialize["default"] = function(input)
    error("invalid type: " .. type(input))
end

Serialize["nil"] = function(input)
	return "nil"
end

function Serialize.boolean(input)
	return tostring(input)
end

function Serialize.number(input)
	return tostring(input)
end

function Serialize.string(input)
	return ("%q"):format(input)
end

function Serialize.table(input)
    -- These functions are called in loops, so upvalue them eagerly.
    local floor     = math.floor
    local strformat = string.format
    local strfind   = string.find
    local type      = type

    -- `t` is our output buffer for each record, `n` is the number of entries
    -- to remove calls to the O(log n) `#` operator.
    local t = {}
    local n = 0

    -- Handle array parts of tables first from `t[1] .. t[n-1]` where `n` is
    -- the index of the first nil value.
    local numArray = 0
    for i, v in ipairs(input) do
        t[n + i] = Serialize[type(v)](v)
        numArray = i
    end

    -- Optimization; advance `n` by the array size instead of doing it once
    -- per iteration in the above loop.
    n = n + numArray

    -- Handle the remaining key/value pairs. We want to skip any integral keys
    -- that are within the `t[1] .. t[numArray]` range.
    for k, v in pairs(input) do
        local typeK, typeV = type(k), type(v)
        if typeK ~= "number" or k > numArray or k < 1 or k ~= floor(k) then
            n = n + 1

            if typeK == "string" and strfind(k, "^[%a_][%w_]*$") then
                -- Optimization for identifier-like string keys (no braces!).
                t[n] = strformat("%s=%s", k, Serialize[typeV](v))
            else
                t[n] = strformat("[%s]=%s", Serialize[typeK](k), Serialize[typeV](v))
            end
        end
    end

	return strformat("{%s}", table.concat(t, ",", 1, n))
end

Internal.Serialize = Serialize

function AddOn_Chomp.Serialize(object)
	local objectType = type(object)
	if not rawget(Serialize, type(object)) then
		error("AddOn_Chomp.Serialize(): object: expected serializable type, got " .. objectType, 2)
	end
	local success, serialized = pcall(Serialize[objectType], object)
	if not success then
		error("AddOn_Chomp.Serialize(): object: could not be serialized due to finding unserializable type", 2)
	end
	return serialized
end

local IsTableSafe
function IsTableSafe(t)
	for k,v in pairs(t) do
		local typeK, typeV = type(k), type(v)
		if not Serialize[typeK] or not Serialize[typeV] then
			return false
		elseif typeK == "table" and not IsTableSafe(k) then
			return false
		elseif typeV == "table" and not IsTableSafe(v) then
			return false
		end
	end
	return true
end

local EMPTY_ENV = setmetatable({}, {
	__newindex = function() end,
	__metatable = false,
})

function AddOn_Chomp.Deserialize(text)
	if type(text) ~= "string" then
		error("AddOn_Chomp.Deserialize(): text: expected string, got " .. type(text), 2)
	end
	local func = loadstring(("return %s"):format(text))
	if not func then
		error("AddOn_Chomp.Deserialize(): text: could not be loaded via loadstring", 2)
	end
	setfenv(func, EMPTY_ENV)
	local retSuccess, ret = pcall(func)
	local retType = type(ret)
	if not retSuccess then
		error("AddOn_Chomp.Deserialize(): text: error while reading data", 2)
	elseif not Serialize[retType] then
		error("AddOn_Chomp.Deserialize(): text: deserialized to invalid type: " .. type(ret), 2)
	elseif retType == "table" and text:find("function", nil, true) and not IsTableSafe(ret) then
		error("AddOn_Chomp.Deserialize(): text: deserialized table included forbidden type", 2)
	end
	return ret
end

function AddOn_Chomp.CheckLoggedContents(text)
	if type(text) ~= "string" then
		error("AddOn_Chomp.CheckLoggedContents(): text: expected string, got " .. type(text), 2)
	end
	if text:find("[%z\001-\009\011-\031\127]") then
		return false, "ASCII_CONTROL"
	elseif text:find("\229\141[\141\144]") then
		return false, "BLIZZ_ABUSIVE"
	elseif text:find("[\192\193\245-\255]") then
		return false, "UTF8_UNUSED_BYTE"
	elseif text:find("[\194-\244]+[\194-\244]") then
		return false, "UTF8_MULTIPLE_LEADING"
	elseif text:find("\224[\128-\159][\128-\191]") or text:find("\240[\128-\143][\128-\191][\128-\191]") or text:find("\244[\143-\191][\128-\191][\128-\191]") then
		return false, "UTF8_MALFORMED"
	elseif text:find("\237\158[\154-\191]") or text:find("\237[\159-\191][\128-\191]") then
		return false, "UTF16_RESERVED"
	elseif text:find("[\194-\244]%f[^\128-\191\194-\244]") or text:find("[\224-\244][\128-\191]%f[^\128-\191]") or text:find("[\240-\244][\128-\191][\128-\191]%f[^\128-\191]") then
		return false, "UTF8_MISSING_CONTINUATION"
	elseif text:find("%f[\128-\191\194-\244][\128-\191]+") then
		return false, "UTF8_MISSING_LEADING"
	elseif text:find("[\194-\223][\128-\191][\128-\191]+") or text:find("[\224-\239][\128-\191][\128-\191][\128-\191]+") or text:find("[\240-\244][\128-\191][\128-\191][\128-\191][\128-\191]+") then
		return false, "UTF8_EXTRA_CONTINUATION"
	elseif text:find("\239\191[\190\191]") then
		return false, "UNICODE_INVALID"
	end
	return true, nil
end

local function CharToQuotedPrintable(c)
	return ("`%02X"):format(c:byte())
end

local function StringToQuotedPrintable(s)
	return (s:gsub(".", CharToQuotedPrintable))
end

local function TooManyContinuations(s1, s2)
	return s1 .. (s2:gsub(".", CharToQuotedPrintable))
end

function Internal.EncodeQuotedPrintable(text, restrictBinary)
	-- First, the quoted-printable escape character.
	text = text:gsub("`", CharToQuotedPrintable)

	if not restrictBinary then
		-- Just NUL, which never works normally.
		text = text:gsub("%z", CharToQuotedPrintable)

		-- Bytes not used in UTF-8 ever.
		text = text:gsub("[\192\193\245-\255]", CharToQuotedPrintable)

		-- Multiple leading bytes.
		text = text:gsub("[\194-\244]+[\194-\244]", function(s)
			return (s:gsub(".", CharToQuotedPrintable, #s - 1))
		end)

		--- Unicode 11.0.0, Table 3-7 malformed UTF-8 byte sequences.
		text = text:gsub("\224[\128-\159][\128-\191]", StringToQuotedPrintable)
		text = text:gsub("\240[\128-\143][\128-\191][\128-\191]", StringToQuotedPrintable)
		text = text:gsub("\244[\143-\191][\128-\191][\128-\191]", StringToQuotedPrintable)

		-- UTF-16 reserved codepoints
		text = text:gsub("\237\158[\154-\191]", StringToQuotedPrintable)
		text = text:gsub("\237[\159-\191][\128-\191]", StringToQuotedPrintable)

		-- Unicode invalid codepoints
		text = text:gsub("\239\191[\190\191]", StringToQuotedPrintable)

		-- 2-4-byte leading bytes without enough continuation bytes.
		text = text:gsub("[\194-\244]%f[^\128-\191\194-\244]", CharToQuotedPrintable)
		-- 3-4-byte leading bytes without enough continuation bytes.
		text = text:gsub("[\224-\244][\128-\191]%f[^\128-\191]", StringToQuotedPrintable)
		-- 4-byte leading bytes without enough continuation bytes.
		text = text:gsub("[\240-\244][\128-\191][\128-\191]%f[^\128-\191]", StringToQuotedPrintable)

		-- Continuation bytes without leading bytes.
		text = text:gsub("%f[\128-\191\194-\244][\128-\191]+", StringToQuotedPrintable)

		-- 2-byte character with too many continuation bytes
		text = text:gsub("([\194-\223][\128-\191])([\128-\191]+)", TooManyContinuations)
		-- 3-byte character with too many continuation bytes
		text = text:gsub("([\224-\239][\128-\191][\128-\191])([\128-\191]+)", TooManyContinuations)
		-- 4-byte character with too many continuation bytes
		text = text:gsub("([\240-\244][\128-\191][\128-\191][\128-\191])([\128-\191]+)", TooManyContinuations)
	else
		-- Binary-restricted messages don't permit UI escape sequences.
		text = text:gsub("|", CharToQuotedPrintable)
		-- They're also picky about backslashes -- ex. \\n (literal \n) fails.
		text = text:gsub("\\", CharToQuotedPrintable)
		-- Newlines are truly necessary but not permitted.
		text = text:gsub("\010", CharToQuotedPrintable)
	end

	return text
end

function AddOn_Chomp.EncodeQuotedPrintable(text)
	if type(text) ~= "string" then
		error("AddOn_Chomp.EncodeQuotedPrintable(): text: expected string, got " .. type(text), 2)
    end

	-- First, the quoted-printable escape character.
	text = text:gsub("`", CharToQuotedPrintable)

	-- Logged messages don't permit UI escape sequences.
	text = text:gsub("|", CharToQuotedPrintable)
	-- They're also picky about backslashes -- ex. \\n (literal \n) fails.
	text = text:gsub("\\", CharToQuotedPrintable)
	-- Some characters are considered abusive-by-default by Blizzard.
	text = text:gsub("\229\141[\141\144]", StringToQuotedPrintable)
	-- ASCII control characters. \009 and \127 are allowed for some reason.
	text = text:gsub("[%z\001-\008\010-\031]", CharToQuotedPrintable)

	-- Bytes not used in UTF-8 ever.
	text = text:gsub("[\192\193\245-\255]", CharToQuotedPrintable)

	-- Multiple leading bytes.
	text = text:gsub("[\194-\244]+[\194-\244]", function(s)
		return (s:gsub(".", CharToQuotedPrintable, #s - 1))
	end)

	--- Unicode 11.0.0, Table 3-7 malformed UTF-8 byte sequences.
	text = text:gsub("\224[\128-\159][\128-\191]", StringToQuotedPrintable)
	text = text:gsub("\240[\128-\143][\128-\191][\128-\191]", StringToQuotedPrintable)
	text = text:gsub("\244[\143-\191][\128-\191][\128-\191]", StringToQuotedPrintable)

	-- UTF-16 reserved codepoints
	text = text:gsub("\237\158[\154-\191]", StringToQuotedPrintable)
	text = text:gsub("\237[\159-\191][\128-\191]", StringToQuotedPrintable)

	-- Unicode invalid codepoints
	text = text:gsub("\239\191[\190\191]", StringToQuotedPrintable)

	-- 2-4-byte leading bytes without enough continuation bytes.
	text = text:gsub("[\194-\244]%f[^\128-\191\194-\244]", CharToQuotedPrintable)
	-- 3-4-byte leading bytes without enough continuation bytes.
	text = text:gsub("[\224-\244][\128-\191]%f[^\128-\191]", StringToQuotedPrintable)
	-- 4-byte leading bytes without enough continuation bytes.
	text = text:gsub("[\240-\244][\128-\191][\128-\191]%f[^\128-\191]", StringToQuotedPrintable)

	-- Continuation bytes without leading bytes.
	text = text:gsub("%f[\128-\191\194-\244][\128-\191]+", StringToQuotedPrintable)

	-- 2-byte character with too many continuation bytes
	text = text:gsub("([\194-\223][\128-\191])([\128-\191]+)", TooManyContinuations)
	-- 3-byte character with too many continuation bytes
	text = text:gsub("([\224-\239][\128-\191][\128-\191])([\128-\191]+)", TooManyContinuations)
	-- 4-byte character with too many continuation bytes
	text = text:gsub("([\240-\244][\128-\191][\128-\191][\128-\191])([\128-\191]+)", TooManyContinuations)

	return text
end

local function DecodeAnyByte(b)
	return string.char(tonumber(b, 16))
end

local function DecodeSafeByte(b)
	local byteNum = tonumber(b, 16)
	if SAFE_BYTES[byteNum] then
		return string.char(byteNum)
	else
		return ("`%02X"):format(byteNum)
	end
end

function Internal.DecodeQuotedPrintable(text, restrictBinary)
	local decodedText = text:gsub("`(%x%x)", not restrictBinary and DecodeAnyByte or DecodeSafeByte)
	return decodedText
end

function AddOn_Chomp.DecodeQuotedPrintable(text)
	if type(text) ~= "string" then
		error("AddOn_Chomp.DecodeQuotedPrintable(): text: expected string, got " .. type(text), 2)
	end
	local decodedText = text:gsub("`(%x%x)", DecodeAnyByte)
	return decodedText
end

function AddOn_Chomp.SafeSubString(text, first, last, textLen)
	if type(text) ~= "string" then
		error("AddOn_Chomp.SafeSubString(): text: expected string, got " .. type(text), 2)
	elseif type(first) ~= "number" then
		error("AddOn_Chomp.SafeSubString(): first: expected number, got " .. type(first), 2)
	elseif type(last) ~= "number" then
		error("AddOn_Chomp.SafeSubString(): last: expected number, got " .. type(last), 2)
	elseif textLen and type(textLen) ~= "number" then
		error("AddOn_Chomp.SafeSubString(): textLen: expected number or nil, got " .. type(textLen), 2)
	end
	local offset = 0
	if not textLen then
		textLen = #text
	end
	if first > textLen then
		error("AddOn_Chomp.SafeSubString(): first: starting index exceeds text length", 2)
	end
	if textLen > last then
		local b3, b2, b1 = text:byte(last - 2, last)
		-- 96 is numeric code for "`"
		if b1 == 96 or (b1 >= 194 and b1 <= 244) then
			offset = 1
		elseif b2 == 96 or (b2 >= 224 and b2 <= 244) then
			offset = 2
		elseif b3 >= 240 and b3 <= 244 then
			offset = 3
		end
	end
	return (text:sub(first, last - offset)), offset
end

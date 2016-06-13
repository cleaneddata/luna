local Lexer = {}
Lexer.__index = Lexer

function Lexer.new(str)
	return setmetatable({
		buf = str,
		tokens = {},
		pos = 1,

		line = 1,
		col = 1
	}, Lexer)
end

function Lexer:error(msg, line, col)
	 error(msg .. " at line " .. (line or self.line) .. " col " .. (col or self.col))
end

-- Attempts to match given pattern and advances lexer forward if match is found
-- 'p' must be a Lua pattern string
-- Returns match as text
function Lexer:_readPattern(p)
	local txt = self.buf:match(p, self.pos)
	if not txt then
		return nil
	end

	self.pos = self.pos + #txt

	-- Count how many lines and cols did we advance

	local afterLastNLSpace = txt:match("\r?\n([^\n]*)$")
	-- there was at least one newline
	if afterLastNLSpace then
		local nlCount = 0
		for nl in txt:gmatch("\n") do nlCount = nlCount + 1 end
		self.line = self.line + nlCount
		self.col = 1 + #afterLastNLSpace
	else
		-- tabs count as 4 spaces
		local tabCount = 0
		for tab in txt:gmatch("\t") do tabCount = tabCount + 1 end
		
		self.col = self.col + #txt - tabCount + (tabCount * 4)
	end

	return txt
end

function Lexer:_skipWhitespace()
	self:_readPattern("^%s+")
end

function Lexer:_createToken(type)
	local pos, line, col = self.pos, self.line, self.col
	return { type = type, pos = pos, line = line, col = col }
end

function Lexer:_readToken(type, pattern)
	local token = self:_createToken(type)
	local matched = self:_readPattern(pattern)
	if matched then
		token.text = matched
		return token
	end
end

local _keywords = {
	["local"] = true, ["return"] = true, ["break"] = true, ["function"] = true,
	["end"] = true, ["do"] = true, ["if"] = true, ["while"] = true, ["for"] = true,
	["else"] = true, ["elseif"] = true, ["then"] = true, ["in"] = true
}
function Lexer:_readIdentifierOrKeyword()
	local id = self:_readToken("identifier", "^[_%a][_%w]*")
	if id and _keywords[id.text] then
		id.type = "keyword"
	end
	return id
end

function Lexer:_readBracketBlock()
	local start = self:_readPattern("^%[%[")
	if start then
		local contentsAndEnd = self:_readPattern("^.-%]%]")
		if not contentsAndEnd then
			self:error("unterminated bracket block")
		end

		return start .. contentsAndEnd
	end
end

-- Reads a one line string
function Lexer:_readOneLineString()
	local start = self:_readPattern("^[\"\']")
	if not start then return end

	local strCharacter = start

	local token = self:_createToken("literal")
	token.pos = token.pos - 1
	token.col = token.col - 1

	local sbuf = {start}

	while true do
		-- find the first quotation within string
		local send = self:_readPattern("^[^" .. strCharacter .. "]*")
		table.insert(sbuf, send)

		-- read the following quotation
		local fquot = self:_readPattern("^" .. strCharacter)
		if not fquot then self:error("unterminated string") end
		table.insert(sbuf, fquot)

		-- match the backslaces preceding that quot (the quot mark is not matched in 'send' so we can match from end)
		local bslashes = send:match("\\+$")
		if not bslashes or #bslashes % 2 == 0 then -- even amount or no bslashes; terminate string here 
			break
		end
	end

	token.text = table.concat(sbuf, "")

	return token
end

function Lexer:_readBlockString()
	local token = self:_createToken("literal")

	local block = self:_readBracketBlock()
	if block then
		token.text = block
		return token
	end
end

function Lexer:_readString()
	return self:_readOneLineString() or self:_readBlockString()
end

function Lexer:_readComment()
	-- TODO store comment in somewhere

	local start = self:_readPattern("^%-%-")
	if not start then
		return
	end

	local c = self:_createToken("comment")

	local block = self:_readBracketBlock()
	if block then
		c.text = block
	else
		c.text = self:_readPattern("^[^\n]*")
	end

	return c
end

function Lexer:next()
	-- read all comments
	repeat
		self:_skipWhitespace()
	until not self:_readComment()

	if self.pos > #self.buf then
		return nil -- EOF
	end

	return
		self:_readString() or

		--self:_readComment() or

		-- longer symbol sequences
		self:_readToken("symbol", "^%.%.%.") or
		self:_readToken("symbol", "^%=%>") or

		-- this needs to be here so that it's detected over single period
		self:_readToken("binop", "^%.%.") or

		-- 1-char symbols
		self:_readToken("symbol", "^[%:%;%,%(%)%[%]%{%}%.%?]") or

		-- mod assign ops (must be before 1-char binops)
		self:_readToken("assignop", "^[%+%-%*%/%^%%]%=") or
		self:_readToken("assignop", "^%|%|%=") or

		-- longer binop sequences
		self:_readToken("binop", "^%<%=") or
		self:_readToken("binop", "^%>%=") or
		self:_readToken("binop", "^%=%=") or
		self:_readToken("binop", "^%~%=") or
		self:_readToken("binop", "^and") or
		self:_readToken("binop", "^or") or
		-- 1-char binops
		self:_readToken("binop", "^[%+%-%*%/%^%%%<%>]") or

		-- assign op (must be after binops)
		self:_readToken("assignop", "^%=") or

		-- unary ops
		self:_readToken("unop", "^%-") or
		self:_readToken("unop", "^not") or
		self:_readToken("unop", "^%#") or
		self:_readToken("unop", "^%~") or

		self:_readIdentifierOrKeyword() or
		self:_readToken("number", "^[%d%.]+") or

		self:error("invalid token " .. self.buf:sub(self.pos, self.pos))
end

return Lexer

local luafier = {}

-- the last line this node appears on
function luafier.getNodeLastLine(n)
	local s = n.line
	if not s then return -1 end

	local l = s
	for k,v in ipairs(n) do
		l = math.max(l, luafier.getNodeLastLine(v))
	end
	return l
end

function luafier.isParentOf(par, node)
	if par == node then return true end
	for k,v in ipairs(par) do
		if v == node or (type(v) == "table" and luafier.isParentOf(v, node)) then return true end
	end
	return false
end

-- Gets the linenumber difference between these two nodes
-- Returns nil if it cannot/shouldn't be derived from these nodes
function luafier.getLinenoDiff(node1, node2)
	local line1, line2

	if type(node1) == "number" then
		line1 = node1
	else
		line1 = luafier.getNodeLastLine(node1)
	end

	line2 = node2.line

	if not line1 or not line2 then
		return nil
	end

	return line2 - line1
end

function luafier.listToLua(list, opts, buf)
	local lastnode
	for i,snode in ipairs(list) do
		if i > 1 then buf:append(", ") end

		local lndiff = opts.matchLinenumbers and lastnode and luafier.getLinenoDiff(lastnode, snode)
		lastnode = snode
		if lndiff and lndiff > 0 then
			for i=1, lndiff do buf:nl() end
		end

		luafier.internalToLua(snode, opts, buf)
	end
end

function luafier.processParListFuncBlock(parlist, funcbody)
	local typechecks = {}
	for _,par in ipairs(parlist) do
		local name = par[1]
		local type = par[2]
		if type then
			table.insert(typechecks, {var = name.text, type = type[1].text, nillable = type[2]})
		end
	end

	for i,tc in pairs(typechecks) do
		-- copy line from parlist line; we want asserts to be on same line as func declaration
		local tcnode = { type = "funccall", line = parlist.line }
		tcnode[1] = { type = "identifier", text = "assert" }
		local args = { type = "explist" }
		tcnode[2] = args

		local typeChecker = {
			type = "binop", "==",
			{ type = "funccall", { type = "identifier", text = "type" }, { type = "identifier", text = tc.var } },
			{ type = "literal", text = "\"" .. tc.type .. "\""}
		}
		if tc.nillable then
			local nilChecker = { type = "unop", "not", { type = "identifier", text = tc.var } }
			args[1] = { type = "binop", "or", nilChecker, typeChecker }
		else
			args[1] = typeChecker
		end

		args[2] = { type = "literal", text = [["Parameter ']] .. tc.var .. [[' must be a ]] .. tc.type .. [["]]}
		
		table.insert(funcbody, i, tcnode)
	end

	return parlist, funcbody
end

local luaBuffer = {}
luaBuffer.__index = luaBuffer

function luaBuffer.new(indentString, nlString, noExtraSpace)
	return setmetatable({
		buf = {},
		indent = 0,
		indentString = indentString,
		nlString = nlString,
		noExtraSpace = noExtraSpace,

		line = 1
	}, luaBuffer)
end
function luaBuffer:appendln(t)
	self:append(t)
	self:nl()
end
function luaBuffer:append(t)
	if not self.hasIndented then
		self.buf[#self.buf + 1] = self.indentString:rep(self.indent)
		self.hasIndented = true
	end
	self.buf[#self.buf + 1] = t
end
function luaBuffer:nl()
	self.buf[#self.buf + 1] = self.nlString
	self.line = self.line + 1
	self.hasIndented = false
end
function luaBuffer:nlIndent()
	self:nl()
	self.indent = self.indent + 1
end
function luaBuffer:nlUnindent()
	self:nl()
	self.indent = self.indent - 1
end

-- Appends optional space. This might nop depending on the options 
function luaBuffer:appendSpace(t)
	if not self.noExtraSpace then
		self:append(t)
	end
end

function luaBuffer:tostring()
	return table.concat(self.buf, "")
end

function luafier.internalToLua(node, opts, buf)
	local function toLua(lnode)
		luafier.internalToLua(lnode, opts, buf)
	end
	local function listToLua(lnode)
		luafier.listToLua(lnode, opts, buf)
	end

	-- Gets the linenumber difference between these two nodes
	-- Returns nil if it cannot/shouldn't be derived from these nodes
	local function getLinenoDiff(node1, node2)
		if opts.matchLinenumbers then
			return luafier.getLinenoDiff(node1, node2)
		end
	end

	-- Adds indentation+nl/spaces around given block based on options
	-- n1 is preceding node
	-- n2 is the block node
	-- fn is the function that adds internal contents
	local function wrapIndent(n1, n2, fn, alsoIfPrettyPrint)
		local lndiff = getLinenoDiff(n1, n2)
		local addNl = lndiff or ((alsoIfPrettyPrint and opts.prettyPrint) and 1) or 0

		if addNl > 0 then
			buf:nlIndent()
			for i=1,addNl-1 do buf:nl() end
		else
			buf:appendSpace(" ")
		end

		fn()

		if addNl > 0 then
			buf:nlUnindent()
		else
			buf:append(" ")
		end
	end

	if node.type == "block" then
		for i,snode in ipairs(node) do

			local lndiff = getLinenoDiff(buf.line, snode)
			if lndiff then
				if lndiff > 0 then
					for i=1,lndiff do buf:nl() end
				elseif lndiff == 0 then
					-- add newlines before all except first node if we're not ahead of ourselves
					if i > 1 then buf:nl() end
				end
			elseif opts.prettyPrint then
				-- add newlines before all except first node if we're prettyprinting
				if i > 1 then buf:nl() end
			end

			-- if something has already been done on this line add semicolon
			if buf.hasIndented then
				buf:append("; ")
			end

			toLua(snode)
		end

	elseif node.type == "local" then
		buf:append("local ")
		toLua(node[1])
		if node[2] then -- has explist
			buf:append(" = ")
			toLua(node[2])
		end
		
	elseif node.type == "localdestructor" then
		local destructor, target = node[1], node[2]
		local names = destructor[1]

		buf:append("local ")
		for i,name in ipairs(names) do
			if i > 1 then buf:append(", ") end
			toLua(name)
		end
		buf:append(" = ")

		if destructor.type == "arraydestructor" then
			for i = 1, #names do
				if i > 1 then buf:append(", ") end
				toLua(target); buf:append("["); buf:append(tostring(i)); buf:append("]")
			end
		elseif destructor.type == "tabledestructor" then
			for i,member in ipairs(names) do
				if i > 1 then buf:append(", ") end
				toLua(target); buf:append("."); toLua(member)
			end
		end

	elseif node.type == "funcname" then
		local methodOffset = node.isMethod and -1 or 0
		for i = 1, #node + methodOffset do
			if i > 1 then buf:append(".") end
			toLua(node[i])
		end

		if node.isMethod then
			buf:append(":")
			toLua(node[#node])
		end
	elseif node.type == "localfunc" then
		buf:append("local function ")
		toLua(node[1])
		toLua(node[2])

	elseif node.type == "globalfunc" then
		buf:append("function ")
		toLua(node[1])
		toLua(node[2])

	elseif node.type == "func" then
		buf:append("function ")
		toLua(node[1])

	elseif node.type == "sfunc" or node.type == "funcbody" then
		local pl, fb = luafier.processParListFuncBlock(node[1], node[2])

		if node.type == "sfunc" then
			buf:append("function(")
		else
			buf:append("(")
		end
		listToLua(pl)
		buf:append(")")

		wrapIndent(pl, fb, function() toLua(fb) end, true)

		buf:append("end")
	elseif node.type == "assignment" then
		local op = node[1]

		if op == "=" then
			toLua(node[2]); buf:append(" = "); toLua(node[3])
		elseif op == "||=" then
			assert(#node[3] == 1, "falsey assignment only works on 1-long explists currently")
			toLua(node[2]); buf:append(" = "); toLua(node[2]); buf:append(" or ("); toLua(node[3]); buf:append(")")
		else
			assert(#node[3] == 1, "mod assignment only works on 1-long explists currently")

			-- what kind of modification to do
			local modop = op:sub(1, 1)
			
			toLua(node[2]); buf:append(" = "); toLua(node[2]); buf:append(" "); buf:append(modop); buf:append(" ("); toLua(node[3]); buf:append(")")
		end
	elseif node.type == "funccall" then
		toLua(node[1]); buf:append("("); toLua(node[2]); buf:append(")")
	elseif node.type == "methodcall" then
		toLua(node[1]); buf:append(":"); toLua(node[2]); buf:append("("); toLua(node[3]); buf:append(")")

	elseif node.type == "args" or node.type == "fieldlist" or node.type == "parlist" or node.type == "typednamelist" or node.type == "varlist" or node.type == "explist" then
		listToLua(node)
		
	elseif node.type == "typedname" then
		toLua(node[1])

	elseif node.type == "return" then
		buf:append("return")
		if node[1] then
			buf:append(" ")
			toLua(node[1])
		end

	elseif node.type == "break" then
		buf:append("break")

	elseif node.type == "index" then
		toLua(node[1]); buf:append("."); toLua(node[2])

	elseif node.type == "tableconstructor" then
		buf:append("{");

		-- returns either first field of fieldlist or fieldlist itself
		local firstField = node[1][1] or node[1]

		-- need to use .line here, otherwise it gets the last line which doesn't work because firstField is child of node
		wrapIndent(node.line, firstField, function() toLua(node[1]) end)
		
		buf:append("}")
		
	elseif node.type == "field" then
		local key, val = node[1], node[2]
		if key then
			if key.type == "identifier" then
				toLua(key)
			else
				buf:append("["); toLua(key); buf:append("]")
			end
			buf:appendSpace(" "); buf:append("="); buf:appendSpace(" "); toLua(val)
		else
			toLua(val)
		end

	elseif node.type == "ifassign" then
		-- Create a temporary variable name for the variable to be assigned before the if
		local origAssignedVarName = node[1][1][1][1].text -- ohgod
		local varName = "_ifa_" .. origAssignedVarName

		-- Set the assignment variable name to generated name
		node[1][1][1][1].text = varName

		-- Create a new if block that checks if varName is trueish
		local varId = { line = node[1].line, type = "identifier", text = varName }
		local checkerIf = { line = node[1].line, type = "if", varId, node[2], node[3] }

		-- Create a new local binding to restore the old name within the if scope and set it as the first code within if
		local restoreBinding = { type = "local", { type = "identifier", text = origAssignedVarName }, varId }
		table.insert(checkerIf[2], 1, restoreBinding)

		toLua(node[1]); buf:append("; ") toLua(checkerIf)

	elseif node.type == "if" or node.type == "elseif" then
		buf:append(node.type); buf:append(" "); toLua(node[1]); buf:append(" then");
		
		wrapIndent(node, node[2], function()
			toLua(node[2])
		end, true)

		if node[3] then
			toLua(node[3])
		else
			buf:append("end")
		end
	elseif node.type == "else" then
		buf:append("else");
		wrapIndent(node, node[1], function()
			toLua(node[1])
		end, true)
		buf:append("end")

	elseif node.type == "while" then
		buf:append("while "); toLua(node[1]); buf:append(" do");
		wrapIndent(node, node[2], function()
			toLua(node[2])
		end, true)
		buf:append("end")

	elseif node.type == "fornum" then
		local var, low, high, step, b = node[1], node[2], node[3], node[4], node[5]
		buf:append("for "); toLua(var); buf:appendSpace(" "); buf:append("="); buf:appendSpace(" "); toLua(low); buf:append(","); buf:appendSpace(" "); toLua(high)
		if step then
			buf:append(","); buf:appendSpace(" ")
			toLua(step)
		end
		buf:append(" do");
		wrapIndent(step, b, function()
			toLua(b)
		end, true)
		buf:append("end")
	elseif node.type == "forgen" then
		local names, iter, b = node[1], node[2], node[3]
		buf:append("for "); toLua(names); buf:append(" in "); toLua(iter); buf:append(" do");
		wrapIndent(iter, b, function()
			toLua(b)
		end, true)
		buf:append("end")

	elseif node.type == "binop" then
		toLua(node[2]); buf:appendSpace(" "); buf:append(node[1]);
		
		local lndiff = getLinenoDiff(node[2], node[3])

		if lndiff then
			for i=1,lndiff do buf:nl() end
		else
			buf:appendSpace(" ")
		end
		toLua(node[3])

	elseif node.type == "unop" then
		buf:append(node[1])
		if node[1] == "not" then
			buf:append(" ")
		end
		toLua(node[2])

	elseif node.type == "identifier" then
		buf:append(node.text)
		
	elseif node.type == "literal" then
		buf:append(node.text)

	elseif node.type == "number" then
		buf:append(node.text)

	else
		error("unhandled ast node " .. node.type)
	end
end

local defopts = {
	-- attempts to create Lua that has same statements on same line numbers as source file
	matchLinenumbers = true,

	-- Tries to create as readable Lua as possible. If enabled alongside matchLinenumbers, it will be preferred over this option in stylistic decisions.
	prettyPrint = true,
	
	-- the indentation character (or string) that will be equal to one level of indentation in the output code
	indentString = "\t",

	-- the newline character that will be used for newlines in the output code
	nlString = "\n",
}

function luafier.toLua(node, useropts)
	local opts = {}

	for k,v in pairs(defopts) do opts[k] = v end
	if useropts then
		for k,v in pairs(useropts) do opts[k] = v end
	end

	local bufIndentString = opts.prettyPrint and opts.indentString or ""

	local buf = luaBuffer.new(bufIndentString, opts.nlString, not opts.prettyPrint)
	luafier.internalToLua(node, opts, buf)
	return buf:tostring()
end

return luafier
local args = {...}

local function loadInput()
-- check if we should read from a file instead of stdin
	if args[2] then
		io.input(args[2])
	end

	return io.read("*a")
end

local thisFilePath = arg[0]
if thisFilePath then
	local thisFolderPath = thisFilePath:gsub("\\", "/"):match("^(.-)[\\/][^\\/]+$")
	package.path = package.path .. ";" .. thisFolderPath .. "/bin/?.lua"
else
	package.path = package.path .. ";bin/?.lua"
end

local _compiler, _packager = require("compiler"), require("packager")

compilestring = loadstring or load -- 5.2/5.3 compat

-- Small library for OS specific commands
local sys = {}

-- OS detection hack! from: http://stackoverflow.com/a/14425862
sys.isWindows = package.config:sub(1,1) == "\\"

function sys.ls(folder)
	local cmd = sys.isWindows and ("dir /b /a-d " .. folder:match("^(.-)/?$")) or ("ls -1 " .. folder)
	local out = io.popen(cmd)
	local t = {}
	for line in out:lines() do
		table.insert(t, line)
	end
	return t
end

-- Source: MoonScript moonc
function sys.dirscan(root, filter, _collected)
	_collected = _collected or {}

	for _,fname in pairs(sys.ls(root)) do
		if not fname:match("^%.") then
			local full_path = root .. fname

			-- run below if path is a folder
			--sys.dirscan(full_path, filter, _collected)

			if not filter or filter(full_path) then
				table.insert(_collected, full_path)
			end
		end
	end

	return _collected
end

local function compileAll(srcFolder, outFolder)
	local scanned = sys.dirscan(srcFolder .. "/", function(f) return f:match("%.luna$") end)

	local map = {}

	for _,srcf in pairs(scanned) do
		local f = io.open(srcf, "rb")
		local luna = f:read("*a")
		f:close()

		local lua = _compiler.lunaToLua(luna)

		local path = srcf:sub(#srcFolder + 2):match("^(.-)%.luna$") -- remove srcfolder prefix and extension
		local nf, e = io.open(outFolder .. "/" .. path .. ".lua", "w")
		if not nf then
			error("Error while trying to write compiled Luna to " .. path .. ": " .. e)
		end
		nf:write(lua)
		nf:close()
	end
end

if args[1] == "compile" or args[1] == "c" then
	print(_compiler.lunaToLua(loadInput()))

elseif args[1] == "compile-all" then

	local srcFolder = args[2] or "src"
	local outFolder = args[3] or "bin"

	compileAll(srcFolder, outFolder)

elseif args[1] == "pack" then
	local folder = args[2] or error("Please provide the folder for sources to pack")
	local main = args[3] or error("Please provide the main module to run upon loading the packed file")
	local outFile = args[4] or "pack.lua"

	local scanned = sys.dirscan(folder .. "/", function(f) return f:match("%.luna$") end)

	local map = {}

	for _,srcf in pairs(scanned) do
		local f = io.open(srcf, "rb")
		local luna = f:read("*a")
		f:close()

		local lunanode = _compiler.lunaToAST(luna)

		local modPath = srcf:sub(#folder + 2):match("^(.-)%.luna$") -- remove srcfolder prefix and extension
		map[modPath] = lunanode
	end

	local packedLua = _packager.packageMap(map, main)

	local nf, e = io.open(outFile, "w")
	nf:write(packedLua)
	nf:close()

elseif args[1] == "ast" then
	local block = _compiler.lunaToAST(loadInput())
	
	local function printnode(t, i)
		local indent = ("  "):rep(i or 0)
		local indentn = ("  "):rep((i or 0) + 1)

		local function printkv(k, v)
			io.write(indent)
			io.write(tostring(k))
			io.write(" = ")

			if type(v) == "table" then
				print()
				printnode(v, (i or 0) + 1)
			else
				print(tostring(v))
			end
		end

		if t.type then
			local s = string.format("[%s at line %d; col %d]", t.type, t.line or -1, t.col or -1)
			if t.type == "identifier" or t.type == "literal" then
				print(indent .. s .. " = " .. t.text)
			else
				print(indent .. s .. " {")
				for k,v in ipairs(t) do
					if type(v) == "table" then
						printnode(v, (i or 0) + 1)
					else
						print(indentn .. tostring(v))
					end
				end
				print(indent .. "}")
			end
		else
			for k,v in pairs(t) do
				printkv(k, v)
			end
		end
	end
	printnode(block)
elseif args[1] == "run" then
	local luac = _compiler.lunaToLua(loadInput())
	
	local f, e = compilestring(luac)
	if f then
		f()
	else
		print("compilation failed: ", e)
	end
elseif args[1] == "t" or args[1] == "test" then
	-- needed for non-Luna projects that use test
	package.path = package.path .. ";bin/?.lua"

	for _,name in pairs(sys.ls("tests")) do
		if name:match("%.luna$") then
			io.write("Testing '" .. name .. "' .. ")
			
  			local f = io.open("tests/" .. name, "rb")
			local src = f:read("*a")
			f:close()

			io.write("luafying .. ")
			local luafied = _compiler.lunaToLua(src)

			io.write("running .. ")
			local f, e = compilestring(luafied, "tests/" .. name)
			if f then
				f()
			else
				error("Lua compilation failed: " .. e)
			end

			print("done")
		end
	end
else
	print("No command given. Try 'compile', 'ast' or 'run'.")
end
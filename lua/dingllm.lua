local M = {}
local Job = require("plenary.job")

local function get_api_key(name)
	return os.getenv(name)
end

function M.get_lines_until_cursor()
	local current_buffer = vim.api.nvim_get_current_buf()
	local current_window = vim.api.nvim_get_current_win()
	local cursor_position = vim.api.nvim_win_get_cursor(current_window)
	local row = cursor_position[1]

	local lines = vim.api.nvim_buf_get_lines(current_buffer, 0, row, true)

	return table.concat(lines, "\n")
end

function M.get_visual_selection()
	local _, srow, scol = unpack(vim.fn.getpos("v"))
	local _, erow, ecol = unpack(vim.fn.getpos("."))

	if vim.fn.mode() == "V" then
		if srow > erow then
			return vim.api.nvim_buf_get_lines(0, erow - 1, srow, true)
		else
			return vim.api.nvim_buf_get_lines(0, srow - 1, erow, true)
		end
	end

	if vim.fn.mode() == "v" then
		if srow < erow or (srow == erow and scol <= ecol) then
			return vim.api.nvim_buf_get_text(0, srow - 1, scol - 1, erow - 1, ecol, {})
		else
			return vim.api.nvim_buf_get_text(0, erow - 1, ecol - 1, srow - 1, scol, {})
		end
	end

	if vim.fn.mode() == "\22" then
		local lines = {}
		if srow > erow then
			srow, erow = erow, srow
		end
		if scol > ecol then
			scol, ecol = ecol, scol
		end
		for i = srow, erow do
			table.insert(
				lines,
				vim.api.nvim_buf_get_text(0, i - 1, math.min(scol - 1, ecol), i - 1, math.max(scol - 1, ecol), {})[1]
			)
		end
		return lines
	end
end

function M.make_anthropic_spec_curl_args(opts, prompt, system_prompt)
	local url = opts.url
	local api_key = opts.api_key_name and get_api_key(opts.api_key_name)
	local data = {
		system = system_prompt,
		messages = { { role = "user", content = prompt } },
		model = opts.model,
		stream = true,
		max_tokens = 4096,
	}
	local args = { "-N", "-X", "POST", "-H", "Content-Type: application/json", "-d", vim.json.encode(data) }
	if api_key then
		table.insert(args, "-H")
		table.insert(args, "x-api-key: " .. api_key)
		table.insert(args, "-H")
		table.insert(args, "anthropic-version: 2023-06-01")
	end
	table.insert(args, url)
	return args
end

function M.make_openai_spec_curl_args(opts, prompt, system_prompt)
	local url = opts.url
	local api_key = opts.api_key_name and get_api_key(opts.api_key_name)
	local data = {
		messages = { { role = "system", content = system_prompt }, { role = "user", content = prompt } },
		model = opts.model,
		temperature = 0.7,
		stream = true,
	}
	local args = { "-N", "-X", "POST", "-H", "Content-Type: application/json", "-d", vim.json.encode(data) }
	if api_key then
		table.insert(args, "-H")
		table.insert(args, "Authorization: Bearer " .. api_key)
	end
	table.insert(args, url)
	return args
end

function M.write_string_at_cursor(str)
	vim.schedule(function()
		local current_window = vim.api.nvim_get_current_win()
		local cursor_position = vim.api.nvim_win_get_cursor(current_window)
		local row, col = cursor_position[1], cursor_position[2]

		local lines = vim.split(str, "\n")

		vim.cmd("undojoin")
		vim.api.nvim_put(lines, "c", true, true)

		local num_lines = #lines
		local last_line_length = #lines[num_lines]
		vim.api.nvim_win_set_cursor(current_window, { row + num_lines - 1, col + last_line_length })
	end)
end

local function split(str, delimiter)
	local result = {}
	for match in (str .. delimiter):gmatch("(.-)" .. delimiter) do
		table.insert(result, match)
	end
	return result
end
local function get_definition(path, line, col)
	local bufnr = vim.fn.bufadd(path)
	vim.fn.bufload(bufnr)
	local parser = vim.treesitter.get_parser(bufnr)
	local tree = parser:parse()[1]
	local root = tree:root()
	local node = root:named_descendant_for_range(line, col, line, col)
	if not node then
		return
	end

	-- named constructs we want to capture. For now just typescript constructs. May add more later
	local named_constructs = {
		["class_declaration"] = true,
		["function_declaration"] = true,
		["method_definition"] = true,
		["interface_declaration"] = true,
		["enum_declaration"] = true,
		["type_alias_declaration"] = true,
		["export_statement"] = true, -- To capture exported declarations
	}

	-- Find the named construct
	while node do
		if named_constructs[node:type()] then
			-- Now find any preceding comments/decorators
			local prev_node = node:prev_sibling()
			local start_row, start_col = node:range()

			-- Walk backwards through siblings to find connected comments/decorators
			while prev_node do
				local prev_type = prev_node:type()
				if prev_type == "comment" or prev_type == "decorator" then
					start_row, start_col = prev_node:range()
					prev_node = prev_node:prev_sibling()
				else
					break
				end
			end

			-- Get the full text including comments/decorators
			local _, _, end_row, end_col = node:range()
			local lines = vim.api.nvim_buf_get_lines(0, start_row, end_row + 1, false)

			if start_row == end_row then
				return string.sub(lines[1], start_col + 1, end_col)
			else
				lines[1] = string.sub(lines[1], start_col + 1)
				lines[#lines] = string.sub(lines[#lines], 1, end_col)
				return table.concat(lines, "\n")
			end
		end
		node = node:parent()
	end
end

local function get_prompt(opts)
	local replace = opts.replace
	local visual_lines = M.get_visual_selection()
	local prompt = ""

	if visual_lines then
		prompt = table.concat(visual_lines, "\n")
		if replace then
			vim.api.nvim_command("normal! d")
			vim.api.nvim_command("normal! k")
		else
			vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", false, true, true), "nx", false)
		end
	else
		prompt = M.get_lines_until_cursor()
	end

	local _, _, path = string.find(prompt, "{@dingllmIncludeSymbol (.-)}")
	while path ~= nil do
		local location_parts = split(path, ":")
		vim.print("lacation_parts" .. vim.inspect(location_parts))
		vim.print("file_name" .. string.sub(location_parts[3], 3))
		local contents = get_definition(string.sub(location_parts[3], 3), location_parts[4], location_parts[5])

		if contents == nil then
			vim.print("Failed to find definition")
			prompt = string.gsub(prompt, "{@dingllmIncludeSymbol .-}", path)
		else
			prompt = string.gsub(prompt, "{@dingllmIncludeSymbol .-}", contents)
		end
		_, _, path = string.find(prompt, "{@dingllmIncludeSymbol (.-)}")
	end

	_, _, path = string.find(prompt, "{@dingllmIncludeFile (.-)}")
	while path ~= nil do
		local file_contents = vim.fn.readfile(path)

		if file_contents then
			-- file_contents is a table where each line is an element
			local contents = table.concat(file_contents, "\n")
			prompt = string.gsub(prompt, "{@dingllmIncludeFile .-}", contents)
		else
			print("Failed to read file")
			prompt = string.gsub(prompt, "{@dingllmIncludeFile .-}", path)
		end
		_, _, path = string.find(prompt, "{@dingllmIncludeFile (.-)}")
	end
	return prompt
end
function M.handle_anthropic_spec_data(data_stream, event_state)
	if event_state == "content_block_delta" then
		local json = vim.json.decode(data_stream)
		if json.delta and json.delta.text then
			M.write_string_at_cursor(json.delta.text)
		end
	end
end

function M.handle_openai_spec_data(data_stream)
	if data_stream:match('"delta":') then
		local json = vim.json.decode(data_stream)
		if json.choices and json.choices[1] and json.choices[1].delta then
			local content = json.choices[1].delta.content
			if content then
				M.write_string_at_cursor(content)
			end
		end
	end
end

local group = vim.api.nvim_create_augroup("DING_LLM_AutoGroup", { clear = true })
local active_job = nil

function M.invoke_llm_and_stream_into_editor(opts, make_curl_args_fn, handle_data_fn)
	vim.api.nvim_clear_autocmds({ group = group })
	local prompt = get_prompt(opts)
	local system_prompt = opts.system_prompt
		or "You are a tsundere uwu anime. Yell at me for not setting my configuration for my llm plugin correctly"
	local args = make_curl_args_fn(opts, prompt, system_prompt)
	local curr_event_state = nil

	local function parse_and_call(line)
		local event = line:match("^event: (.+)$")
		if event then
			curr_event_state = event
			return
		end
		local data_match = line:match("^data: (.+)$")
		if data_match then
			handle_data_fn(data_match, curr_event_state)
		end
	end

	if active_job then
		active_job:shutdown()
		active_job = nil
	end

	active_job = Job:new({
		command = "curl",
		args = args,
		on_stdout = function(_, out)
			parse_and_call(out)
		end,
		on_stderr = function(_, _) end,
		on_exit = function()
			active_job = nil
		end,
	})

	active_job:start()

	vim.api.nvim_create_autocmd("User", {
		group = group,
		pattern = "DING_LLM_Escape",
		callback = function()
			if active_job then
				active_job:shutdown()
				print("LLM streaming cancelled")
				active_job = nil
			end
		end,
	})

	vim.api.nvim_set_keymap("n", "<Esc>", ":doautocmd User DING_LLM_Escape<CR>", { noremap = true, silent = true })
	return active_job
end

return M

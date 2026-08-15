-- The pi agent — a clean-room coding loop, in Lua, run in Luerl.
--
-- The whole agent is this file. It runs as a fenced guest: its only reach is
-- the capabilities the host granted — ask() for a model turn, file.* for the
-- workspace, sh() for a shell, sql() for its own history, require() for the
-- library. There is no Elixir in the loop; the host owns one turn (ask), the
-- guest owns the loop. That is what makes it embeddable: any Luerl with these
-- grants runs the same agent.
--
-- Four verbs, the pi set: read, write, run, done. The model calls them; the
-- agent performs them over the workspace and feeds the result back. It stops
-- when the model calls done or runs out of steps.
--
-- Usage (the host calls this): agent.run(task, max_steps) -> summary string.

local agent = {}

-- The tool schema the model is offered. Names match the verbs below.
local TOOLS = {
  { name = "read",  description = "Read a file. args: { path }" },
  { name = "write", description = "Write a file. args: { path, content }" },
  { name = "run",   description = "Run a shell line over the workspace, see its output. args: { line }" },
  { name = "done",  description = "Finish. args: { summary }" },
}

-- The system prompt is assembled from what is true now — the task and the
-- files present — never authored, so it cannot describe a workspace that
-- moved underneath it.
local function system_prompt(task)
  local files = file.list()
  local listing = "(empty)"
  if #files > 0 then
    listing = table.concat(files, ", ")
  end

  return "You are a coding agent working over a flat workspace of files.\n"
    .. "Files present: " .. listing .. "\n"
    .. "Task: " .. task .. "\n"
    .. "Work in small steps: read what you need, write files, run a shell line "
    .. "to check, and call done with a summary when the task is complete. "
    .. "Prefer one action per turn."
end

-- Perform one tool call over the workspace. Returns the observation text the
-- model sees next, plus whether it was `done`.
local function perform(call)
  local name = call.name
  local args = call.arguments or {}

  if name == "read" then
    local content = file.read(args.path)
    if content == nil then
      return "read " .. tostring(args.path) .. ": no such file", false
    end
    return "read " .. args.path .. ":\n" .. content, false
  elseif name == "write" then
    file.write(args.path, args.content or "")
    return "wrote " .. args.path .. " (" .. #(args.content or "") .. " bytes)", false
  elseif name == "run" then
    local out, rc = sh(args.line or "")
    return "ran (rc " .. tostring(rc) .. "):\n" .. out, false
  elseif name == "done" then
    return args.summary or "done", true
  else
    return name .. ": not a tool the agent has", false
  end
end

-- The loop. Ask, act on the call(s), feed the observation back, repeat until
-- the model is done or the step budget runs out.
function agent.run(task, max_steps)
  max_steps = max_steps or 12
  local messages = {
    { role = "system", content = system_prompt(task) },
    { role = "user", content = task },
  }

  local steps = 0
  while steps < max_steps do
    steps = steps + 1
    local reply = ask(messages, TOOLS)

    if reply.error ~= nil then
      -- A refused turn (rate limit, etc.): stop honestly with the reason.
      return "stopped: " .. reply.error
    end

    if reply.said ~= nil and reply.calls == nil then
      -- The model spoke instead of acting — treat plain text as the finish.
      return reply.said
    end

    -- Record the assistant's calls, perform each, feed observations back.
    table.insert(messages, { role = "assistant", content = "(tool calls)" })

    for i = 1, #reply.calls do
      local obs, finished = perform(reply.calls[i])
      table.insert(messages, { role = "tool", content = obs })
      if finished then
        return obs
      end
    end
  end

  return "stopped: reached the " .. max_steps .. "-step budget without finishing"
end

return agent

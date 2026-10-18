--# selene: allow(unused_variable)
--- HTTP over curl (vim.system), shared by services.ai and the rest module.
--- OWNER: complete. STATUS: stub (interface only).
---
--- Rules: never blocks (vim.system + vim.schedule_wrap; callbacks run on the main loop); body goes via stdin
--- (`--data-binary @-`, never argv); `--globoff`; metadata from `-w '%{json}'` (no stderr parsing);
--- optional cookie jar (`-b/-c <path>`); every request is cancellable and has a timeout.
---@class slop.http
local M = {}

---@alias slop.http.StreamMode "sse"|"ndjson"|"raw"

---@class slop.http.SseEvent
---@field event? string
---@field data string          joined `data:` lines ("[DONE]" is passed through)
---@field id? string

---@class slop.http.Request
---@field url string
---@field method? string                         default "GET" ("POST" when body is set)
---@field headers? table<string, string>|{[1]: string, [2]: string}[]  list form keeps order + duplicates
---@field query? table<string, string|number>    appended url-encoded
---@field body? string|table                     table => JSON-encoded (+ Content-Type: application/json)
---@field timeout? integer                       ms, whole request (--max-time); default 30000
---@field connect_timeout? integer               ms
---@field stream? slop.http.StreamMode           decode stdout incrementally and call on_chunk
---@field on_chunk? fun(chunk: slop.http.SseEvent|table|string, handle: slop.http.Handle)  sse | ndjson | raw
---@field on_done fun(res: slop.http.Response?, err: slop.http.Error?)  exactly once, on the main loop
---@field follow_redirects? boolean              -L (default false)
---@field max_redirs? integer
---@field cookie_jar? string                     path; enables -b/-c
---@field insecure? boolean                      -k
---@field http_version? "1.1"|"2"|"3"
---@field output? string                         write body to this file instead of memory (-o)
---@field extra_args? string[]                   appended verbatim to curl argv
---@field name? string                           label for core.log entries

---@class slop.http.Response
---@field status integer                         0 when no response (see err)
---@field headers table<string, string>          lower-cased names, last value wins
---@field header_list {[1]: string, [2]: string}[]  all headers of the final hop, in order
---@field body string                            "" when streamed or `output` set
---@field meta table                             curl -w '%{json}' (response_code, time_total, size_download,
---                                              content_type, url_effective, num_redirects, http_version, ...)
---@field json fun(self: slop.http.Response): any, string?  decode body

---@class slop.http.Error
---@field kind "timeout"|"cancelled"|"curl"|"http"|"spawn"|"decode"
---@field message string
---@field code? integer                          curl exit code or HTTP status
---@field response? slop.http.Response           for kind = "http" (status >= 400)

---@class slop.http.Handle
---@field id integer
---@field cancel fun(self: slop.http.Handle)      kills curl; on_done gets {kind="cancelled"}
---@field is_active fun(self: slop.http.Handle): boolean

--- Start a request. Status >= 400 is reported as err.kind = "http" with err.response set.
---@param opts slop.http.Request
---@return slop.http.Handle
function M.request(opts)
  error("slop: core.http.request not implemented yet", 2)
end

--- Low-level: run curl with raw args (used by request() and by rest's runner).
---@param args string[]                          curl arguments (without "curl")
---@param opts {stdin?: string, timeout?: integer, on_stdout?: fun(data: string), on_exit: fun(code: integer, stdout: string, stderr: string)}
---@return slop.http.Handle
function M.curl(args, opts)
  error("slop: core.http.curl not implemented yet", 2)
end

--- Pure: curl argv + stdin for a request (tests, "copy as curl").
---@param opts slop.http.Request
---@return string[] args, string? stdin
function M.build_args(opts)
  error("slop: core.http.build_args not implemented yet", 2)
end

--- Pure incremental decoders: feed raw stdout data, get callbacks per complete event/object/chunk.
---@param on_event fun(ev: slop.http.SseEvent)
---@return fun(data: string)
function M.sse_decoder(on_event)
  error("slop: core.http.sse_decoder not implemented yet", 2)
end

---@param on_obj fun(obj: table)
---@return fun(data: string)
function M.ndjson_decoder(on_obj)
  error("slop: core.http.ndjson_decoder not implemented yet", 2)
end

return M

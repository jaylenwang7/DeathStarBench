local _M = {}
local k8s_suffix = os.getenv("fqdn_suffix")
if (k8s_suffix == nil) then
  k8s_suffix = ""
end

local function _StrIsEmpty(s)
  return s == nil or s == ''
end

-- Add safe number conversion
local function _SafeNumber(s, default)
  if s == nil then return default end
  local n = tonumber(s)
  if n == nil then return default end
  return n
end

-- Add safe JSON decode
local function _SafeJSONDecode(s, default)
  if _StrIsEmpty(s) then return default end
  local status, result = pcall(require("cjson").decode, s)
  if not status then return default end
  return result
end

function _M.ComposePost()
  local bridge_tracer = require "opentracing_bridge_tracer"
  local ngx = ngx
  local cjson = require "cjson"

  local GenericObjectPool = require "GenericObjectPool"
  local social_network_ComposePostService = require "social_network_ComposePostService"
  local ComposePostServiceClient = social_network_ComposePostService.ComposePostServiceClient

  GenericObjectPool:setMaxTotal(512)

  local req_id = tonumber(string.sub(ngx.var.request_id, 0, 15), 16)
  local tracer = bridge_tracer.new_from_global()
  local parent_span_context = tracer:binary_extract(ngx.var.opentracing_binary_context)
  local span = nil  -- Declare span early for proper error handling

  ngx.req.read_body()
  local post = ngx.req.get_post_args()

  -- Input validation
  if (_StrIsEmpty(post.user_id) or _StrIsEmpty(post.username) or
      _StrIsEmpty(post.post_type) or _StrIsEmpty(post.text)) then
    ngx.status = ngx.HTTP_BAD_REQUEST
    ngx.say("Incomplete arguments")
    ngx.log(ngx.ERR, "Incomplete arguments")
    ngx.exit(ngx.HTTP_BAD_REQUEST)
  end

  -- Safe number conversions
  local user_id = _SafeNumber(post.user_id)
  local post_type = _SafeNumber(post.post_type)
  
  if not user_id or not post_type then
    ngx.status = ngx.HTTP_BAD_REQUEST
    ngx.say("Invalid numeric arguments")
    ngx.log(ngx.ERR, "Invalid numeric arguments")
    ngx.exit(ngx.HTTP_BAD_REQUEST)
  end

  -- Get client connection with error handling
  local status, client = pcall(GenericObjectPool.connection, GenericObjectPool,
      ComposePostServiceClient, "compose-post-service" .. k8s_suffix, 9090)
  
  if not status then
    ngx.status = ngx.HTTP_INTERNAL_SERVER_ERROR
    ngx.say("Failed to get client connection")
    ngx.log(ngx.ERR, "Failed to get client connection: " .. tostring(client))
    ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
  end

  -- Start span after successful connection
  span = tracer:start_span("compose_post_client",
      { ["references"] = { { "child_of", parent_span_context } } })
  local carrier = {}
  tracer:text_map_inject(span:context(), carrier)

  -- Safe handling of media parameters
  local media_ids = _SafeJSONDecode(post.media_ids, {})
  local media_types = _SafeJSONDecode(post.media_types, {})

  -- Execute post composition
  status, ret = pcall(client.ComposePost, client,
      req_id, post.username, user_id, post.text,
      media_ids, media_types, post_type, carrier)

  -- Always return connection to pool, even on error
  GenericObjectPool:returnConnection(client)

  if not status then
    ngx.status = ngx.HTTP_INTERNAL_SERVER_ERROR
    local error_msg = (ret.message and ret.message or tostring(ret))
    ngx.say("compose_post failure: " .. error_msg)  -- Fixed typo in error message
    ngx.log(ngx.ERR, "compose_post failure: " .. error_msg)
    if span then span:finish() end
    ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
  end

  -- Success response
  ngx.status = ngx.HTTP_OK
  ngx.say("Successfully upload post")
  if span then span:finish() end
  ngx.exit(ngx.status)
end

return _M
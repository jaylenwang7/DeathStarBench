local _M = {}
local k8s_suffix = os.getenv("fqdn_suffix")
if (k8s_suffix == nil) then
  k8s_suffix = ""
end

local function _StrIsEmpty(s)
  return s == nil or s == ''
end

local function _UploadUserId(req_id, post, carrier)
  local GenericObjectPool = require "GenericObjectPool"
  local UserServiceClient = require 'media_service_UserService'
  local user_client = GenericObjectPool:connection(
    UserServiceClient,"user-service" .. k8s_suffix,9090)
  
  local status, err = pcall(function()
    user_client:UploadUserWithUsername(req_id, post.username, carrier)
  end)
  
  GenericObjectPool:returnConnection(user_client)
  
  if not status then
    ngx.log(ngx.ERR, "Failed to upload user ID: " .. tostring(err))
    return false, err
  end
  
  return true
end

local function _UploadText(req_id, post, carrier)
  local GenericObjectPool = require "GenericObjectPool"
  local TextServiceClient = require 'media_service_TextService'
  local text_client = GenericObjectPool:connection(
    TextServiceClient,"text-service" .. k8s_suffix ,9090)
  
  local status, err = pcall(function()
    text_client:UploadText(req_id, post.text, carrier)
  end)
  
  GenericObjectPool:returnConnection(text_client)
  
  if not status then
    ngx.log(ngx.ERR, "Failed to upload text: " .. tostring(err))
    return false, err
  end
  
  return true
end

local function _UploadMovieId(req_id, post, carrier)
  local GenericObjectPool = require "GenericObjectPool"
  local MovieIdServiceClient = require 'media_service_MovieIdService'
  local movie_id_client = GenericObjectPool:connection(
    MovieIdServiceClient,"movie-id-service" .. k8s_suffix ,9090)
  
  local status, err = pcall(function()
    movie_id_client:UploadMovieId(req_id, post.title, tonumber(post.rating), carrier)
  end)
  
  GenericObjectPool:returnConnection(movie_id_client)
  
  if not status then
    ngx.log(ngx.ERR, "Failed to upload movie ID: " .. tostring(err))
    return false, err
  end
  
  return true
end

local function _UploadUniqueId(req_id, carrier)
  local GenericObjectPool = require "GenericObjectPool"
  local UniqueIdServiceClient = require 'media_service_UniqueIdService'
  local unique_id_client = GenericObjectPool:connection(
    UniqueIdServiceClient,"unique-id-service" .. k8s_suffix ,9090)
  
  local status, err = pcall(function()
    unique_id_client:UploadUniqueId(req_id, carrier)
  end)
  
  GenericObjectPool:returnConnection(unique_id_client)
  
  if not status then
    ngx.log(ngx.ERR, "Failed to upload unique ID: " .. tostring(err))
    return false, err
  end
  
  return true
end

function _M.ComposeReview()
  local bridge_tracer = require "opentracing_bridge_tracer"
  local ngx = ngx

  local req_id = tonumber(string.sub(ngx.var.request_id, 0, 15), 16)
  local tracer = bridge_tracer.new_from_global()
  local parent_span_context = tracer:binary_extract(ngx.var.opentracing_binary_context)
  local span = tracer:start_span("ComposeReview", {["references"] = {{"child_of", parent_span_context}}})
  local carrier = {}
  tracer:text_map_inject(span:context(), carrier)

  ngx.req.read_body()
  local post = ngx.req.get_post_args()

  if (_StrIsEmpty(post.title) or _StrIsEmpty(post.text) or
      _StrIsEmpty(post.username) or _StrIsEmpty(post.password) or
      _StrIsEmpty(post.rating)) then
    ngx.status = ngx.HTTP_BAD_REQUEST
    ngx.say("Incomplete arguments")
    ngx.log(ngx.ERR, "Incomplete arguments")
    ngx.exit(ngx.HTTP_BAD_REQUEST)
  end

  local threads = {
    ngx.thread.spawn(_UploadUserId, req_id, post, carrier),
    ngx.thread.spawn(_UploadMovieId, req_id, post, carrier),
    ngx.thread.spawn(_UploadText, req_id, post, carrier),
    ngx.thread.spawn(_UploadUniqueId, req_id, carrier)
  }

  local status = ngx.HTTP_OK
  for i = 1, #threads do
    local ok, res = ngx.thread.wait(threads[i])
    if not ok then
      status = ngx.HTTP_INTERNAL_SERVER_ERROR
    end
  end
  span:finish()
  ngx.exit(status)

end

return _M
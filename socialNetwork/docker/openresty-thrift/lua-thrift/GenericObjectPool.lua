local Object = require 'Object'
local RpcClientFactory = require 'RpcClientFactory'
local ngx = ngx

local GenericObjectPool = Object:new({
    __type = 'GenericObjectPool',
    maxTotal = 100,
    maxIdleTime = 10000,
    timeout = 10000
})

function GenericObjectPool:init(conf)
    if conf then
        if conf.maxTotal then self:setMaxTotal(conf.maxTotal) end
        if conf.maxIdleTime then self:setMaxIdleTime(conf.maxIdleTime) end
        if conf.timeout then self:setTimeout(conf.timeout) end
    end
end

function GenericObjectPool:connection(thriftClient,ip,port)
    -- Maintain original single-value return for compatibility
    local ssl = ngx.shared.config:get("ssl")
    
    -- Safe creation but maintain original return signature
    local ok, client = pcall(function()
        return RpcClientFactory:createClient(thriftClient,ip,port,self.timeout,ssl)
    end)
    
    if not ok then
        ngx.log(ngx.ERR, "Failed to create client: " .. tostring(client))
        return nil  -- Original behavior would return nil on failure
    end
    
    return client
end

function GenericObjectPool:returnConnection(client)
    if not client then return end
    
    -- Safe navigation
    if client.iprot and client.iprot.trans and client.iprot.trans.trans then
        if client.iprot.trans.trans:isOpen() then
            -- Maintain original behavior but add error logging
            local ok, err = pcall(function()
                client.iprot.trans.trans:setKeepAlive(self.maxIdleTime, self.maxTotal)
            end)
            if not ok then
                ngx.log(ngx.ERR, "Failed to set keepalive: " .. tostring(err))
            end
        else
            ngx.log(ngx.ERR, "return rpc client fail, socket close.")
        end
    end
end

function GenericObjectPool:setMaxIdleTime(maxIdleTime)
    if type(maxIdleTime) == "number" and maxIdleTime > 0 then
        self.maxIdleTime = maxIdleTime
    else
        ngx.log(ngx.ERR, "Invalid maxIdleTime value")
    end
end

function GenericObjectPool:setMaxTotal(maxTotal)
    if type(maxTotal) == "number" and maxTotal > 0 then
        self.maxTotal = maxTotal
    else
        ngx.log(ngx.ERR, "Invalid maxTotal value")
    end
end

function GenericObjectPool:setTimeout(timeout)
    if type(timeout) == "number" and timeout > 0 then
        self.timeout = timeout
    else
        ngx.log(ngx.ERR, "Invalid timeout value")
    end
end

function GenericObjectPool:clear()
end

function GenericObjectPool:remove()
end

-- Add new monitoring methods that won't affect existing code
function GenericObjectPool:_getStats()
    return {
        maxTotal = self.maxTotal,
        maxIdleTime = self.maxIdleTime,
        timeout = self.timeout
    }
end

return GenericObjectPool
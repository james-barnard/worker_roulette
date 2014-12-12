module WorkerRoulette
  class Lua
    Thread.main[:worker_roulette_lua_script_cache] = Hash.new

    def initialize(connection_pool)
      @connection_pool = connection_pool
    end

    def call(lua_script, keys_accessed = [], args = [], &callback)
      @connection_pool.with do |redis|
        evalsha(redis, lua_script, keys_accessed, args, &callback)
      end
    end

    def sha(lua_script)
      Thread.main[:worker_roulette_lua_script_cache][lua_script] ||= Digest::SHA1.hexdigest(lua_script)
    end

    def cache
      Thread.main[:worker_roulette_lua_script_cache].dup
    end

    def clear_cache!
      Thread.main[:worker_roulette_lua_script_cache] = {}
    end

    def eval(redis, lua_script, keys_accessed, args, &callback)
      results = redis.eval(lua_script, keys_accessed.length, *keys_accessed, *args)
      results.callback(&callback) if callback
      results.errback  {|err_msg| byebug; raise EM::Hiredis::RedisError.new(err_msg)}
    end

    def evalsha(redis, lua_script, keys_accessed, args, &callback)
      if redis.class == EM::Hiredis::Client
        results = redis.evalsha(sha(lua_script), keys_accessed.length, *keys_accessed, *args)
        results.callback(&callback) if callback
        results.errback {eval(redis, lua_script, keys_accessed, args, &callback)}
      else
        begin
          results = redis.evalsha(sha(lua_script), keys_accessed, args)
        rescue Redis::CommandError
          results = redis.eval(lua_script, keys_accessed, args)
        ensure
          return callback.call results if callback
        end
      end
      results
    end
  end
end

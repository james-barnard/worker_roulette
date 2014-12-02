module WorkerRoulette
  class Foreman

    LUA_ENQUEUE_WORK_ORDER = <<-HERE
      local counter_key       = KEYS[1]
      local job_board_key     = KEYS[2]
      local sender_key        = KEYS[3]

      local redis_call        = redis.call
      local zscore            = 'ZSCORE'
      local incr              = 'INCR'
      local zadd              = 'ZADD'

      local function enqueue_work_order()

        -- add sender_id to fifo job_board if not already there
        if (redis_call(zscore, job_board_key, sender_key) == false) then
          local count = redis_call(incr, counter_key)
          redis_call(zadd, job_board_key, count, sender_key)
        end
      end

      enqueue_work_order()
    HERE

    attr_reader :sender, :namespace

    def initialize(redis_pool, sender, namespace = nil)
      @sender     = sender
      @redis_pool = redis_pool
      @namespace  = namespace || WorkerRoulette::JOB_NOTIFICATIONS
      @lua        = Lua.new(@redis_pool)
    end

    def enqueue_work_order(work_order, header = {}, &callback)
      work_order = {'headers' => default_header.merge(header), 'payload' => work_order}
      enqueue(WorkerRoulette.dump(work_order), &callback)
    end

    def enqueue(work_order, &callback)
      NexiaMessageQueue.new(sender_key).send(work_order) do
        add_to_job_board(&callback)
      end
    end

    def add_to_job_board(&callback)
      @lua.call(LUA_ENQUEUE_WORK_ORDER, [counter_key, job_board_key, sender_key], [], &callback)
    end

    def job_board_key
      @job_board_key ||= WorkerRoulette.job_board_key(namespace)
    end

    def counter_key
      @counter_key ||= WorkerRoulette.counter_key(namespace)
    end

    def sender_key
      @sender_key ||= WorkerRoulette.sender_key(sender, namespace)
    end

    private

    def default_header
      { 'sender' => sender }
    end

  end
end

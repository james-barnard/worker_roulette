require 'posix/mqueue'

module WorkerRoulette
  class NexiaMessageQueue
    def initialize(sender_key=nil)
      puts "MessageQueue:sender_key: (#{sender_key})"
      fail "MessageQueue: sender_key is required" if sender_key.to_s == ""
      @sender_key = sender_key
    end

    def send(message, &block)
      queue.timedsend(message)
      block.call(@sender_key) if block
    rescue POSIX::Mqueue::QueueFull
      puts "MessageQueue: queue full"
    end

    def drain
      messages = fetch_all
      drop

      messages
    end

    def fetch_all
      messages = []
      while true
        begin
          messages << queue.timedreceive
        rescue POSIX::Mqueue::QueueEmpty
          break
        end
      end
      messages
    end

    def drop
      queue.unlink
      close
    end

    def close
      queue.close
    end

    private

    def queue
      @queue ||= POSIX::Mqueue.new("/#{@sender_key}", msgsize: 4096, maxmsg: 10)
    end

  end
end

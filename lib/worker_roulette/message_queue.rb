require 'posix/mqueue'

module WorkerRoulette
  class MessageQueue
    def initialize(sender_key)
      @queue_name = "/#{sender_key}"
    end

    def send(message)
      queue.timedwrite(message)
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
    end

    private

    def queue
      @queue ||= POSIX::Mqueue.new(@queue_name)
    end

  end
end

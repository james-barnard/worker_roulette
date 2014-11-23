require "spec_helper"
module WorkerRoulette
  class Tradesman
    attr_reader :lua
  end

  describe WorkerRoulette do
    let(:sender) {'katie_80'}
    let(:work_orders) {["hello", "foreman"]}
    let(:default_headers) {Hash['headers' => {'sender' => sender}]}
    let(:hello_work_order) {Hash['payload' => "hello"]}
    let(:foreman_work_order) {Hash['payload' => "foreman"]}
    let(:work_orders_with_headers) {default_headers.merge({'payload' => work_orders})}
    let(:jsonized_work_orders_with_headers) {[WorkerRoulette.dump(work_orders_with_headers)]}
    let(:worker_roulette) { WorkerRoulette.start }
    let(:redis) {Redis.new(worker_roulette.redis_config)}

    before do
      redis.flushall
    end

    it "exists" do
      expect(worker_roulette).to be_instance_of(WorkerRoulette)
    end

    context Foreman do
      let(:foreman) {worker_roulette.foreman(sender)}
      let(:other_forman) { worker_roulette.foreman('other_forman') }

      it "works on behalf of a sender" do
        expect(foreman.sender).to eq(sender)
      end

      xit "enqueues two work_orders in the sender's work queue" do
        foreman.enqueue_work_order(work_orders.first) {}
        foreman.enqueue_work_order(work_orders.last) {}
        expect(redis.lrange(sender, 0, -1)).to eq(work_orders.map {|m| WorkerRoulette.dump(default_headers.merge({'payload' => m})) })
      end

      xit "enqueues an array of work_orders without headers in the sender's work queue" do
        foreman.enqueue_work_order_without_headers(work_orders)
        expect(redis.lrange(sender, 0, -1)).to eq([WorkerRoulette.dump(work_orders)])
      end

      xit "enqueues an array of work_orders with default headers in the sender's work queue" do
        foreman.enqueue_work_order(work_orders)
        expect(redis.lrange(sender, 0, -1)).to eq(jsonized_work_orders_with_headers)
      end

      xit "enqueues an array of work_orders with additional headers in the sender's work queue" do
        extra_headers = {'foo' => 'bars'}
        foreman.enqueue_work_order(work_orders, extra_headers)
        work_orders_with_headers['headers'].merge!(extra_headers)
        expect(redis.lrange(sender, 0, -1)).to eq([WorkerRoulette.dump(work_orders_with_headers)])
      end

      xit "posts the sender's id to the job board with an order number" do
        foreman.enqueue_work_order(work_orders.first)
        worker_roulette.foreman('other_forman').enqueue_work_order(work_orders.last)
        expect(redis.zrange(foreman.job_board_key, 0, -1, with_scores: true)).to eq([[sender, 1.0], ["other_forman", 2.0]])
      end

      it "counter_key increases by one only for first introduction of foreman to job board" do
        expect(redis.get(foreman.counter_key)).to be_nil
        foreman.enqueue_work_order(work_orders.first)
        expect(redis.get(foreman.counter_key)).to eq("1")
        foreman.enqueue_work_order(work_orders.last)
        expect(redis.get(foreman.counter_key)).to eq("1")
        other_forman.enqueue_work_order(work_orders.last)
        expect(redis.get(other_forman.counter_key)).to eq("2")
      end
    end

    context Tradesman do
      let(:foreman)   { worker_roulette.foreman(sender) }
      let(:tradesman) { worker_roulette.tradesman }

      before do
        foreman.enqueue_work_order(work_orders)
      end

      context 'removing locks from queues' do
        it "for the last_sender's queue" do
          most_recent_sender = 'most_recent_sender'
          most_recent_foreman = worker_roulette.foreman(most_recent_sender)
          most_recent_foreman.enqueue_work_order(work_orders)
          expect(redis.keys("L*:*").length).to eq(0)
          tradesman.work_orders!
          expect(redis.get("L*:katie_80")).to eq("1")
          expect(redis.keys("L*:*").length).to eq(1)
          tradesman.work_orders!
          expect(redis.keys("L*:*").length).to eq(1)
          expect(redis.get("L*:most_recent_sender")).to eq("1")
          tradesman.work_orders!
          expect(redis.keys("L*:*").length).to eq(0)
        end
      end

      it "has a last sender if it found messages" do
        expect(tradesman.work_orders!.length).to eq(1)
        expect(tradesman.last_sender).to eq(sender)
      end

      it "does not have a last sender if it found no messages" do
        expect(tradesman.work_orders!.length).to eq(1)
        expect(tradesman.work_orders!.length).to eq(0)
        expect(tradesman.last_sender).to be_nil
      end

      it "drains one set of work_orders from the sender's work queue" do
        expect(tradesman.work_orders!).to eq([work_orders_with_headers])
        expect(tradesman.work_orders!).to be_empty
        expect(tradesman.work_orders!).to be_empty #does not throw an error if queue is already empty
      end

      it "drains all the work_orders from the sender's work queue" do
        foreman.enqueue_work_order(work_orders)
        expect(tradesman.work_orders!).to eq([work_orders_with_headers, work_orders_with_headers])
        expect(tradesman.work_orders!).to be_empty
        expect(tradesman.work_orders!).to be_empty #does not throw an error if queue is already empty
      end

      it "takes the oldest sender off the job board (FIFO)" do
        oldest_sender = sender.to_s
        most_recent_sender = 'most_recent_sender'
        most_recent_foreman = worker_roulette.foreman(most_recent_sender)
        most_recent_foreman.enqueue_work_order(work_orders)
        expect(redis.zrange(tradesman.job_board_key, 0, -1)).to eq([oldest_sender, most_recent_sender])
        tradesman.work_orders!
        expect(redis.zrange(tradesman.job_board_key, 0, -1)).to eq([most_recent_sender])
      end

      it "gets the work_orders from the next queue when a new job is ready, then poll for new work" do
        tradesman.wait_for_work_orders do |redis_work_orders|
          expect(redis_work_orders).to eq([work_orders_with_headers])
          expect(tradesman.last_sender).to eq('katie_80')
          allow(tradesman).to receive(:wait_for_work_orders)
        end
      end

      it "publishes and subscribes on custom channels" do
        tradesman         = worker_roulette.tradesman('good_channel')
        expect(tradesman).to receive(:work_orders!).and_call_original

        good_foreman      = worker_roulette.foreman('foreman', 'good_channel')
        bad_foreman       = worker_roulette.foreman('foreman', 'bad_channel')

        good_foreman.enqueue_work_order('some old fashion work')
        bad_foreman.enqueue_work_order('evil biddings you should not carry out')

        tradesman.wait_for_work_orders do |work|
          expect(work.to_s).to match("some old fashion work")
          expect(work.to_s).not_to match("evil")
          expect(tradesman.last_sender).to eq('foreman')
          allow(tradesman).to receive(:wait_for_work_orders)
        end
      end

      it "goes back to the channel to get more work for the same sender" do
        tradesman.wait_for_work_orders do |redis_work_orders|
          expect(redis_work_orders).to eq([work_orders_with_headers])
          expect(tradesman.last_sender).to eq('katie_80')
          allow(tradesman).to receive(:wait_for_work_orders)
        end

        expect(tradesman.lua).to receive(:call).with(Tradesman::LUA_DRAIN_WORK_ORDERS_FOR_SENDER, [instance_of(String), sender])
        tradesman.get_more_work_for_last_sender do |redis_work_orders|
          expect(redis_work_orders).to eq([])
        end

        foreman.enqueue_work_order("more_work_orders")
        expect(tradesman.lua).to receive(:call).with(Tradesman::LUA_DRAIN_WORK_ORDERS_FOR_SENDER, [instance_of(String), sender])
        tradesman.get_more_work_for_last_sender do |redis_work_orders|
          expect(redis_work_orders).to eq(["more_work_orders"])
        end

      end

      context "Concurrent Access" do
        it "pools its connections" do
          Array.new(100) do
            Thread.new {worker_roulette.tradesman_connection_pool.with {|pooled_redis| pooled_redis.get("foo")}}
          end.each(&:join)
          worker_roulette.tradesman_connection_pool.with do |pooled_redis|
            expect(pooled_redis.info["connected_clients"].to_i).to be > (worker_roulette.pool_size)
          end
        end
      end
    end
  end
end

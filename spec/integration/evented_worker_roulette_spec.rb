require "spec_helper"
module WorkerRoulette
  describe WorkerRoulette do
    include EventedSpec::EMSpec

    let(:sender) { 'katie_80' }
    let(:work_orders) { ["hello", "foreman"] }
    let(:default_headers) { { 'sender' => sender } }
    let(:extra_headers) { {} }
    let(:all_the_headers) { default_headers.merge(extra_headers) }
    let(:hello_work_order) { Hash['payload' => "hello"] }
    let(:foreman_work_order) { Hash['payload' => "foreman"] }
    let(:work_orders_with_headers) { { 'headers' => all_the_headers, 'payload' => work_orders } }
    let(:worker_roulette) {  WorkerRoulette.start(evented: true)  }
    let(:redis) { Redis.new(worker_roulette.redis_config) }

    before do
      redis.flushall
      NexiaMessageQueue.new("bad_channel:foreman").drain
      NexiaMessageQueue.new("good_channel:foreman").drain
      NexiaMessageQueue.new("new_job_ready:katie_80").drain
      NexiaMessageQueue.new("new_job_ready:foreman").drain
      NexiaMessageQueue.new("new_job_ready:recent_sender").drain
      NexiaMessageQueue.new("new_job_ready:other_foreman").drain
      NexiaMessageQueue.new("good_channel:good_foreman").drain
      NexiaMessageQueue.new("good_channel:lazy_foreman").drain
    end

    context "Evented Foreman" do
      subject(:foreman) { worker_roulette.foreman(sender) }
      let(:tradesman)   { worker_roulette.tradesman(nil, 0.01) }

      it "enqueues an array of work_orders with default headers in the sender's slot in the job board" do
        foreman.enqueue_work_order(work_orders) do
          tradesman.work_orders! do |work|
            expect(work).to eq([work_orders_with_headers])
          done { foreman.shutdown }
          end
        end
      end

      it "calls the block given when enqueue_work_order succeeds" do
        called = false
        foreman = worker_roulette.foreman('foreman')
        foreman.enqueue_work_order('some old fashion work') do |redis_response, stuff|
          called = true
          done(0.1) do
            expect(called).to be_truthy
            foreman.shutdown
          end
        end
      end

      it "enqueues an array of work_orders without headers in the sender's slot in the job board" do
        foreman.enqueue(WorkerRoulette.dump(work_orders)) do
          tradesman.work_orders! do |work|
            expect(work).to eq([work_orders])
          done { foreman.shutdown }
          end

        end
      end

      context "with additional headers" do
        let(:extra_headers) { {'foo' => 'bars'} }

        it "enqueues an array of work_orders with additional headers in the sender's slot in the job board" do
          foreman.enqueue_work_order(work_orders, extra_headers) do
            tradesman.work_orders! do |work|
              expect(work).to eq([work_orders_with_headers])
            done { foreman.shutdown }
            end

          end
          foreman.shutdown
        end
      end

      it "posts the sender's id to the job board with an order number" do
        other_foreman = worker_roulette.foreman('other_foreman')

        other_foreman.enqueue_work_order('foo') do
          foreman.enqueue_work_order(work_orders.first) do
            foreman.enqueue_work_order(work_orders.last) do
              expect(redis.zrange(foreman.job_board_key, 0, -1, with_scores: true)).to eq([["new_job_ready:other_foreman", 1.0], ["new_job_ready:#{sender}", 2.0]])

              done { foreman.shutdown; other_foreman.shutdown }
            end
          end
        end
      end

      it "counter_key increases by one only for first introduction of foreman to job board" do
        other_foreman = worker_roulette.foreman('other_foreman')

        expect(redis.get(foreman.counter_key)).to be_nil

        other_foreman.enqueue_work_order(work_orders.first) do
          expect(redis.get(foreman.counter_key)).to eq("1")
          other_foreman.enqueue_work_order(work_orders.last) do
            expect(redis.get(foreman.counter_key)).to eq("1")
            foreman.enqueue_work_order(work_orders.first) do
              expect(redis.get(foreman.counter_key)).to eq("2")
              done { foreman.shutdown; other_foreman.shutdown }
            end
          end
        end
      end
    end

    context "Evented Tradesman" do
      let(:foreman)   { worker_roulette.foreman(sender) }
      let(:tradesman) { worker_roulette.tradesman(nil, 0.01) }

      it "works on behalf of a sender" do
        foreman.enqueue_work_order(work_orders) do
          tradesman.work_orders! do |r|
            expect(tradesman.last_sender).to eq("new_job_ready:#{sender}")
            done { foreman.shutdown }
          end
        end
      end

      it "removes the lock from the last_sender's queue" do
        recent_sender = 'recent_sender'
        recent_foreman = worker_roulette.foreman(recent_sender)

        foreman.enqueue_work_order(work_orders) do
          recent_foreman.enqueue_work_order(work_orders) do
            expect(redis.keys("L*:*").length).to eq(0)
            tradesman.work_orders! do
              expect(redis.get("L*:new_job_ready:#{sender}")).to eq("1")
              expect(redis.keys("L*:*").length).to eq(1)
              tradesman.work_orders! do
                expect(redis.keys("L*:*").length).to eq(1)
                expect(redis.get("L*:new_job_ready:recent_sender")).to eq("1")
                tradesman.work_orders!
                done(0.2) do
                  expect(redis.keys("L*:*").length).to eq(0)
                  foreman.shutdown
                  recent_foreman.shutdown
                end
              end
            end
          end
        end
      end

      it "drains one set of work_orders from the sender's slot in the job board" do
        foreman.enqueue_work_order(work_orders) do
          tradesman.work_orders! do |r|
            expect(r).to eq([work_orders_with_headers])
            tradesman.work_orders! do |q|
              expect(q).to be_empty
              done(0.2)
            end
          end
        end
        foreman.shutdown
      end

      it "takes the oldest sender off the job board (FIFO)" do
        oldest_sender = sender
        recent_sender = 'recent_sender'
        recent_foreman = worker_roulette.foreman(recent_sender)

        foreman.enqueue_work_order(work_orders) do
          recent_foreman.enqueue_work_order(work_orders) do
            expect(redis.zrange(tradesman.job_board_key, 0, -1)).to eq(["new_job_ready:#{oldest_sender}", "new_job_ready:#{recent_sender}"])
            tradesman.work_orders! do
              expect(redis.zrange(tradesman.job_board_key, 0, -1)).to eq(["new_job_ready:#{recent_sender}"])
              done do
                foreman.shutdown
                recent_foreman.shutdown
              end
            end
          end
        end
      end

      it "gets the work_orders from the next queue when a new job is ready" do
        # tradesman polls every so often, we care that it is called at least twice, but did not use
        # the built in rspec syntax for that bc if the test ends while we're talking to redis, redis
        # throws an Error. This way we ensure we call work_orders! at least twice and just stub the second
        # call so as not to hurt redis' feelings.

        expect(tradesman).to receive(:work_orders!).and_call_original
        expect(tradesman).to receive(:work_orders!)

        foreman.enqueue_work_order(work_orders) do
          tradesman.wait_for_work_orders do |redis_work_orders|
            expect(redis_work_orders).to eq([work_orders_with_headers])
            expect(tradesman.last_sender).to match(/new_job_ready:katie_80/)
            done(0.1) { foreman.shutdown }
          end
        end
      end

      it "publishes and subscribes on custom channels" do
        tradesman      = worker_roulette.tradesman('good_channel', 0.001)
        evil_tradesman = worker_roulette.tradesman('bad_channel', 0.001)

        good_foreman   = worker_roulette.foreman('foreman', 'good_channel')
        bad_foreman    = worker_roulette.foreman('foreman', 'bad_channel')

        # tradesman polls every so often, we care that it is called at least twice, but did not use
        # the built in rspec syntax for that bc if the test ends while we're talking to redis, redis
        # throws an Error. This way we ensure we call work_orders! at least twice and just stub the second
        # call so as not to hurt redis' feelings.
        expect(tradesman).to receive(:work_orders!).and_call_original
        expect(tradesman).to receive(:work_orders!)

        expect(evil_tradesman).to receive(:work_orders!).and_call_original
        expect(evil_tradesman).to receive(:work_orders!)

        good_foreman.enqueue_work_order('some old fashion work') do
          bad_foreman.enqueue_work_order('evil biddings') do

            tradesman.wait_for_work_orders do |good_work|
              expect(good_work.to_s).to match("old fashion")
              expect(good_work.to_s).not_to match("evil")
            end

            evil_tradesman.wait_for_work_orders do |bad_work|
              expect(bad_work.to_s).not_to match("old fashion")
              expect(bad_work.to_s).to match("evil")
            end
            done(0.1) do
              good_foreman.shutdown
              bad_foreman.shutdown
            end
          end
        end
      end

      it "pulls off work orders for more than one sender" do
        tradesman = worker_roulette.tradesman('good_channel')

        good_foreman = worker_roulette.foreman('good_foreman', 'good_channel')
        lazy_foreman = worker_roulette.foreman('lazy_foreman', 'good_channel')

        got_good = false
        got_lazy = false
        good_foreman.enqueue_work_order('do good work') do
          tradesman.work_orders! do |r|
            got_good = true
            expect(r.first['payload']).to eq('do good work')
          end
        end
        lazy_foreman.enqueue_work_order('just get it done') do
          tradesman.work_orders! do |r|
            got_lazy = true
            expect(r.first['payload']).to eq('just get it done')
          end
        end

        done(0.2) do
          expect(got_good && got_lazy).to eq(true)
          good_foreman.shutdown
          lazy_foreman.shutdown
        end
      end
    end

  end
end

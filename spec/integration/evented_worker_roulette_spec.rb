require "spec_helper"
module WorkerRoulette
  describe WorkerRoulette do
    include EventedSpec::EMSpec

    let(:sender) { 'katie_80' }
    let(:work_orders) { ["hello", "foreman"] }
    let(:default_headers) { Hash['headers' => { 'sender' => sender }] }
    let(:hello_work_order) { Hash['payload' => "hello"] }
    let(:foreman_work_order) { Hash['payload' => "foreman"] }
    let(:work_orders_with_headers) { default_headers.merge({ 'payload' => work_orders }) }
    let(:jsonized_work_orders_with_headers) { [WorkerRoulette.dump(work_orders_with_headers)] }
    let(:worker_roulette) {  WorkerRoulette.start(evented: true)  }
    let(:redis) { Redis.new(worker_roulette.redis_config) }

    context "Evented Foreman" do
      subject(:foreman) { worker_roulette.foreman(sender) }
      let(:tradesman)   { worker_roulette.tradesman(nil, 0.01) }

      it "calls the block given when enqueue_work_order succeeds" do
        called = false
        foreman = worker_roulette.foreman('foreman')
        foreman.enqueue_work_order('some old fashion work') do |redis_response, stuff|
          called = true
        end

        done(0.1) { expect(called).to be_truthy }
      end

      it "enqueues an array of work_orders without headers in the sender's slot in the job board" do
        foreman.enqueue_work_order_without_headers(work_orders) do
          tradesman.work_orders! do |work|
            expect(work).to eq([WorkerRoulette.dump(work_orders)])
          end

          done
        end
      end

      it "enqueues an array of work_orders with default headers in the sender's slot in the job board" do
        foreman.enqueue_work_order(work_orders) do
          tradesman.work_orders! do |work|
            expect(work).to eq(jsonized_work_orders_with_headers)
          end

          done
        end
      end

      it "enqueues an array of work_orders with additional headers in the sender's slot in the job board" do
        let(:extra_headers) { {'foo' => 'bars'} }
        work_orders_with_headers['headers'].merge!(extra_headers)

        foreman.enqueue_work_order(work_orders, extra_headers) do
          tradesman.work_orders! do |work|
            expect(work).to eq([WorkerRoulette.dump(work_orders_with_headers)])
          end

          done
        end
      end

      it "posts the sender's id to the job board with an order number" do
        let(:other_foreman) { worker_roulette.foreman('other_foreman') }

        other_foreman.enqueue_work_order('foo') do
          foreman.enqueue_work_order(work_orders.other) do
            foreman.enqueue_work_order(work_orders.last) do
              expect(redis.zrange(foreman.job_board_key, 0, -1, with_scores: true)).to eq([["other_foreman", 1.0], ["#{sender}", 2.0]])

              done
            end
          end
        end
      end

      it "counter_key increases by one only for first introduction of foreman to job board" do
        let(:other_foreman) { worker_roulette.foreman('other_foreman') }

        expect(redis.get(foreman.counter_key)).to be_nil

        other_foreman.enqueue_work_order(work_orders.other) do
          expect(redis.get(foreman.counter_key)).to eq("1")
          other_foreman.enqueue_work_order(work_orders.last) do
            expect(redis.get(foreman.counter_key)).to eq("1")
            foreman.enqueue_work_order(work_orders.first) do
              expect(redis.get(foreman.counter_key)).to eq("2")
              done
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
            expect(tradesman.last_sender).to eq(sender)
            done
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
              expect(redis.get("L*:#{sender}")).to eq("1")
              expect(redis.keys("L*:*").length).to eq(1)
              tradesman.work_orders! do
                expect(redis.keys("L*:*").length).to eq(1)
                expect(redis.get("L*:recent_sender")).to eq("1")
                tradesman.work_orders!
                done(0.2) do
                  expect(redis.keys("L*:*").length).to eq(0)
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
            tradesman.work_orders! do |p| expect(p).to be_empty
              tradesman.work_orders! {|q| expect(q).to be_empty; done} #does not throw an error if queue is alreay empty
            end
          end
        end
      end

      it "takes the oldest sender off the job board (FIFO)" do
        foreman.enqueue_work_order(work_orders) do
          oldest_sender = sender.to_s
          recent_sender = 'recent_sender'
          recent_foreman = worker_roulette.foreman(recent_sender)
          recent_foreman.enqueue_work_order(work_orders) do
            expect(redis.zrange(tradesman.job_board_key, 0, -1)).to eq([oldest_sender, recent_sender])
            tradesman.work_orders! { expect(redis.zrange(tradesman.job_board_key, 0, -1)).to eq([recent_sender]); done }
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
            expect(tradesman.last_sender).to match(/katie_80/)
            done(0.1)
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
            done(0.1)

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

        done(0.2) {expect(got_good && got_lazy).to eq(true)}
      end
    end

  end
end

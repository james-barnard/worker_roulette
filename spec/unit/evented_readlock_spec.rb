require 'spec_helper'
module WorkerRoulette
  describe "Evented Read Lock" do
    include EventedSpec::EMSpec

    let(:redis) {Redis.new(WorkerRoulette.start.redis_config)}
    let(:sender) {'katie_80'}
    let(:sender_key) {"new_job_ready:#{sender}" }
    let(:work_orders) {"hellot"}
    let(:lock_key) {"L*:#{sender_key}"}
    let(:default_headers) {Hash['headers' => {'sender' => sender}]}
    let(:work_orders_with_headers) {default_headers.merge({'payload' => work_orders})}
    let(:jsonized_work_orders_with_headers) {[WorkerRoulette.dump(work_orders_with_headers)]}
    let(:worker_roulette) { WorkerRoulette.start(evented: true) }
    let(:foreman) {worker_roulette.foreman(sender)}
    let(:number_two) {worker_roulette.foreman('number_two')}
    let(:subject) {worker_roulette.tradesman}
    let(:subject_two) {worker_roulette.tradesman}
    let(:lua) { Lua.new(worker_roulette.tradesman_connection_pool) }

    em_before do
      lua.clear_cache!
      redis.script(:flush)
      redis.flushdb
    end

    xit "should lock a queue when it reads from it" do
      evented_readlock_preconditions do
        expect(redis.get(lock_key)).not_to be_nil
        done
      end
    end

    xit "should set the lock to expire in 3 seconds" do
      evented_readlock_preconditions do
        expect(redis.ttl(lock_key)).to eq(3)
        done
      end
    end

    it "should not read a locked queue" do
      evented_readlock_preconditions do
        foreman.enqueue_work_order(work_orders) do #locked
          subject_two.work_orders! do |work|
            expect(work).to be_empty
            done { subject.work_orders! }
          end
        end
      end
    end

    xit "should read from the first available queue that is not locked" do
      evented_readlock_preconditions do
        foreman.enqueue_work_order(work_orders) do    #locked
          number_two.enqueue_work_order(work_orders) do  #unlocked
            subject_two.work_orders!{|work| expect(work.first['headers']['sender']).to eq('number_two'); done { subject.work_orders!} }
          end
        end
      end
    end

    xit "should release its last lock when it asks for its next work order from another sender" do
      evented_readlock_preconditions do
        number_two.enqueue_work_order(work_orders) do #unlocked
          expect(subject.last_sender).to eq(sender_key)
          subject.work_orders! do |work|
            expect(work.first['headers']['sender']).to eq('number_two')
            expect(redis.get(lock_key)).to be_nil
            done
          end
        end
      end
    end

    xit "should not release its lock when it asks for its next work order from the same sender" do
      evented_readlock_preconditions do
        foreman.enqueue_work_order(work_orders) do #locked
          subject.work_orders! do |work|
            expect(work).to eq([work_orders_with_headers])
            expect(subject.last_sender).to eq(sender_key)
            expect(redis.get(lock_key)).not_to be_nil
            done
          end
        end
      end
    end

    xit "should not take out another lock if there is no work to do" do
      evented_readlock_preconditions do
        foreman.enqueue_work_order(work_orders) do #locked
          subject.work_orders! do |work_order|
            expect(work_order).to eq([work_orders_with_headers])
            subject.work_orders! do |work|
              expect(work).to be_empty
              expect(redis.get(lock_key)).to be_nil
              done
            end
          end
        end
      end
    end

    def evented_readlock_preconditions(&spec_block)
      foreman.enqueue_work_order(work_orders) do
        subject.work_orders! do |work|
          expect(work).to eq([work_orders_with_headers])
          spec_block.call
        end
      end
    end
  end
end

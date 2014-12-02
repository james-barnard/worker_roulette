require 'spec_helper'
module WorkerRoulette
 describe "Read Lock" do
    let(:worker_roulette) {WorkerRoulette.start(evented: false)}
    let(:redis) {Redis.new(worker_roulette.redis_config)}
    let(:sender) {'katie_80'}
    let(:sender_key) { "new_job_ready:#{sender}" }
    let(:work_orders) {"hellot"}
    let(:lock_key) {"L*:#{sender_key}"}
    let(:default_headers) {Hash['headers' => {'sender' => sender}]}
    let(:work_orders_with_headers) {default_headers.merge({'payload' => work_orders})}
    let(:jsonized_work_orders_with_headers) {[WorkerRoulette.dump(work_orders_with_headers)]}
    let(:foreman) {worker_roulette.foreman(sender)}
    let(:number_two) {worker_roulette.foreman('number_two')}
    let(:subject) {worker_roulette.tradesman}
    let(:subject_two) {worker_roulette.tradesman}
    let(:lua) { Lua.new(worker_roulette.tradesman_connection_pool) }

    before do
      lua.clear_cache!
      redis.script(:flush)
      redis.flushdb
      foreman.enqueue_work_order(work_orders)
      expect(subject.work_orders!).to eq([work_orders_with_headers])
    end

    it "should lock a queue when it reads from it" do
      expect(redis.get(lock_key)).not_to be_nil
    end

    it "should set the lock to expire in 3 second" do
      expect(redis.ttl(lock_key)).to eq(3)
    end

    it "should not read a locked queue" do
      foreman.enqueue_work_order(work_orders)    #locked
      expect(subject_two.work_orders!).to be_empty
    end

    it "should read from the first available queue that is not locked" do
       foreman.enqueue_work_order(work_orders)     #locked
       number_two.enqueue_work_order(work_orders)  #unlocked
       expect(subject_two.work_orders!.first['headers']['sender']).to eq('new_job_ready:number_two')
    end

    it "should release its previous lock when it asks for work from another sender" do
      number_two.enqueue_work_order(work_orders)    #unlocked
      expect(subject.last_sender).to eq(sender)
      expect(subject.work_orders!.first['headers']['sender']).to eq('new_job_ready:number_two')
      expect(redis.get(lock_key)).to be_nil
    end

    it "should not release its lock when it asks for work from the same sender" do
      foreman.enqueue_work_order(work_orders)    #locked
      expect(subject.work_orders!).to eq([work_orders_with_headers])
      expect(subject.last_sender).to eq(sender_key)

      foreman.enqueue_work_order(work_orders)    #locked
      expect(subject.work_orders!).to eq([work_orders_with_headers])
      expect(subject.last_sender).to eq(sender_key)

      expect(redis.get(lock_key)).not_to be_nil
    end

    it "should release its previous lock if there is no work to do from the same sender" do
      foreman.enqueue_work_order(work_orders)    #locked
      expect(subject.work_orders!).to eq([work_orders_with_headers])
      expect(subject.work_orders!).to be_empty
      expect(redis.get(lock_key)).to be_nil
    end
  end
end

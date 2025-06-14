require_relative '../helper'
require 'fluent/plugin/buffer'
require 'fluent/plugin/buffer/memory_chunk'
require 'fluent/plugin/compressable'
require 'fluent/plugin/buffer/chunk'
require 'fluent/event'
require 'flexmock/test_unit'

require 'fluent/log'
require 'fluent/plugin_id'

require 'time'

module FluentPluginBufferTest
  class DummyOutputPlugin < Fluent::Plugin::Base
    include Fluent::PluginId
    include Fluent::PluginLoggerMixin
  end
  class DummyMemoryChunkError < StandardError; end
  class DummyMemoryChunk < Fluent::Plugin::Buffer::MemoryChunk
    attr_reader :append_count, :rollbacked, :closed, :purged, :chunk
    attr_accessor :failing
    def initialize(metadata, compress: :text)
      super
      @append_count = 0
      @rollbacked = false
      @closed = false
      @purged = false
      @failing = false
    end
    def concat(data, size)
      @append_count += 1
      raise DummyMemoryChunkError if @failing
      super
    end
    def rollback
      super
      @rollbacked = true
    end
    def close
      super
      @closed = true
    end
    def purge
      super
      @purged = true
    end
  end
  class DummyPlugin < Fluent::Plugin::Buffer
    def create_metadata(timekey=nil, tag=nil, variables=nil)
      Fluent::Plugin::Buffer::Metadata.new(timekey, tag, variables)
    end
    def create_chunk(metadata, data)
      c = FluentPluginBufferTest::DummyMemoryChunk.new(metadata)
      c.append(data)
      c.commit
      c
    end
    def create_chunk_es(metadata, es)
      c = FluentPluginBufferTest::DummyMemoryChunk.new(metadata)
      c.concat(es.to_msgpack_stream, es.size)
      c.commit
      c
    end
    def resume
      dm0 = create_metadata(Time.parse('2016-04-11 16:00:00 +0000').to_i, nil, nil)
      dm1 = create_metadata(Time.parse('2016-04-11 16:10:00 +0000').to_i, nil, nil)
      dm2 = create_metadata(Time.parse('2016-04-11 16:20:00 +0000').to_i, nil, nil)
      dm3 = create_metadata(Time.parse('2016-04-11 16:30:00 +0000').to_i, nil, nil)
      staged = {
        dm2 => create_chunk(dm2, ["b" * 100]).staged!,
        dm3 => create_chunk(dm3, ["c" * 100]).staged!,
      }
      queued = [
        create_chunk(dm0, ["0" * 100]).enqueued!,
        create_chunk(dm1, ["a" * 100]).enqueued!,
        create_chunk(dm1, ["a" * 3]).enqueued!,
      ]
      return staged, queued
    end
    def generate_chunk(metadata)
      DummyMemoryChunk.new(metadata, compress: @compress)
    end
  end
end

class BufferTest < Test::Unit::TestCase
  def create_buffer(hash)
    buffer_conf = config_element('buffer', '', hash, [])
    owner = FluentPluginBufferTest::DummyOutputPlugin.new
    owner.configure(config_element('ROOT', '', {}, [ buffer_conf ]))
    p = FluentPluginBufferTest::DummyPlugin.new
    p.owner = owner
    p.configure(buffer_conf)
    p
  end

  def create_metadata(timekey=nil, tag=nil, variables=nil)
    Fluent::Plugin::Buffer::Metadata.new(timekey, tag, variables)
  end

  def create_chunk(metadata, data)
    c = FluentPluginBufferTest::DummyMemoryChunk.new(metadata)
    c.append(data)
    c.commit
    c
  end

  def create_chunk_es(metadata, es)
    c = FluentPluginBufferTest::DummyMemoryChunk.new(metadata)
    c.concat(es.to_msgpack_stream, es.size)
    c.commit
    c
  end

  setup do
    Fluent::Test.setup
  end

  sub_test_case 'using base buffer class' do
    setup do
      buffer_conf = config_element('buffer', '', {}, [])
      owner = FluentPluginBufferTest::DummyOutputPlugin.new
      owner.configure(config_element('ROOT', '', {}, [ buffer_conf ]))
      p = Fluent::Plugin::Buffer.new
      p.owner = owner
      p.configure(buffer_conf)
      @p = p
    end

    test 'default persistency is false' do
      assert !@p.persistent?
    end

    test 'chunk bytes limit is 8MB, and total bytes limit is 512MB' do
      assert_equal 8*1024*1024, @p.chunk_limit_size
      assert_equal 512*1024*1024, @p.total_limit_size
    end

    test 'chunk records limit is ignored in default' do
      assert_nil @p.chunk_limit_records
    end

    test '#storable? checks total size of staged and enqueued(includes dequeued chunks) against total_limit_size' do
      assert_equal 512*1024*1024, @p.total_limit_size
      assert_equal 0, @p.stage_size
      assert_equal 0, @p.queue_size
      assert @p.storable?

      @p.stage_size = 256 * 1024 * 1024
      @p.queue_size = 256 * 1024 * 1024 - 1
      assert @p.storable?

      @p.queue_size = 256 * 1024 * 1024
      assert !@p.storable?
    end

    test '#resume must be implemented by subclass' do
      assert_raise NotImplementedError do
        @p.resume
      end
    end

    test '#generate_chunk must be implemented by subclass' do
      assert_raise NotImplementedError do
        @p.generate_chunk(Object.new)
      end
    end
  end

  sub_test_case 'with default configuration and dummy implementation' do
    setup do
      @p = create_buffer({'queued_chunks_limit_size' => 100})
      @dm0 = create_metadata(Time.parse('2016-04-11 16:00:00 +0000').to_i, nil, nil)
      @dm1 = create_metadata(Time.parse('2016-04-11 16:10:00 +0000').to_i, nil, nil)
      @dm2 = create_metadata(Time.parse('2016-04-11 16:20:00 +0000').to_i, nil, nil)
      @dm3 = create_metadata(Time.parse('2016-04-11 16:30:00 +0000').to_i, nil, nil)
      @p.start
    end

    test '#start resumes buffer states and update queued numbers per metadata' do
      plugin = create_buffer({})

      assert_equal({}, plugin.stage)
      assert_equal([], plugin.queue)
      assert_equal({}, plugin.dequeued)
      assert_equal({}, plugin.queued_num)

      assert_equal 0, plugin.stage_size
      assert_equal 0, plugin.queue_size
      assert_equal [], plugin.timekeys

      # @p is started plugin

      assert_equal [@dm2,@dm3], @p.stage.keys
      assert_equal "b" * 100, @p.stage[@dm2].read
      assert_equal "c" * 100, @p.stage[@dm3].read

      assert_equal 200, @p.stage_size

      assert_equal 3, @p.queue.size
      assert_equal "0" * 100, @p.queue[0].read
      assert_equal "a" * 100, @p.queue[1].read
      assert_equal "a" * 3, @p.queue[2].read

      assert_equal 203, @p.queue_size

      # staged, queued
      assert_equal 1, @p.queued_num[@dm0]
      assert_equal 2, @p.queued_num[@dm1]
    end

    test '#close closes all chunks in dequeued, enqueued and staged' do
      dmx = create_metadata(Time.parse('2016-04-11 15:50:00 +0000').to_i, nil, nil)
      cx = create_chunk(dmx, ["x" * 1024])
      @p.dequeued[cx.unique_id] = cx

      staged_chunks = @p.stage.values.dup
      queued_chunks = @p.queue.dup

      @p.close

      assert cx.closed
      assert{ staged_chunks.all?{|c| c.closed } }
      assert{ queued_chunks.all?{|c| c.closed } }
    end

    test '#terminate initializes all internal states' do
      dmx = create_metadata(Time.parse('2016-04-11 15:50:00 +0000').to_i, nil, nil)
      cx = create_chunk(dmx, ["x" * 1024])
      @p.dequeued[cx.unique_id] = cx

      @p.close

      @p.terminate

      assert_nil @p.stage
      assert_nil @p.queue
      assert_nil @p.dequeued
      assert_nil @p.queued_num
      assert_nil @p.stage_length_metrics
      assert_nil @p.stage_size_metrics
      assert_nil @p.queue_length_metrics
      assert_nil @p.queue_size_metrics
      assert_nil @p.available_buffer_space_ratios_metrics
      assert_nil @p.total_queued_size_metrics
      assert_nil @p.newest_timekey_metrics
      assert_nil @p.oldest_timekey_metrics
      assert_equal [], @p.timekeys
    end

    test '#queued_records returns total number of size in all chunks in queue' do
      assert_equal 3, @p.queue.size

      r0 = @p.queue[0].size
      assert_equal 1, r0
      r1 = @p.queue[1].size
      assert_equal 1, r1
      r2 = @p.queue[2].size
      assert_equal 1, r2

      assert_equal (r0+r1+r2), @p.queued_records
    end

    test '#queued? returns queue has any chunks or not without arguments' do
      assert @p.queued?

      @p.queue.reject!{|_c| true }
      assert !@p.queued?
    end

    test '#queued? returns queue has chunks for specified metadata with an argument' do
      assert @p.queued?(@dm0)
      assert @p.queued?(@dm1)
      assert !@p.queued?(@dm2)
    end

    test '#enqueue_chunk enqueues a chunk on stage with specified metadata' do
      assert_equal 2, @p.stage.size
      assert_equal [@dm2,@dm3], @p.stage.keys
      assert_equal 3, @p.queue.size
      assert_nil @p.queued_num[@dm2]

      assert_equal 200, @p.stage_size
      assert_equal 203, @p.queue_size

      @p.enqueue_chunk(@dm2)

      assert_equal [@dm3], @p.stage.keys
      assert_equal @dm2, @p.queue.last.metadata
      assert_equal 1, @p.queued_num[@dm2]
      assert_equal 100, @p.stage_size
      assert_equal 303, @p.queue_size
    end

    test '#enqueue_chunk ignores empty chunks' do
      assert_equal 3, @p.queue.size

      m = @p.metadata(timekey: Time.parse('2016-04-11 16:40:00 +0000').to_i)
      c = create_chunk(m, [''])
      @p.stage[m] = c
      assert @p.stage[m].empty?
      assert !c.closed

      @p.enqueue_chunk(m)

      assert_nil @p.stage[m]
      assert_equal 3, @p.queue.size
      assert_nil @p.queued_num[m]
      assert c.closed
    end

    test '#enqueue_chunk calls #enqueued! if chunk responds to it' do
      assert_equal 3, @p.queue.size
      m = @p.metadata(timekey: Time.parse('2016-04-11 16:40:00 +0000').to_i)
      c = create_chunk(m, ['c' * 256])
      callback_called = false
      (class << c; self; end).module_eval do
        define_method(:enqueued!){ callback_called = true }
      end

      @p.stage[m] = c
      @p.enqueue_chunk(m)

      assert_equal c, @p.queue.last
      assert callback_called
    end

    test '#enqueue_all enqueues chunks on stage which given block returns true with' do
      m1 = @p.metadata(timekey: Time.parse('2016-04-11 16:40:00 +0000').to_i)
      c1 = create_chunk(m1, ['c' * 256])
      @p.stage[m1] = c1
      m2 = @p.metadata(timekey: Time.parse('2016-04-11 16:50:00 +0000').to_i)
      c2 = create_chunk(m2, ['c' * 256])
      @p.stage[m2] = c2

      assert_equal [@dm2,@dm3,m1,m2], @p.stage.keys
      assert_equal [@dm0,@dm1,@dm1], @p.queue.map(&:metadata)

      @p.enqueue_all{ |m, c| m.timekey < Time.parse('2016-04-11 16:41:00 +0000').to_i }

      assert_equal [m2], @p.stage.keys
      assert_equal [@dm0,@dm1,@dm1,@dm2,@dm3,m1], @p.queue.map(&:metadata)
    end

    test '#enqueue_all enqueues all chunks on stage without block' do
      m1 = @p.metadata(timekey: Time.parse('2016-04-11 16:40:00 +0000').to_i)
      c1 = create_chunk(m1, ['c' * 256])
      @p.stage[m1] = c1
      m2 = @p.metadata(timekey: Time.parse('2016-04-11 16:50:00 +0000').to_i)
      c2 = create_chunk(m2, ['c' * 256])
      @p.stage[m2] = c2

      assert_equal [@dm2,@dm3,m1,m2], @p.stage.keys
      assert_equal [@dm0,@dm1,@dm1], @p.queue.map(&:metadata)

      @p.enqueue_all

      assert_equal [], @p.stage.keys
      assert_equal [@dm0,@dm1,@dm1,@dm2,@dm3,m1,m2], @p.queue.map(&:metadata)
    end

    test '#dequeue_chunk dequeues a chunk from queue if a chunk exists' do
      assert_equal [@dm0,@dm1,@dm1], @p.queue.map(&:metadata)
      assert_equal({}, @p.dequeued)

      m1 = @p.dequeue_chunk
      assert_equal @dm0, m1.metadata
      assert_equal @dm0, @p.dequeued[m1.unique_id].metadata

      m2 = @p.dequeue_chunk
      assert_equal @dm1, m2.metadata
      assert_equal @dm1, @p.dequeued[m2.unique_id].metadata

      m3 = @p.dequeue_chunk
      assert_equal @dm1, m3.metadata
      assert_equal @dm1, @p.dequeued[m3.unique_id].metadata

      m4 = @p.dequeue_chunk
      assert_nil m4
    end

    test '#takeback_chunk resumes a chunk from dequeued to queued at the head of queue, and returns true' do
      assert_equal [@dm0,@dm1,@dm1], @p.queue.map(&:metadata)
      assert_equal({}, @p.dequeued)

      m1 = @p.dequeue_chunk
      assert_equal @dm0, m1.metadata
      assert_equal @dm0, @p.dequeued[m1.unique_id].metadata
      assert_equal [@dm1,@dm1], @p.queue.map(&:metadata)
      assert_equal({m1.unique_id => m1}, @p.dequeued)

      assert @p.takeback_chunk(m1.unique_id)

      assert_equal [@dm0,@dm1,@dm1], @p.queue.map(&:metadata)
      assert_equal({}, @p.dequeued)
    end

    test '#purge_chunk removes a chunk specified by argument id from dequeued chunks' do
      assert_equal [@dm0,@dm1,@dm1], @p.queue.map(&:metadata)
      assert_equal({}, @p.dequeued)

      m0 = @p.dequeue_chunk
      m1 = @p.dequeue_chunk

      assert @p.takeback_chunk(m0.unique_id)

      assert_equal [@dm0,@dm1], @p.queue.map(&:metadata)
      assert_equal({m1.unique_id => m1}, @p.dequeued)

      assert !m1.purged

      @p.purge_chunk(m1.unique_id)
      assert m1.purged

      assert_equal [@dm0,@dm1], @p.queue.map(&:metadata)
      assert_equal({}, @p.dequeued)
    end

    test '#purge_chunk removes an argument metadata if no chunks exist on stage or in queue' do
      assert_equal [@dm0,@dm1,@dm1], @p.queue.map(&:metadata)
      assert_equal({}, @p.dequeued)

      m0 = @p.dequeue_chunk

      assert_equal [@dm1,@dm1], @p.queue.map(&:metadata)
      assert_equal({m0.unique_id => m0}, @p.dequeued)

      assert !m0.purged

      @p.purge_chunk(m0.unique_id)
      assert m0.purged

      assert_equal [@dm1,@dm1], @p.queue.map(&:metadata)
      assert_equal({}, @p.dequeued)
    end

    test '#takeback_chunk returns false if specified chunk_id is already purged' do
      assert_equal [@dm0,@dm1,@dm1], @p.queue.map(&:metadata)
      assert_equal({}, @p.dequeued)

      m0 = @p.dequeue_chunk

      assert_equal [@dm1,@dm1], @p.queue.map(&:metadata)
      assert_equal({m0.unique_id => m0}, @p.dequeued)

      assert !m0.purged

      @p.purge_chunk(m0.unique_id)
      assert m0.purged

      assert_equal [@dm1,@dm1], @p.queue.map(&:metadata)
      assert_equal({}, @p.dequeued)

      assert !@p.takeback_chunk(m0.unique_id)

      assert_equal [@dm1,@dm1], @p.queue.map(&:metadata)
      assert_equal({}, @p.dequeued)
    end

    test '#clear_queue! removes all chunks in queue, but leaves staged chunks' do
      qchunks = @p.queue.dup

      assert_equal [@dm0,@dm1,@dm1], @p.queue.map(&:metadata)
      assert_equal 2, @p.stage.size
      assert_equal({}, @p.dequeued)

      @p.clear_queue!

      assert_equal [], @p.queue
      assert_equal 0, @p.queue_size
      assert_equal 2, @p.stage.size
      assert_equal({}, @p.dequeued)

      assert{ qchunks.all?{ |c| c.purged } }
    end

    test '#write returns immediately if argument data is empty array' do
      assert_equal [@dm0,@dm1,@dm1], @p.queue.map(&:metadata)
      assert_equal [@dm2,@dm3], @p.stage.keys

      m = @p.metadata(timekey: Time.parse('2016-04-11 16:40:00 +0000').to_i)

      @p.write({m => []})

      assert_equal [@dm0,@dm1,@dm1], @p.queue.map(&:metadata)
      assert_equal [@dm2,@dm3], @p.stage.keys
    end

    test '#write returns immediately if argument data is empty event stream' do
      assert_equal [@dm0,@dm1,@dm1], @p.queue.map(&:metadata)
      assert_equal [@dm2,@dm3], @p.stage.keys

      m = @p.metadata(timekey: Time.parse('2016-04-11 16:40:00 +0000').to_i)

      @p.write({m => Fluent::ArrayEventStream.new([])})

      assert_equal [@dm0,@dm1,@dm1], @p.queue.map(&:metadata)
      assert_equal [@dm2,@dm3], @p.stage.keys
    end

    test '#write raises BufferOverflowError if buffer is not storable' do
      @p.stage_size = 256 * 1024 * 1024
      @p.queue_size = 256 * 1024 * 1024

      m = @p.metadata(timekey: Time.parse('2016-04-11 16:40:00 +0000').to_i)

      assert_raise Fluent::Plugin::Buffer::BufferOverflowError do
        @p.write({m => ["x" * 256]})
      end
    end

    test '#write stores data into an existing chunk with metadata specified' do
      assert_equal [@dm0,@dm1,@dm1], @p.queue.map(&:metadata)
      assert_equal [@dm2,@dm3], @p.stage.keys

      dm3data = @p.stage[@dm3].read.dup
      prev_stage_size = @p.stage_size

      assert_equal 1, @p.stage[@dm3].append_count

      @p.write({@dm3 => ["x" * 256, "y" * 256, "z" * 256]})

      assert_equal 2, @p.stage[@dm3].append_count
      assert_equal (dm3data + ("x" * 256) + ("y" * 256) + ("z" * 256)), @p.stage[@dm3].read
      assert_equal (prev_stage_size + 768), @p.stage_size

      assert_equal [@dm0,@dm1,@dm1], @p.queue.map(&:metadata)
      assert_equal [@dm2,@dm3], @p.stage.keys
    end

    test '#write creates new chunk and store data into it if there are no chunks for specified metadata' do
      assert_equal [@dm0,@dm1,@dm1], @p.queue.map(&:metadata)
      assert_equal [@dm2,@dm3], @p.stage.keys

      timekey = Time.parse('2016-04-11 16:40:00 +0000').to_i
      assert !@p.timekeys.include?(timekey)

      prev_stage_size = @p.stage_size

      m = @p.metadata(timekey: timekey)

      @p.write({m => ["x" * 256, "y" * 256, "z" * 256]})

      assert_equal 1, @p.stage[m].append_count
      assert_equal ("x" * 256 + "y" * 256 + "z" * 256), @p.stage[m].read
      assert_equal (prev_stage_size + 768), @p.stage_size

      assert_equal [@dm0,@dm1,@dm1], @p.queue.map(&:metadata)
      assert_equal [@dm2,@dm3,m], @p.stage.keys

      @p.update_timekeys

      assert @p.timekeys.include?(timekey)
    end

    test '#write tries to enqueue and store data into a new chunk if existing chunk is full' do
      assert_equal 8 * 1024 * 1024, @p.chunk_limit_size
      assert_equal 0.95, @p.chunk_full_threshold

      assert_equal [@dm0,@dm1,@dm1], @p.queue.map(&:metadata)
      assert_equal [@dm2,@dm3], @p.stage.keys

      m = @p.metadata(timekey: Time.parse('2016-04-11 16:40:00 +0000').to_i)

      row = "x" * 1024 * 1024
      small_row = "x" * 1024 * 512
      @p.write({m => [row] * 7 + [small_row]})

      assert_equal [@dm0,@dm1,@dm1], @p.queue.map(&:metadata)
      assert_equal [@dm2,@dm3,m], @p.stage.keys
      assert_equal 1, @p.stage[m].append_count

      @p.write({m => [row]})

      assert_equal [@dm0,@dm1,@dm1,m], @p.queue.map(&:metadata)
      assert_equal [@dm2,@dm3,m], @p.stage.keys
      assert_equal 1, @p.stage[m].append_count
      assert_equal 1024*1024, @p.stage[m].bytesize
      assert_equal 3, @p.queue.last.append_count # 1 -> write (2) -> write_step_by_step (3)
      assert @p.queue.last.rollbacked
    end

    test '#write rollbacks if commit raises errors' do
      assert_equal [@dm0,@dm1,@dm1], @p.queue.map(&:metadata)
      assert_equal [@dm2,@dm3], @p.stage.keys

      m = @p.metadata(timekey: Time.parse('2016-04-11 16:40:00 +0000').to_i)

      row = "x" * 1024
      @p.write({m => [row] * 8})

      assert_equal [@dm0,@dm1,@dm1], @p.queue.map(&:metadata)
      assert_equal [@dm2,@dm3,m], @p.stage.keys

      target_chunk = @p.stage[m]

      assert_equal 1, target_chunk.append_count
      assert !target_chunk.rollbacked

      (class << target_chunk; self; end).module_eval do
        define_method(:commit){ raise "yay" }
      end

      assert_raise RuntimeError.new("yay") do
        @p.write({m => [row]})
      end

      assert_equal [@dm0,@dm1,@dm1], @p.queue.map(&:metadata)
      assert_equal [@dm2,@dm3,m], @p.stage.keys

      assert_equal 2, target_chunk.append_count
      assert target_chunk.rollbacked
      assert_equal row * 8, target_chunk.read
    end

    test '#write w/ format raises BufferOverflowError if buffer is not storable' do
      @p.stage_size = 256 * 1024 * 1024
      @p.queue_size = 256 * 1024 * 1024

      m = @p.metadata(timekey: Time.parse('2016-04-11 16:40:00 +0000').to_i)

      es = Fluent::ArrayEventStream.new([ [event_time('2016-04-11 16:40:01 +0000'), {"message" => "xxxxxxxxxxxxxx"} ] ])

      assert_raise Fluent::Plugin::Buffer::BufferOverflowError do
        @p.write({m => es}, format: ->(e){e.to_msgpack_stream})
      end
    end

    test '#write w/ format stores data into an existing chunk with metadata specified' do
      assert_equal [@dm0,@dm1,@dm1], @p.queue.map(&:metadata)
      assert_equal [@dm2,@dm3], @p.stage.keys

      dm3data = @p.stage[@dm3].read.dup
      prev_stage_size = @p.stage_size

      assert_equal 1, @p.stage[@dm3].append_count

      es = Fluent::ArrayEventStream.new(
        [
          [event_time('2016-04-11 16:40:01 +0000'), {"message" => "x" * 128}],
          [event_time('2016-04-11 16:40:01 +0000'), {"message" => "y" * 128}],
          [event_time('2016-04-11 16:40:01 +0000'), {"message" => "z" * 128}],
        ]
      )

      @p.write({@dm3 => es}, format: ->(e){e.to_msgpack_stream})

      assert_equal 2, @p.stage[@dm3].append_count
      assert_equal (dm3data + es.to_msgpack_stream), @p.stage[@dm3].read
      assert_equal (prev_stage_size + es.to_msgpack_stream.bytesize), @p.stage_size

      assert_equal [@dm0,@dm1,@dm1], @p.queue.map(&:metadata)
      assert_equal [@dm2,@dm3], @p.stage.keys
    end

    test '#write w/ format creates new chunk and store data into it if there are not chunks for specified metadata' do
      assert_equal 8 * 1024 * 1024, @p.chunk_limit_size

      assert_equal [@dm0,@dm1,@dm1], @p.queue.map(&:metadata)
      assert_equal [@dm2,@dm3], @p.stage.keys

      timekey = Time.parse('2016-04-11 16:40:00 +0000').to_i
      assert !@p.timekeys.include?(timekey)

      m = @p.metadata(timekey: timekey)

      es = Fluent::ArrayEventStream.new(
        [
          [event_time('2016-04-11 16:40:01 +0000'), {"message" => "x" * 1024 * 1024}],
          [event_time('2016-04-11 16:40:01 +0000'), {"message" => "x" * 1024 * 1024}],
          [event_time('2016-04-11 16:40:01 +0000'), {"message" => "x" * 1024 * 1024}],
          [event_time('2016-04-11 16:40:01 +0000'), {"message" => "x" * 1024 * 1024}],
          [event_time('2016-04-11 16:40:01 +0000'), {"message" => "x" * 1024 * 1024}],
          [event_time('2016-04-11 16:40:01 +0000'), {"message" => "x" * 1024 * 1024}],
          [event_time('2016-04-11 16:40:01 +0000'), {"message" => "x" * 1024 * 1024}],
          [event_time('2016-04-11 16:40:03 +0000'), {"message" => "z" * 1024 * 512}],
        ]
      )
      @p.write({m => es}, format: ->(e){e.to_msgpack_stream})

      assert_equal [@dm0,@dm1,@dm1], @p.queue.map(&:metadata)
      assert_equal [@dm2,@dm3,m], @p.stage.keys
      assert_equal 1, @p.stage[m].append_count

      @p.update_timekeys

      assert @p.timekeys.include?(timekey)
    end

    test '#write w/ format tries to enqueue and store data into a new chunk if existing chunk does not have enough space' do
      assert_equal 8 * 1024 * 1024, @p.chunk_limit_size

      assert_equal [@dm0,@dm1,@dm1], @p.queue.map(&:metadata)
      assert_equal [@dm2,@dm3], @p.stage.keys

      m = @p.metadata(timekey: Time.parse('2016-04-11 16:40:00 +0000').to_i)

      es = Fluent::ArrayEventStream.new(
        [
          [event_time('2016-04-11 16:40:01 +0000'), {"message" => "x" * 1024 * 1024}],
          [event_time('2016-04-11 16:40:01 +0000'), {"message" => "x" * 1024 * 1024}],
          [event_time('2016-04-11 16:40:01 +0000'), {"message" => "x" * 1024 * 1024}],
          [event_time('2016-04-11 16:40:01 +0000'), {"message" => "x" * 1024 * 1024}],
          [event_time('2016-04-11 16:40:01 +0000'), {"message" => "x" * 1024 * 1024}],
          [event_time('2016-04-11 16:40:01 +0000'), {"message" => "x" * 1024 * 1024}],
          [event_time('2016-04-11 16:40:01 +0000'), {"message" => "x" * 1024 * 1024}],
          [event_time('2016-04-11 16:40:03 +0000'), {"message" => "z" * 1024 * 512}],
        ]
      )
      @p.write({m => es}, format: ->(e){e.to_msgpack_stream})

      assert_equal [@dm0,@dm1,@dm1], @p.queue.map(&:metadata)
      assert_equal [@dm2,@dm3,m], @p.stage.keys
      assert_equal 1, @p.stage[m].append_count

      es2 = Fluent::OneEventStream.new(event_time('2016-04-11 16:40:03 +0000'), {"message" => "z" * 1024 * 1024})
      @p.write({m => es2}, format: ->(e){e.to_msgpack_stream})

      assert_equal [@dm0,@dm1,@dm1,m], @p.queue.map(&:metadata)
      assert_equal [@dm2,@dm3,m], @p.stage.keys
      assert_equal 1, @p.stage[m].append_count
      assert_equal es2.to_msgpack_stream.bytesize, @p.stage[m].bytesize
      assert_equal 2, @p.queue.last.append_count # 1 -> write (2) -> rollback&enqueue
      assert @p.queue.last.rollbacked
    end

    test '#write w/ format enqueues chunk if it is already full after adding data' do
      assert_equal 8 * 1024 * 1024, @p.chunk_limit_size

      assert_equal [@dm0,@dm1,@dm1], @p.queue.map(&:metadata)
      assert_equal [@dm2,@dm3], @p.stage.keys

      m = @p.metadata(timekey: Time.parse('2016-04-11 16:40:00 +0000').to_i)
      es = Fluent::ArrayEventStream.new(
        [
          [event_time('2016-04-11 16:40:01 +0000'), {"message" => "x" * (1024 * 1024 - 25)}], # 1024 * 1024 bytes as msgpack stream
          [event_time('2016-04-11 16:40:01 +0000'), {"message" => "x" * (1024 * 1024 - 25)}],
          [event_time('2016-04-11 16:40:01 +0000'), {"message" => "x" * (1024 * 1024 - 25)}],
          [event_time('2016-04-11 16:40:01 +0000'), {"message" => "x" * (1024 * 1024 - 25)}],
          [event_time('2016-04-11 16:40:01 +0000'), {"message" => "x" * (1024 * 1024 - 25)}],
          [event_time('2016-04-11 16:40:01 +0000'), {"message" => "x" * (1024 * 1024 - 25)}],
          [event_time('2016-04-11 16:40:01 +0000'), {"message" => "x" * (1024 * 1024 - 25)}],
          [event_time('2016-04-11 16:40:01 +0000'), {"message" => "x" * (1024 * 1024 - 25)}],
        ]
      )
      @p.write({m => es}, format: ->(e){e.to_msgpack_stream})

      assert_equal [@dm0,@dm1,@dm1,m], @p.queue.map(&:metadata)
      assert_equal [@dm2,@dm3], @p.stage.keys
      assert_equal 1, @p.queue.last.append_count
    end

    test '#write w/ format rollbacks if commit raises errors' do
      assert_equal [@dm0,@dm1,@dm1], @p.queue.map(&:metadata)
      assert_equal [@dm2,@dm3], @p.stage.keys

      m = @p.metadata(timekey: Time.parse('2016-04-11 16:40:00 +0000').to_i)

      es = Fluent::ArrayEventStream.new(
        [
          [event_time('2016-04-11 16:40:01 +0000'), {"message" => "x" * 1024 * 1024}],
          [event_time('2016-04-11 16:40:01 +0000'), {"message" => "x" * 1024 * 1024}],
          [event_time('2016-04-11 16:40:01 +0000'), {"message" => "x" * 1024 * 1024}],
          [event_time('2016-04-11 16:40:01 +0000'), {"message" => "x" * 1024 * 1024}],
          [event_time('2016-04-11 16:40:01 +0000'), {"message" => "x" * 1024 * 1024}],
          [event_time('2016-04-11 16:40:01 +0000'), {"message" => "x" * 1024 * 1024}],
          [event_time('2016-04-11 16:40:01 +0000'), {"message" => "x" * 1024 * 1024}],
          [event_time('2016-04-11 16:40:03 +0000'), {"message" => "z" * 1024 * 512}],
        ]
      )
      @p.write({m => es}, format: ->(e){e.to_msgpack_stream})

      assert_equal [@dm0,@dm1,@dm1], @p.queue.map(&:metadata)
      assert_equal [@dm2,@dm3,m], @p.stage.keys

      target_chunk = @p.stage[m]

      assert_equal 1, target_chunk.append_count
      assert !target_chunk.rollbacked

      (class << target_chunk; self; end).module_eval do
        define_method(:commit){ raise "yay" }
      end

      es2 = Fluent::ArrayEventStream.new(
        [
          [event_time('2016-04-11 16:40:04 +0000'), {"message" => "z" * 1024 * 128}],
        ]
      )
      assert_raise RuntimeError.new("yay") do
        @p.write({m => es2}, format: ->(e){e.to_msgpack_stream})
      end

      assert_equal [@dm0,@dm1,@dm1], @p.queue.map(&:metadata)
      assert_equal [@dm2,@dm3,m], @p.stage.keys

      assert_equal 2, target_chunk.append_count
      assert target_chunk.rollbacked
      assert_equal es.to_msgpack_stream, target_chunk.read
    end

    test '#write writes many metadata and data pairs at once' do
      assert_equal [@dm0,@dm1,@dm1], @p.queue.map(&:metadata)
      assert_equal [@dm2,@dm3], @p.stage.keys

      row = "x" * 1024
      @p.write({ @dm0 => [row, row, row], @dm1 => [row, row] })

      assert_equal [@dm2,@dm3,@dm0,@dm1], @p.stage.keys
    end

    test '#write does not commit on any chunks if any append operation on chunk fails' do
      assert_equal [@dm0,@dm1,@dm1], @p.queue.map(&:metadata)
      assert_equal [@dm2,@dm3], @p.stage.keys

      row = "x" * 1024
      @p.write({ @dm0 => [row, row, row], @dm1 => [row, row] })

      assert_equal [@dm2,@dm3,@dm0,@dm1], @p.stage.keys

      dm2_size = @p.stage[@dm2].size
      assert !@p.stage[@dm2].rollbacked
      dm3_size = @p.stage[@dm3].size
      assert !@p.stage[@dm3].rollbacked

      assert{ @p.stage[@dm0].size == 3 }
      assert !@p.stage[@dm0].rollbacked
      assert{ @p.stage[@dm1].size == 2 }
      assert !@p.stage[@dm1].rollbacked

      meta_list = [@dm0, @dm1, @dm2, @dm3].sort
      @p.stage[meta_list.last].failing = true

      assert_raise(FluentPluginBufferTest::DummyMemoryChunkError) do
        @p.write({ @dm2 => [row], @dm3 => [row], @dm0 => [row, row, row], @dm1 => [row, row] })
      end

      assert{ @p.stage[@dm2].size == dm2_size }
      assert @p.stage[@dm2].rollbacked
      assert{ @p.stage[@dm3].size == dm3_size }
      assert @p.stage[@dm3].rollbacked

      assert{ @p.stage[@dm0].size == 3 }
      assert @p.stage[@dm0].rollbacked
      assert{ @p.stage[@dm1].size == 2 }
      assert @p.stage[@dm1].rollbacked
    end

    test '#compress returns :text' do
      assert_equal :text, @p.compress
    end

    # https://github.com/fluent/fluentd/issues/3089
    test "closed chunk should not be committed" do
      assert_equal 8 * 1024 * 1024, @p.chunk_limit_size
      assert_equal 0.95, @p.chunk_full_threshold

      purge_count = 0

      stub.proxy(@p).generate_chunk(anything) do |chunk|
        stub.proxy(chunk).purge do |result|
          purge_count += 1
          result
        end
        stub.proxy(chunk).commit do |result|
          assert_false(chunk.closed?)
          result
        end
        stub.proxy(chunk).rollback do |result|
          assert_false(chunk.closed?)
          result
        end
        chunk
      end

      m = @p.metadata(timekey: Time.parse('2016-04-11 16:40:00 +0000').to_i)
      small_row = "x" * 1024 * 400
      big_row = "x" * 1024 * 1024 * 8 # just `chunk_size_limit`, it does't cause BufferOverFlowError.

      # Write 42 events in 1 event stream, last one is for triggering `ShouldRetry`
      @p.write({m => [small_row] * 40 + [big_row] + ["x"]})

      # Above event strem will be splitted twice by `Buffer#write_step_by_step`
      #
      # 1. `write_once`: 42 [events] * 1 [stream]
      # 2. `write_step_by_step`: 4 [events]* 10 [streams] + 2 [events] * 1 [stream]
      # 3. `write_step_by_step` (by `ShouldRetry`): 1 [event] * 42 [streams]
      #
      # The problematic data is built in the 2nd stage.
      # In the 2nd stage, 5 streams are packed in a chunk.
      # ((1024 * 400) [bytes] * 4 [events] * 5 [streams] = 8192000 [bytes] < `chunk_limit_size` (8MB)).
      # So 3 chunks are used to store all data.
      # The 1st chunk is already staged by `write_once`.
      # The 2nd & 3rd chunks are newly created as unstaged.
      # The 3rd chunk is purged before `ShouldRetry`, it's no problem:
      #   https://github.com/fluent/fluentd/blob/7e9eba736ff40ad985341be800ddc46558be75f2/lib/fluent/plugin/buffer.rb#L850
      # The 2nd chunk is purged in `rescue ShouldRetry`:
      #   https://github.com/fluent/fluentd/blob/7e9eba736ff40ad985341be800ddc46558be75f2/lib/fluent/plugin/buffer.rb#L862
      # It causes the issue described in https://github.com/fluent/fluentd/issues/3089#issuecomment-1811839198

      assert_equal 2, purge_count
    end

    # https://github.com/fluent/fluentd/issues/4446
    test "#write_step_by_step keeps chunks kept in locked in entire #write process" do
      assert_equal 8 * 1024 * 1024, @p.chunk_limit_size
      assert_equal 0.95, @p.chunk_full_threshold

      mon_enter_counts_by_chunk = {}
      mon_exit_counts_by_chunk = {}

      stub.proxy(@p).generate_chunk(anything) do |chunk|
        stub(chunk).mon_enter do
          enter_count = 1 + mon_enter_counts_by_chunk.fetch(chunk, 0)
          exit_count = mon_exit_counts_by_chunk.fetch(chunk, 0)
          mon_enter_counts_by_chunk[chunk] = enter_count

          # Assert that chunk is passed to &block of write_step_by_step before exiting the lock.
          # (i.e. The lock count must be 2 greater than the exit count).
          # Since ShouldRetry occurs once, the staged chunk takes the lock 3 times when calling the block.
          if chunk.staged?
            lock_in_block = enter_count == 3
            assert_equal(enter_count - 2, exit_count) if lock_in_block
          else
            lock_in_block = enter_count == 2
            assert_equal(enter_count - 2, exit_count) if lock_in_block
          end
        end
        stub(chunk).mon_exit do
          exit_count = 1 + mon_exit_counts_by_chunk.fetch(chunk, 0)
          mon_exit_counts_by_chunk[chunk] = exit_count
        end
        chunk
      end

      m = @p.metadata(timekey: Time.parse('2016-04-11 16:40:00 +0000').to_i)
      small_row = "x" * 1024 * 400
      big_row = "x" * 1024 * 1024 * 8 # just `chunk_size_limit`, it does't cause BufferOverFlowError.

      # Write 42 events in 1 event stream, last one is for triggering `ShouldRetry`
      @p.write({m => [small_row] * 40 + [big_row] + ["x"]})

      # Above event strem will be splitted twice by `Buffer#write_step_by_step`
      #
      # 1. `write_once`: 42 [events] * 1 [stream]
      # 2. `write_step_by_step`: 4 [events]* 10 [streams] + 2 [events] * 1 [stream]
      # 3. `write_step_by_step` (by `ShouldRetry`): 1 [event] * 42 [streams]
      #
      # Example of staged chunk lock behavior:
      #
      # 1. mon_enter in write_step_by_step
      # 2. ShouldRetry occurs
      # 3. mon_exit in write_step_by_step
      # 4. mon_enter again in write_step_by_step (retry)
      # 5. passed to &block of write_step_by_step
      # 6. mon_enter in the block (write)
      # 7. mon_exit in write_step_by_step
      # 8. mon_exit in write

      assert_equal(mon_enter_counts_by_chunk.values, mon_exit_counts_by_chunk.values)
    end
  end

  sub_test_case 'standard format with configuration for test with lower chunk limit size' do
    setup do
      @p = create_buffer({"chunk_limit_size" => 1_280_000})
      @format = ->(e){e.to_msgpack_stream}
      @dm0 = dm0 = create_metadata(Time.parse('2016-04-11 16:00:00 +0000').to_i, nil, nil)
      # 1 record is 128bytes in msgpack stream
      @es0 = es0 = Fluent::ArrayEventStream.new([ [event_time('2016-04-11 16:00:01 +0000'), {"message" => "x" * (128 - 22)}] ] * 5000)
      (class << @p; self; end).module_eval do
        define_method(:resume) {
          staged = {
            dm0 => create_chunk_es(dm0, es0).staged!,
          }
          queued = []
          return staged, queued
        }
      end
      @p.start
    end

    test '#write appends event stream into staged chunk' do
      assert_equal [@dm0], @p.stage.keys
      assert_equal [], @p.queue.map(&:metadata)

      assert_equal 1_280_000, @p.chunk_limit_size

      es = Fluent::ArrayEventStream.new([ [event_time('2016-04-11 16:00:02 +0000'), {"message" => "x" * (128 - 22)}] ] * 1000)
      @p.write({@dm0 => es}, format: @format)

      assert_equal [@dm0], @p.stage.keys
      assert_equal [], @p.queue.map(&:metadata)

      assert_equal (@es0.to_msgpack_stream + es.to_msgpack_stream), @p.stage[@dm0].read
    end

    test '#write writes event stream into a new chunk with enqueueing existing chunk if event stream is larger than available space of existing chunk' do
      assert_equal [@dm0], @p.stage.keys
      assert_equal [], @p.queue.map(&:metadata)

      assert_equal 1_280_000, @p.chunk_limit_size

      es = Fluent::ArrayEventStream.new([ [event_time('2016-04-11 16:00:02 +0000'), {"message" => "x" * (128 - 22)}] ] * 8000)
      @p.write({@dm0 => es}, format: @format)

      assert_equal [@dm0], @p.stage.keys
      assert_equal [@dm0], @p.queue.map(&:metadata)

      assert_equal (es.to_msgpack_stream), @p.stage[@dm0].read
    end

    test '#write writes event stream into many chunks excluding staged chunk if event stream is larger than chunk limit size' do
      assert_equal [@dm0], @p.stage.keys
      assert_equal [], @p.queue.map(&:metadata)

      assert_equal 1_280_000, @p.chunk_limit_size

      es = Fluent::ArrayEventStream.new([ [event_time('2016-04-11 16:00:02 +0000'), {"message" => "x" * (128 - 22)}] ] * 45000)
      @p.write({@dm0 => es}, format: @format)

      # metadata whose seq is 4 is created, but overwrite with original metadata(seq=0) for next use of this chunk https://github.com/fluent/fluentd/blob/9d113029d4550ce576d8825bfa9612aa3e55bff0/lib/fluent/plugin/buffer.rb#L357
      assert_equal [@dm0], @p.stage.keys
      assert_equal 5400, @p.stage[@dm0].size
      assert_equal [@dm0, @dm0, @dm0, @dm0, @dm0], @p.queue.map(&:metadata)
      assert_equal [5000, 9900, 9900, 9900, 9900], @p.queue.map(&:size) # splits: 45000 / 100 => 450 * ...
      # 9900 * 4 + 5400 == 45000
    end

    test '#dequeue_chunk succeeds when chunk is splited' do
      assert_equal [@dm0], @p.stage.keys
      assert_equal [], @p.queue.map(&:metadata)

      assert_equal 1_280_000, @p.chunk_limit_size

      es = Fluent::ArrayEventStream.new([ [event_time('2016-04-11 16:00:02 +0000'), {"message" => "x" * (128 - 22)}] ] * 45000)
      @p.write({@dm0 => es}, format: @format)
      @p.enqueue_all(true)

      dequeued_chunks = Array.new(6) { |e| @p.dequeue_chunk } # splits: 45000 / 100 => 450 * ...
      assert_equal [5000, 9900, 9900, 9900, 9900, 5400], dequeued_chunks.map(&:size)
      assert_equal [@dm0, @dm0, @dm0, @dm0, @dm0, @dm0], dequeued_chunks.map(&:metadata)
    end

    test '#write raises BufferChunkOverflowError if a record is biggar than chunk limit size' do
      assert_equal [@dm0], @p.stage.keys
      assert_equal [], @p.queue.map(&:metadata)

      assert_equal 1_280_000, @p.chunk_limit_size

      es = Fluent::ArrayEventStream.new([ [event_time('2016-04-11 16:00:02 +0000'), {"message" => "x" * 1_280_000}] ])
      assert_raise Fluent::Plugin::Buffer::BufferChunkOverflowError do
        @p.write({@dm0 => es}, format: @format)
      end
    end

    data(
      first_chunk: Fluent::ArrayEventStream.new([[event_time('2016-04-11 16:00:02 +0000'), {"message" => "x" * 1_280_000}],
                                                 [event_time('2016-04-11 16:00:02 +0000'), {"message" => "a"}],
                                                 [event_time('2016-04-11 16:00:02 +0000'), {"message" => "b"}]]),
      intermediate_chunk: Fluent::ArrayEventStream.new([[event_time('2016-04-11 16:00:02 +0000'), {"message" => "a"}],
                                                        [event_time('2016-04-11 16:00:02 +0000'), {"message" => "x" * 1_280_000}],
                                                        [event_time('2016-04-11 16:00:02 +0000'), {"message" => "b"}]]),
      last_chunk: Fluent::ArrayEventStream.new([[event_time('2016-04-11 16:00:02 +0000'), {"message" => "a"}],
                                                [event_time('2016-04-11 16:00:02 +0000'), {"message" => "b"}],
                                                [event_time('2016-04-11 16:00:02 +0000'), {"message" => "x" * 1_280_000}]]),
      multiple_chunks: Fluent::ArrayEventStream.new([[event_time('2016-04-11 16:00:02 +0000'), {"message" => "a"}],
                                                     [event_time('2016-04-11 16:00:02 +0000'), {"message" => "x" * 1_280_000}],
                                                     [event_time('2016-04-11 16:00:02 +0000'), {"message" => "b"}],
                                                     [event_time('2016-04-11 16:00:02 +0000'), {"message" => "x" * 1_280_000}]])
    )
    test '#write exceeds chunk_limit_size, raise BufferChunkOverflowError, but not lost whole messages' do |(es)|
      assert_equal [@dm0], @p.stage.keys
      assert_equal [], @p.queue.map(&:metadata)

      assert_equal 1_280_000, @p.chunk_limit_size

      nth = []
      es.entries.each_with_index do |entry, index|
        if entry.last["message"].size == @p.chunk_limit_size
          nth << index
        end
      end
      messages = []
      nth.each do |n|
        messages << "a 1280025 bytes record (nth: #{n}) is larger than buffer chunk limit size (1280000)"
      end

      assert_raise Fluent::Plugin::Buffer::BufferChunkOverflowError.new(messages.join(", ")) do
        @p.write({@dm0 => es}, format: @format)
      end
      # message a and b are concatenated and staged
      staged_messages = Fluent::MessagePackFactory.msgpack_unpacker.feed_each(@p.stage[@dm0].chunk).collect do |record|
        record.last
      end
      assert_equal([2, [{"message" => "a"}, {"message" => "b"}]],
                   [@p.stage[@dm0].size, staged_messages])
      # only es0 message is queued
      assert_equal [@dm0], @p.queue.map(&:metadata)
      assert_equal [5000], @p.queue.map(&:size)
    end

    test "confirm that every message which is smaller than chunk threshold does not raise BufferChunkOverflowError" do
      assert_equal [@dm0], @p.stage.keys
      assert_equal [], @p.queue.map(&:metadata)
      timestamp = event_time('2016-04-11 16:00:02 +0000')
      es = Fluent::ArrayEventStream.new([[timestamp, {"message" => "a" * 1_000_000}],
                                         [timestamp, {"message" => "b" * 1_000_000}],
                                         [timestamp, {"message" => "c" * 1_000_000}]])

      # https://github.com/fluent/fluentd/issues/1849
      # Even though 1_000_000 < 1_280_000 (chunk_limit_size), it raised BufferChunkOverflowError before.
      # It should not be raised and message a,b,c should be stored into 3 chunks.
      assert_nothing_raised do
        @p.write({@dm0 => es}, format: @format)
      end
      messages = []
      # pick up first letter to check whether chunk is queued in expected order
      3.times do |index|
        chunk = @p.queue[index]
        es = Fluent::MessagePackEventStream.new(chunk.chunk)
        es.ensure_unpacked!
        records = es.instance_eval{ @unpacked_records }
        records.each do |record|
          messages << record["message"][0]
        end
      end
      es = Fluent::MessagePackEventStream.new(@p.stage[@dm0].chunk)
      es.ensure_unpacked!
      staged_message = es.instance_eval{ @unpacked_records }.first["message"]
      # message a and b are queued, message c is staged
      assert_equal([
                     [@dm0],
                     "c" * 1_000_000,
                     [@dm0, @dm0, @dm0],
                     [5000, 1, 1],
                     [["x"] * 5000, "a", "b"].flatten
                   ],
                   [
                     @p.stage.keys,
                     staged_message,
                     @p.queue.map(&:metadata),
                     @p.queue.map(&:size),
                     messages
                   ])
    end
  end

  sub_test_case 'custom format with configuration for test with lower chunk limit size' do
    setup do
      @p = create_buffer({"chunk_limit_size" => 1_280_000})
      @dm0 = dm0 = create_metadata(Time.parse('2016-04-11 16:00:00 +0000').to_i, nil, nil)
      @row = "x" * 128
      @data0 = data0 = [@row] * 5000
      (class << @p; self; end).module_eval do
        define_method(:resume) {
          staged = {
            dm0 => create_chunk(dm0, data0).staged!,
          }
          queued = []
          return staged, queued
        }
      end
      @p.start
    end

    test '#write appends event stream into staged chunk' do
      assert_equal [@dm0], @p.stage.keys
      assert_equal [], @p.queue.map(&:metadata)

      assert_equal 1_280_000, @p.chunk_limit_size

      data = [@row] * 1000
      @p.write({@dm0 => data})

      assert_equal [@dm0], @p.stage.keys
      assert_equal [], @p.queue.map(&:metadata)

      assert_equal (@row * 6000), @p.stage[@dm0].read
    end

    test '#write writes event stream into a new chunk with enqueueing existing chunk if event stream is larger than available space of existing chunk' do
      assert_equal [@dm0], @p.stage.keys
      assert_equal [], @p.queue.map(&:metadata)

      staged_chunk_object_id = @p.stage[@dm0].object_id

      assert_equal 1_280_000, @p.chunk_limit_size

      data = [@row] * 8000
      @p.write({@dm0 => data})

      assert_equal [@dm0], @p.queue.map(&:metadata)
      assert_equal [staged_chunk_object_id], @p.queue.map(&:object_id)
      assert_equal [@dm0], @p.stage.keys

      assert_equal [9800], @p.queue.map(&:size)
      assert_equal 3200, @p.stage[@dm0].size
      # 9800 + 3200 == 5000 + 8000
    end

    test '#write writes event stream into many chunks including staging chunk if event stream is larger than chunk limit size' do
      assert_equal [@dm0], @p.stage.keys
      assert_equal [], @p.queue.map(&:metadata)

      staged_chunk_object_id = @p.stage[@dm0].object_id

      assert_equal 1_280_000, @p.chunk_limit_size

      assert_equal 5000, @p.stage[@dm0].size

      data = [@row] * 45000
      @p.write({@dm0 => data})

      assert_equal staged_chunk_object_id, @p.queue.first.object_id

      assert_equal [@dm0], @p.stage.keys
      assert_equal 900, @p.stage[@dm0].size
      assert_equal [@dm0, @dm0, @dm0, @dm0, @dm0], @p.queue.map(&:metadata)
      assert_equal [9500, 9900, 9900, 9900, 9900], @p.queue.map(&:size) # splits: 45000 / 100 => 450 * ...
      ##### 900 + 9500 + 9900 * 4 == 5000 + 45000
    end

    test '#write raises BufferChunkOverflowError if a record is bigger than chunk limit size' do
      assert_equal [@dm0], @p.stage.keys
      assert_equal [], @p.queue.map(&:metadata)

      assert_equal 1_280_000, @p.chunk_limit_size

      es = ["x" * 1_280_000 + "x" * 300]
      assert_raise Fluent::Plugin::Buffer::BufferChunkOverflowError do
        @p.write({@dm0 => es})
      end
    end

    test 'confirm that every array message which is smaller than chunk threshold does not raise BufferChunkOverflowError' do
      assert_equal [@dm0], @p.stage.keys
      assert_equal [], @p.queue.map(&:metadata)

      assert_equal 1_280_000, @p.chunk_limit_size

      es = ["a" * 1_000_000, "b" * 1_000_000, "c" * 1_000_000]
      assert_nothing_raised do
        @p.write({@dm0 => es})
      end
      queue_messages = @p.queue.collect do |chunk|
        # collect first character of each message
        chunk.chunk[0]
      end
      assert_equal([
                     [@dm0],
                     1,
                     "c",
                     [@dm0, @dm0, @dm0],
                     [5000, 1, 1],
                     ["x", "a", "b"]
                   ],
                   [
                     @p.stage.keys,
                     @p.stage[@dm0].size,
                     @p.stage[@dm0].chunk[0],
                     @p.queue.map(&:metadata),
                     @p.queue.map(&:size),
                     queue_messages
                   ])
    end
  end

  sub_test_case 'with configuration for test with lower limits' do
    setup do
      @p = create_buffer({"chunk_limit_size" => 1024, "total_limit_size" => 10240})
      @dm0 = dm0 = create_metadata(Time.parse('2016-04-11 16:00:00 +0000').to_i, nil, nil)
      @dm1 = dm1 = create_metadata(Time.parse('2016-04-11 16:10:00 +0000').to_i, nil, nil)
      @dm2 = dm2 = create_metadata(Time.parse('2016-04-11 16:20:00 +0000').to_i, nil, nil)
      @dm3 = dm3 = create_metadata(Time.parse('2016-04-11 16:30:00 +0000').to_i, nil, nil)
      (class << @p; self; end).module_eval do
        define_method(:resume) {
          staged = {
            dm2 => create_chunk(dm2, ["b" * 128] * 7).staged!,
            dm3 => create_chunk(dm3, ["c" * 128] * 5).staged!,
          }
          queued = [
            create_chunk(dm0, ["0" * 128] * 8).enqueued!,
            create_chunk(dm0, ["0" * 128] * 8).enqueued!,
            create_chunk(dm0, ["0" * 128] * 8).enqueued!,
            create_chunk(dm0, ["0" * 128] * 8).enqueued!,
            create_chunk(dm0, ["0" * 128] * 8).enqueued!,
            create_chunk(dm1, ["a" * 128] * 8).enqueued!,
            create_chunk(dm1, ["a" * 128] * 8).enqueued!,
            create_chunk(dm1, ["a" * 128] * 8).enqueued!, # 8th queued chunk
            create_chunk(dm1, ["a" * 128] * 3).enqueued!,
          ]
          return staged, queued
        }
      end
      @p.start
    end

    test '#storable? returns false when too many data exist' do
      assert_equal [@dm0,@dm0,@dm0,@dm0,@dm0,@dm1,@dm1,@dm1,@dm1], @p.queue.map(&:metadata)
      assert_equal [@dm2,@dm3], @p.stage.keys

      assert_equal 128*8*8+128*3, @p.queue_size
      assert_equal 128*7+128*5, @p.stage_size

      assert @p.storable?

      dm3 = @p.metadata(timekey: @dm3.timekey)
      @p.write({dm3 => ["c" * 128]})

      assert_equal 10240, (@p.stage_size + @p.queue_size)
      assert !@p.storable?
    end

    test '#chunk_size_over? returns true if chunk size is bigger than limit' do
      m = create_metadata(Time.parse('2016-04-11 16:40:00 +0000').to_i)

      c1 = create_chunk(m, ["a" * 128] * 8)
      assert !@p.chunk_size_over?(c1)

      c2 = create_chunk(m, ["a" * 128] * 9)
      assert @p.chunk_size_over?(c2)

      c3 = create_chunk(m, ["a" * 128] * 8 + ["a"])
      assert @p.chunk_size_over?(c3)
    end

    test '#chunk_size_full? returns true if chunk size is enough big against limit' do
      m = create_metadata(Time.parse('2016-04-11 16:40:00 +0000').to_i)

      c1 = create_chunk(m, ["a" * 128] * 7)
      assert !@p.chunk_size_full?(c1)

      c2 = create_chunk(m, ["a" * 128] * 8)
      assert @p.chunk_size_full?(c2)

      assert_equal 0.95, @p.chunk_full_threshold
      c3 = create_chunk(m, ["a" * 128] * 6 + ["a" * 64])
      assert !@p.chunk_size_full?(c3)
    end
  end

  sub_test_case 'with configuration includes chunk_limit_records' do
    setup do
      @p = create_buffer({"chunk_limit_size" => 1024, "total_limit_size" => 10240, "chunk_limit_records" => 6})
      @dm0 = dm0 = create_metadata(Time.parse('2016-04-11 16:00:00 +0000').to_i, nil, nil)
      @dm1 = dm1 = create_metadata(Time.parse('2016-04-11 16:10:00 +0000').to_i, nil, nil)
      @dm2 = dm2 = create_metadata(Time.parse('2016-04-11 16:20:00 +0000').to_i, nil, nil)
      @dm3 = dm3 = create_metadata(Time.parse('2016-04-11 16:30:00 +0000').to_i, nil, nil)
      (class << @p; self; end).module_eval do
        define_method(:resume) {
          staged = {
            dm2 => create_chunk(dm2, ["b" * 128] * 1).staged!,
            dm3 => create_chunk(dm3, ["c" * 128] * 2).staged!,
          }
          queued = [
            create_chunk(dm0, ["0" * 128] * 6).enqueued!,
            create_chunk(dm1, ["a" * 128] * 6).enqueued!,
            create_chunk(dm1, ["a" * 128] * 6).enqueued!,
            create_chunk(dm1, ["a" * 128] * 3).enqueued!,
          ]
          return staged, queued
        }
      end
      @p.start
    end

    test '#chunk_size_over? returns true if too many records exists in a chunk even if its bytes is less than limit' do
      assert_equal 6, @p.chunk_limit_records

      m = create_metadata(Time.parse('2016-04-11 16:40:00 +0000').to_i)

      c1 = create_chunk(m, ["a" * 128] * 6)
      assert_equal 6, c1.size
      assert !@p.chunk_size_over?(c1)

      c2 = create_chunk(m, ["a" * 128] * 7)
      assert @p.chunk_size_over?(c2)

      c3 = create_chunk(m, ["a" * 128] * 6 + ["a"])
      assert @p.chunk_size_over?(c3)
    end

    test '#chunk_size_full? returns true if enough many records exists in a chunk even if its bytes is less than limit' do
      assert_equal 6, @p.chunk_limit_records

      m = create_metadata(Time.parse('2016-04-11 16:40:00 +0000').to_i)

      c1 = create_chunk(m, ["a" * 128] * 5)
      assert_equal 5, c1.size
      assert !@p.chunk_size_full?(c1)

      c2 = create_chunk(m, ["a" * 128] * 6)
      assert @p.chunk_size_full?(c2)

      c3 = create_chunk(m, ["a" * 128] * 5 + ["a"])
      assert @p.chunk_size_full?(c3)
    end
  end

  sub_test_case 'with configuration includes queue_limit_length' do
    setup do
      @p = create_buffer({"chunk_limit_size" => 1024, "total_limit_size" => 10240, "queue_limit_length" => 5})
      @dm0 = dm0 = create_metadata(Time.parse('2016-04-11 16:00:00 +0000').to_i, nil, nil)
      @dm1 = dm1 = create_metadata(Time.parse('2016-04-11 16:10:00 +0000').to_i, nil, nil)
      @dm2 = dm2 = create_metadata(Time.parse('2016-04-11 16:20:00 +0000').to_i, nil, nil)
      @dm3 = dm3 = create_metadata(Time.parse('2016-04-11 16:30:00 +0000').to_i, nil, nil)
      (class << @p; self; end).module_eval do
        define_method(:resume) {
          staged = {
            dm2 => create_chunk(dm2, ["b" * 128] * 1).staged!,
            dm3 => create_chunk(dm3, ["c" * 128] * 2).staged!,
          }
          queued = [
            create_chunk(dm0, ["0" * 128] * 6).enqueued!,
            create_chunk(dm1, ["a" * 128] * 6).enqueued!,
            create_chunk(dm1, ["a" * 128] * 6).enqueued!,
            create_chunk(dm1, ["a" * 128] * 3).enqueued!,
          ]
          return staged, queued
        }
      end
      @p.start
    end

    test '#configure will overwrite standard configuration if queue_limit_length' do
      assert_equal 1024, @p.chunk_limit_size
      assert_equal 5, @p.queue_limit_length
      assert_equal (1024*5), @p.total_limit_size
    end
  end

  sub_test_case 'when compress is gzip' do
    setup do
      @p = create_buffer({'compress' => 'gzip'})
      @dm0 = create_metadata(Time.parse('2016-04-11 16:00:00 +0000').to_i, nil, nil)
    end

    test '#compress returns :gzip' do
      assert_equal :gzip, @p.compress
    end

    test 'create decompressable chunk' do
      chunk = @p.generate_chunk(create_metadata)
      assert chunk.singleton_class.ancestors.include?(Fluent::Plugin::Buffer::Chunk::GzipDecompressable)
    end

    test '#write compressed data which exceeds chunk_limit_size, it raises BufferChunkOverflowError' do
      @p = create_buffer({'compress' => 'gzip', 'chunk_limit_size' => 70})
      timestamp = event_time('2016-04-11 16:00:02 +0000')
      es = Fluent::ArrayEventStream.new([[timestamp, {"message" => "012345"}], # overflow
                                         [timestamp, {"message" => "aaa"}],
                                         [timestamp, {"message" => "bbb"}]])
      assert_equal [], @p.queue.map(&:metadata)
      assert_equal 70, @p.chunk_limit_size

      # calculate the actual boundary value. it varies on machine
      c = @p.generate_chunk(create_metadata)
      c.append(Fluent::ArrayEventStream.new([[timestamp, {"message" => "012345"}]]), compress: :gzip)
      overflow_bytes = c.bytesize

      messages = "concatenated/appended a #{overflow_bytes} bytes record (nth: 0) is larger than buffer chunk limit size (70)"
      assert_raise Fluent::Plugin::Buffer::BufferChunkOverflowError.new(messages) do
        # test format == nil && compress == :gzip
        @p.write({@dm0 => es})
      end
      # message a and b occupies each chunks in full, so both of messages are queued (no staged chunk)
      assert_equal([2, [@dm0, @dm0], [1, 1], nil],
                   [@p.queue.size, @p.queue.map(&:metadata), @p.queue.map(&:size), @p.stage[@dm0]])
    end
  end

  sub_test_case '#statistics' do
    setup do
      @p = create_buffer({ "total_limit_size" => 1024 })
      dm = create_metadata(Time.parse('2020-03-13 16:00:00 +0000').to_i, nil, nil)

      (class << @p; self; end).module_eval do
        define_method(:resume) {
          queued = [create_chunk(dm, ["a" * (1024 - 102)]).enqueued!]
          return {}, queued
        }
      end

      @p.start
    end

    test 'returns available_buffer_space_ratios' do
      assert_equal 10.0, @p.statistics['buffer']['available_buffer_space_ratios']
    end
  end
end

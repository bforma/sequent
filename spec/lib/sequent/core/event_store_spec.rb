# frozen_string_literal: true

require 'spec_helper'
require 'sequent/support'
require 'postgresql_cursor'

describe Sequent::Core::EventStore do
  class MyEvent < Sequent::Core::Event
  end

  class MyAggregate < Sequent::Core::AggregateRoot
  end

  let(:event_store) { Sequent.configuration.event_store }
  let(:aggregate_id) { Sequent.new_uuid }

  context '.configure' do
    it 'can be configured using a ActiveRecord class' do
      Sequent.configuration.stream_record_class = :foo
      expect(Sequent.configuration.stream_record_class).to eq :foo
    end

    it 'can be configured with event_handlers' do
      event_handler_class = Class.new
      Sequent.configure do |config|
        config.event_handlers = [event_handler_class]
      end
      expect(Sequent.configuration.event_handlers).to eq [event_handler_class]
    end

    it 'configuring a second time will reset the configuration' do
      foo = Class.new
      bar = Class.new
      Sequent.configure do |config|
        config.event_handlers = [foo]
      end
      expect(Sequent.configuration.event_handlers).to eq [foo]
      Sequent.configure do |config|
        config.event_handlers << bar
      end
      expect(Sequent.configuration.event_handlers).to eq [bar]
    end
  end

  context 'snapshotting' do
    let(:snapshot_threshold) { 1 }
    before do
      event_store.commit_events(
        Sequent::Core::Command.new(aggregate_id: aggregate_id),
        [
          [
            Sequent::Core::EventStream.new(
              aggregate_type: 'MyAggregate',
              aggregate_id: aggregate_id,
              snapshot_threshold: snapshot_threshold,
            ),
            [
              MyEvent.new(
                aggregate_id: aggregate_id,
                sequence_number: 1,
                created_at: Time.parse('2024-02-29T01:10:12Z'),
                data: "with ' unsafe SQL characters;\n",
              ),
            ],
          ],
        ],
      )
    end

    it 'can store events' do
      stream, events = event_store.load_events aggregate_id

      expect(stream.snapshot_threshold).to eq(1)
      expect(stream.aggregate_type).to eq('MyAggregate')
      expect(stream.aggregate_id).to eq(aggregate_id)
      expect(events.first.aggregate_id).to eq(aggregate_id)
      expect(events.first.sequence_number).to eq(1)
    end

    it 'can find streams that need snapshotting' do
      expect(event_store.aggregates_that_need_snapshots(nil)).to include(aggregate_id)
    end

    it 'can store and delete snapshots' do
      aggregate = MyAggregate.new(aggregate_id)
      snapshot = aggregate.take_snapshot
      snapshot.created_at = Time.parse('2024-02-28T04:12:33Z')

      event_store.store_snapshots([snapshot])

      expect(event_store.load_latest_snapshot(aggregate_id)).to eq(snapshot)

      event_store.delete_snapshots_before(aggregate_id, snapshot.sequence_number + 1)
      expect(event_store.load_latest_snapshot(aggregate_id)).to eq(nil)
    end
  end

  describe '#commit_events' do
    it 'fails with OptimisticLockingError when RecordNotUnique' do
      expect do
        event_store.commit_events(
          Sequent::Core::Command.new(aggregate_id: aggregate_id),
          [
            [
              Sequent::Core::EventStream.new(
                aggregate_type: 'MyAggregate',
                aggregate_id: aggregate_id,
                snapshot_threshold: 13,
              ),
              [
                MyEvent.new(aggregate_id: aggregate_id, sequence_number: 1),
                MyEvent.new(aggregate_id: aggregate_id, sequence_number: 1),
              ],
            ],
          ],
        )
      end.to raise_error(Sequent::Core::EventStore::OptimisticLockingError) { |error|
        expect(error.cause).to be_a(ActiveRecord::RecordNotUnique)
      }
    end
  end

  describe '#events_exists?' do
    it 'gets true for an existing aggregate' do
      event_store.commit_events(
        Sequent::Core::Command.new(aggregate_id: aggregate_id),
        [
          [
            Sequent::Core::EventStream.new(
              aggregate_type: 'MyAggregate',
              aggregate_id: aggregate_id,
              snapshot_threshold: 13,
            ),
            [MyEvent.new(aggregate_id: aggregate_id, sequence_number: 1)],
          ],
        ],
      )
      expect(event_store.events_exists?(aggregate_id)).to eq(true)
    end

    it 'gets false for an non-existing aggregate' do
      expect(event_store.events_exists?(aggregate_id)).to eq(false)
    end
  end

  describe '#stream_exists?' do
    it 'gets true for an existing aggregate' do
      event_store.commit_events(
        Sequent::Core::Command.new(aggregate_id: aggregate_id),
        [
          [
            Sequent::Core::EventStream.new(
              aggregate_type: 'MyAggregate',
              aggregate_id: aggregate_id,
              snapshot_threshold: 13,
            ),
            [MyEvent.new(aggregate_id: aggregate_id, sequence_number: 1)],
          ],
        ],
      )
      expect(event_store.stream_exists?(aggregate_id)).to eq(true)
    end

    it 'gets false for an non-existing aggregate' do
      expect(event_store.stream_exists?(aggregate_id)).to eq(false)
    end
  end

  describe '#load_events' do
    it 'returns nil for non existing aggregates' do
      stream, events = event_store.load_events(aggregate_id)
      expect(stream).to be_nil
      expect(events).to be_nil
    end

    it 'returns the stream and events for existing aggregates' do
      event_store.commit_events(
        Sequent::Core::Command.new(aggregate_id: aggregate_id),
        [
          [
            Sequent::Core::EventStream.new(aggregate_type: 'MyAggregate', aggregate_id: aggregate_id),
            [MyEvent.new(aggregate_id: aggregate_id, sequence_number: 1)],
          ],
        ],
      )
      stream, events = event_store.load_events(aggregate_id)
      expect(stream).to be
      expect(events).to be
    end

    context 'and event type caching disabled' do
      around do |example|
        current = Sequent.configuration.event_store_cache_event_types

        Sequent.configuration.event_store_cache_event_types = false

        example.run
      ensure
        Sequent.configuration.event_store_cache_event_types = current
      end
      let(:event_store) { Sequent::Core::EventStore.new }

      it 'returns the stream and events for existing aggregates' do
        TestEventForCaching = Class.new(Sequent::Core::Event)

        event_store.commit_events(
          Sequent::Core::Command.new(aggregate_id: aggregate_id),
          [
            [
              Sequent::Core::EventStream.new(aggregate_type: 'MyAggregate', aggregate_id: aggregate_id),
              [TestEventForCaching.new(aggregate_id: aggregate_id, sequence_number: 1)],
            ],
          ],
        )
        stream, events = event_store.load_events(aggregate_id)
        expect(stream).to be
        expect(events.first).to be_kind_of(TestEventForCaching)

        # redefine TestEventForCaching class (ie. simulate Rails auto-loading)
        OldTestEventForCaching = TestEventForCaching
        TestEventForCaching = Class.new(Sequent::Core::Event)

        stream, events = event_store.load_events(aggregate_id)
        expect(stream).to be
        expect(events.first).to be_kind_of(TestEventForCaching)

        expect(event_store.load_event(aggregate_id, events.first.sequence_number)).to eq(events.first)
      end
    end
  end

  describe '#load_events_for_aggregates' do
    let(:aggregate_id_1) { Sequent.new_uuid }
    let(:aggregate_id_2) { Sequent.new_uuid }

    before :each do
      event_store.commit_events(
        Sequent::Core::Command.new(aggregate_id: aggregate_id),
        [
          [
            Sequent::Core::EventStream.new(aggregate_type: 'MyAggregate', aggregate_id: aggregate_id_1),
            [MyEvent.new(aggregate_id: aggregate_id_1, sequence_number: 1)],
          ],
          [
            Sequent::Core::EventStream.new(aggregate_type: 'MyAggregate', aggregate_id: aggregate_id_2),
            [MyEvent.new(aggregate_id: aggregate_id_2, sequence_number: 1)],
          ],
        ],
      )
    end
    it 'returns the stream and events for multiple aggregates' do
      streams_with_events = event_store.load_events_for_aggregates([aggregate_id_1, aggregate_id_2])

      expect(streams_with_events).to have(2).items
      expect(streams_with_events[0]).to have(2).items
      expect(streams_with_events[1]).to have(2).items
    end
  end

  describe 'stream events for aggregate' do
    let(:aggregate_id_1) { Sequent.new_uuid }
    let(:frozen_time) { Time.parse('2022-02-08 14:15:00 +0200') }
    let(:event_stream) { instance_of(Sequent::Core::EventStream) }
    let(:event_1) { MyEvent.new(aggregate_id: aggregate_id_1, sequence_number: 1, created_at: frozen_time) }
    let(:event_2) do
      MyEvent.new(aggregate_id: aggregate_id_1, sequence_number: 2, created_at: frozen_time + 5.minutes)
    end
    let(:event_3) do
      MyEvent.new(aggregate_id: aggregate_id_1, sequence_number: 3, created_at: frozen_time + 10.minutes)
    end
    let(:snapshot_event) do
      Sequent::Core::SnapshotEvent.new(
        aggregate_id: aggregate_id_1,
        sequence_number: 3,
        created_at: frozen_time + 8.minutes,
      )
    end

    context 'with a snapshot event' do
      before :each do
        event_store.commit_events(
          Sequent::Core::Command.new(aggregate_id: aggregate_id),
          [
            [
              Sequent::Core::EventStream.new(
                aggregate_type: 'MyAggregate',
                aggregate_id: aggregate_id_1,
              ),
              [
                event_1,
                event_2,
                event_3,
              ],
            ],
          ],
        )
        event_store.store_snapshots([snapshot_event])
      end

      context 'returning events except snapshot events in order of sequence_number' do
        it 'all events up until now' do
          expect do |block|
            event_store.stream_events_for_aggregate(aggregate_id_1, load_until: Time.now, &block)
          end.to yield_successive_args([event_stream, event_1], [event_stream, event_2], [event_stream, event_3])
        end

        it 'all events if no load_until is passed' do
          expect do |block|
            event_store.stream_events_for_aggregate(aggregate_id_1, &block)
          end.to yield_successive_args([event_stream, event_1], [event_stream, event_2], [event_stream, event_3])
        end

        it 'events up until the specified time for the aggregate' do
          expect do |block|
            event_store.stream_events_for_aggregate(aggregate_id_1, load_until: frozen_time + 1.minute, &block)
          end.to yield_successive_args([event_stream, event_1])
        end
      end

      context 'failure' do
        it 'argument error for no events' do
          expect do |block|
            event_store.stream_events_for_aggregate(aggregate_id_1, load_until: frozen_time - 1.year, &block)
          end.to raise_error(ArgumentError, 'no events for this aggregate')
        end
      end

      it 'returns all events from the snapshot onwards for #load_events_for_aggregates' do
        streamed_events = event_store.load_events_for_aggregates([aggregate_id_1])
        expect(streamed_events).to have(1).items
        expect(streamed_events[0]).to have(2).items
        expect(streamed_events[0][1]).to have(2).items
      end
    end
  end

  describe 'error handling for publishing events' do
    class TestRecord; end
    class RecordingHandler < Sequent::Core::Projector
      manages_tables TestRecord
      attr_reader :recorded_events

      def initialize
        super
        @recorded_events = []
      end

      on MyEvent do |e|
        @recorded_events << e
      end
    end

    class TestRecord; end
    class FailingHandler < Sequent::Core::Projector
      manages_tables TestRecord
      Error = Class.new(RuntimeError)

      on MyEvent do |_|
        fail Error, 'Handler error'
      end
    end

    before do
      Sequent.configure do |c|
        c.event_handlers << handler
      end
    end

    context 'given a handler for MyEvent' do
      let(:handler) { RecordingHandler.new }

      it 'calls an event handler that handles the event' do
        my_event = MyEvent.new(aggregate_id: aggregate_id, sequence_number: 1)
        event_store.commit_events(
          Sequent::Core::Command.new(aggregate_id: aggregate_id),
          [
            [
              Sequent::Core::EventStream.new(
                aggregate_type: 'MyAggregate',
                aggregate_id: aggregate_id,
                snapshot_threshold: 13,
              ),
              [my_event],
            ],
          ],
        )
        expect(handler.recorded_events).to eq([my_event])
      end

      context 'Sequent.configuration.disable_event_handlers = true' do
        it 'does not publish any events' do
          Sequent.configuration.disable_event_handlers = true
          my_event = MyEvent.new(aggregate_id: aggregate_id, sequence_number: 1)
          event_store.commit_events(
            Sequent::Core::Command.new(aggregate_id: aggregate_id),
            [
              [
                Sequent::Core::EventStream.new(
                  aggregate_type: 'MyAggregate',
                  aggregate_id: aggregate_id,
                  snapshot_threshold: 13,
                ),
                [my_event],
              ],
            ],
          )
          expect(handler.recorded_events).to eq([])
        end
      end
    end

    context 'given a failing event handler' do
      let(:handler) { FailingHandler.new }
      let(:my_event) { MyEvent.new(aggregate_id: aggregate_id, sequence_number: 1) }
      subject(:publish_error) do
        event_store.commit_events(
          Sequent::Core::Command.new(aggregate_id: aggregate_id),
          [
            [
              Sequent::Core::EventStream.new(
                aggregate_type: 'MyAggregate',
                aggregate_id: aggregate_id,
                snapshot_threshold: 13,
              ),
              [my_event],
            ],
          ],
        )
      rescue StandardError => e
        e
      end

      it { is_expected.to be_a(Sequent::Core::EventPublisher::PublishEventError) }

      it 'preserves its cause' do
        expect(publish_error.cause).to be_a(FailingHandler::Error)
        expect(publish_error.cause.message).to eq('Handler error')
      end

      it 'specifies the event handler that failed' do
        expect(publish_error.event_handler_class).to eq(FailingHandler)
      end

      it 'specifies the event that failed' do
        expect(publish_error.event).to eq(my_event)
      end
    end
  end

  describe '#replay_events_from_cursor' do
    let(:stream_record) do
      Sequent::Core::StreamRecord.create!(
        aggregate_type: 'Sequent::Core::AggregateRoot',
        aggregate_id: aggregate_id,
        created_at: DateTime.now,
      )
    end
    let(:command_record) do
      Sequent::Core::CommandRecord.create!(
        command_type: 'Sequent::Core::Command',
        command_json: '{}',
        aggregate_id: stream_record.aggregate_id,
      )
    end

    let(:get_events) do
      -> do
        event_records = Sequent.configuration.event_record_class.table_name
        stream_records = Sequent.configuration.stream_record_class.table_name
        snapshot_event_type = Sequent.configuration.snapshot_event_class
        Sequent.configuration.event_record_class
          .select('event_type, event_json')
          .joins("INNER JOIN #{stream_records} ON #{event_records}.aggregate_id = #{stream_records}.aggregate_id")
          .where('event_type <> ?', snapshot_event_type)
          .order!("#{stream_records}.aggregate_id, #{event_records}.sequence_number")
      end
    end

    before do
      Sequent::Core::EventRecord.delete_all
      5.times do |n|
        Sequent::Core::EventRecord.create!(
          aggregate_id: stream_record.aggregate_id,
          sequence_number: n + 1,
          event_type: 'Sequent::Core::Event',
          event_json: '{}',
          created_at: DateTime.now,
          command_record_id: command_record.id,
          stream_record: stream_record,
        )
      end
    end

    it 'publishes all events' do
      replay_counter = ReplayCounter.new
      Sequent.configuration.event_handlers << replay_counter
      event_store.replay_events_from_cursor(
        get_events: get_events,
        block_size: 2,
        on_progress: proc {},
      )
      expect(replay_counter.replay_count).to eq(Sequent::Core::EventRecord.count)
    end

    it 'reports progress for each block' do
      progress = 0
      progress_reported_count = 0
      on_progress = ->(n, _, _) do
        progress = n
        progress_reported_count += 1
      end
      event_store.replay_events_from_cursor(
        get_events: get_events,
        block_size: 2,
        on_progress: on_progress,
      )
      total_events = Sequent::Core::EventRecord.count
      expect(progress).to eq(total_events)
      expect(progress_reported_count).to eq((total_events / 2.0).ceil)
    end
  end

  class ReplayCounter < Sequent::Core::Projector
    attr_reader :replay_count

    manages_no_tables
    def initialize
      super
      @replay_count = 0
    end

    on Sequent::Core::Event do |_|
      @replay_count += 1
    end
  end

  describe '#permanently_delete_commands_without_events' do
    before do
      event_store.commit_events(
        Sequent::Core::Command.new(aggregate_id:),
        [
          [
            Sequent::Core::EventStream.new(
              aggregate_type: 'MyAggregate',
              aggregate_id:,
              snapshot_threshold: 13,
            ),
            [MyEvent.new(aggregate_id:, sequence_number: 1)],
          ],
        ],
      )
    end

    it 'does not delete commands with associated events' do
      event_store.permanently_delete_commands_without_events(aggregate_id:)
      expect(Sequent::Core::CommandRecord.exists?(aggregate_id:)).to be_truthy
    end

    it 'deletes commands without associated events' do
      event_store.permanently_delete_event_stream(aggregate_id)
      event_store.permanently_delete_commands_without_events(aggregate_id:)
      expect(Sequent::Core::CommandRecord.exists?(aggregate_id:)).to be_falsy
    end
  end
end

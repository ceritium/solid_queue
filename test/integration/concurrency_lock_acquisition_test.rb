# frozen_string_literal: true

require "test_helper"

class ConcurrencyLockAcquisitionTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  class NonOverlappingJob < ApplicationJob
    # Enqueued inside the transaction, which is what this is about.
    # Rails 7.2 takes :never rather than false.
    self.enqueue_after_transaction_commit = Rails.version.start_with?("7.2") ? :never : false if respond_to?(:enqueue_after_transaction_commit=)

    limits_concurrency key: ->(key) { key }

    def perform(key)
    end
  end

  setup do
    # SQLite allows a single writer at a time, so any enqueue waits for any open
    # write transaction, concurrency controls or not.
    skip "SQLite serializes all writes" if SolidQueue::Record.connection_pool.db_config.adapter == "sqlite3"
  end

  test "a job enqueued inside a transaction holds its concurrency lock until the transaction ends" do
    assert_not another_enqueue_completes_while_transaction_is_open?(acquire: :on_enqueue)
  end

  test "a job leaving its concurrency lock to the dispatcher doesn't hold it in the transaction" do
    assert another_enqueue_completes_while_transaction_is_open?(acquire: :outside_transaction)
  end

  private
    # Enqueues a job with `acquire` inside a transaction on Solid Queue's
    # connection, and keeps that transaction open while another thread enqueues
    # a job with the same concurrency key. Answers whether that second enqueue
    # completed before the transaction ended.
    def another_enqueue_completes_while_transaction_is_open?(acquire:)
      enqueued = Concurrent::Event.new
      other_enqueue_done = Concurrent::Event.new

      holder = Thread.new do
        SolidQueue::Record.connection_pool.with_connection do
          SolidQueue::Record.transaction do
            NonOverlappingJob.set(acquire: acquire).perform_later("shared")
            enqueued.set

            other_enqueue_done.wait(1.second)
            other_enqueue_done.set?
          end
        end
      end

      assert enqueued.wait(5.seconds), "The first job was never enqueued"
      NonOverlappingJob.perform_later("shared")
      other_enqueue_done.set

      holder.value
    end
end

# frozen_string_literal: true

module SolidQueue
  # Enqueues the jobs that Active Job defers until after commit
  # (enqueue_after_transaction_commit) together, in one transaction.
  #
  # Active Job enqueues each deferred job on its own once the transaction
  # commits, and each enqueue is then its own transaction. Here a deferred
  # job waits in a list for its thread, and the first one to come due
  # enqueues the whole list in one transaction. Each job still goes through
  # its enqueue callbacks and the adapter, and a job deferred in a
  # transaction or savepoint that rolls back is dropped, as Active Job
  # drops it.
  module DeferredEnqueue
    class << self
      def defer(job, options, transactions)
        pending = (ActiveSupport::IsolatedExecutionState[:solid_queue_deferred_enqueues] ||= [])
        deferred = [ job, options ]
        pending << deferred
        transactions.each { |transaction| transaction.after_rollback { pending.delete_if { |entry| entry.equal?(deferred) } } }

        # Registered for each job rather than once per list: a savepoint that
        # rolls back drops the callbacks registered in it.
        ActiveRecord.after_all_transactions_commit { flush }
      end

      def flush
        pending = ActiveSupport::IsolatedExecutionState.delete(:solid_queue_deferred_enqueues)
        return if pending.blank?

        SolidQueue::Record.transaction do
          BatchExecution.counting_jobs do
            pending.each { |job, options| job.enqueue_deferred(options) }
          end
        end
      end

      # The Active Job internals this relies on: Enqueuing#raw_enqueue runs the
      # enqueue callbacks around the adapter, below the after-commit deferral.
      def supported?
        ActiveRecord.respond_to?(:all_open_transactions) && ActiveJob::Enqueuing.private_method_defined?(:_raw_enqueue)
      end
    end

    # Enqueues now, with the options the job had when it was deferred, through
    # Active Job's own enqueue rather than its after-commit deferral, which
    # would defer it again inside the transaction enqueueing it.
    def enqueue_deferred(options) # :nodoc:
      previous = [ scheduled_at, queue_name, priority ]
      self.scheduled_at, self.queue_name, self.priority = options
      self.successfully_enqueued = false
      ActiveJob::Enqueuing.instance_method(:raw_enqueue).bind_call(self)
    ensure
      self.scheduled_at, self.queue_name, self.priority = previous
    end

    private
      def raw_enqueue
        transactions = deferring_until_commit? ? ActiveRecord.all_open_transactions : []
        return super if transactions.none?

        # As Active Job does: report the job enqueued now, and enqueue it with
        # the options it had when deferred.
        self.successfully_enqueued = true
        DeferredEnqueue.defer(self, [ scheduled_at, queue_name, priority ], transactions)

        self
      end

      def deferring_until_commit?
        self.class.queue_adapter_name == "solid_queue" && DeferredEnqueue.supported? &&
          self.class.enqueue_after_transaction_commit == true
      end
  end
end

# frozen_string_literal: true

# Inspired by active_job/core.rb docs
# https://github.com/rails/rails/blob/1c2529b9a6ba5a1eff58be0d0373d7d9d401015b/activejob/lib/active_job/core.rb#L136
module ActiveJob
  module JobBatchId
    extend ActiveSupport::Concern

    included do
      attr_accessor :batch_id, :bid

      after_discard do |job, error|
        # grab the workflow node and mark it as discarded?
      end
    end

    def serialize
      super.merge("batch_id" => batch_id, "bid" => Thread.current[:sidekiq_batch]&.bid)
    end

    def deserialize(job_data)
      super
      self.batch_id = job_data["batch_id"]
      self.bid = job_data["bid"]
    end

    def batch
      @batch ||= SolidQueue::JobBatch.find_by(id: batch_id)
    end

    def sidekiq_batch
      @sidekiq_batch ||= Sidekiq::Batch.new(bid)
    end
  end
end

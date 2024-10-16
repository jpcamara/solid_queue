Rails.application.config.x.solid_queue_record_hook_ran = false

ActiveSupport.on_load(:solid_queue_record) do
  raise "Expected to run on SolidQueue::Record, got #{self.inspect}" unless self == SolidQueue::Record
  Rails.application.config.x.solid_queue_record_hook_ran = true
end

# FIXME: load these automatically like acidic job? sidekiq workflow? one of those does it
#        and it's great
require "sidekiq"
require_relative "../../../../app/models/solid_queue/server_middleware.rb"
require_relative "../../../../app/models/solid_queue/client_middleware.rb"

# From sidekiq WIKI:
# (https://github.com/mperham/sidekiq/wiki/Middleware#sometimes-client-side-middleware-should-be-registered-
# in-both-places)
# Sometimes client-side middleware should be registered in both places.
# The jobs running in the Sidekiq server can themselves push new jobs to Sidekiq, thus acting as clients.
# You must configure your client middleware within the configure_server block also in that case
Sidekiq.configure_client do |config|
  config.client_middleware do |chain|
    chain.add ::SolidQueue::ClientMiddleware
  end
end

Sidekiq.configure_server do |config|
  config.client_middleware do |chain|
    chain.add ::SolidQueue::ClientMiddleware
  end

  config.server_middleware do |chain|
    chain.add ::SolidQueue::ServerMiddleware
  end

  # https://github.com/sidekiq/sidekiq/issues/4496#issuecomment-677838552
  config.death_handlers << -> (job, exception) do
    # worker = job["wrapped"].safe_constantize
    # worker&.sidekiq_retries_exhausted_block&.call(job, exception)
  end
end

# require 'sidekiq_adapter_extension'

# module SidekiqAdapterExtension
#   # included do
#   #   class << self
#   #     alias_method :original_enqueue, :enqueue

#   #     def enqueue(job)
#   #       # Custom logic before enqueue
#   #       Rails.logger.info "Custom logic before enqueue"

#   #       original_enqueue(job)

#   #       # Custom logic after enqueue
#   #       Rails.logger.info "Custom logic after enqueue"
#   #     end
#   #   end
#   # end
#   def enqueue(job) # :nodoc:
#     puts "we dun did it!!!!", "", "", "", "", ""
#     super
#   end

#   def enqueue_at(job, timestamp) # :nodoc:
#     puts "we dun did it", "", "", "", "", ""
#     super
#   end

#   def enqueue_all(jobs) # :nodoc:
#     puts "we dun did it ALL", "", "", "", "", ""
#     super
#   end
# end

# ActiveSupport.on_load(:active_job) do
#   ActiveJob::QueueAdapters::SidekiqAdapter.include(SidekiqAdapterExtension)
#   binding.pry
# end

Rails.application.config.to_prepare do
  unless defined?(OriginalAdapter)
    OriginalAdapter = ActiveJob::QueueAdapters::SidekiqAdapter
  end

  module ActiveJob
    module QueueAdapters
      class SidekiqAdapter
        def enqueue(job) # :nodoc:
          # OriginalAdapter.new.enqueue(job)
          job.provider_job_id = JobWrapper.set(
            wrapped: job.class,
            queue: job.queue_name
          ).perform_async(job.serialize)
        end

        def enqueue_at(job, timestamp) # :nodoc:
          # Sidekiq::Batch.current?
          if Thread.current[:sidekiq_batch].blank? && job.bid.present?
            batch = Sidekiq::Batch.new(job.bid)
            batch.jobs do
              # OriginalAdapter.new.enqueue_at(job, timestamp)
              job.provider_job_id = JobWrapper.set(
                wrapped: job.class,
                queue: job.queue_name,
              ).perform_at(timestamp, job.serialize)
            end
          else
            job.provider_job_id = JobWrapper.set(
              wrapped: job.class,
              queue: job.queue_name,
            ).perform_at(timestamp, job.serialize)
          end
        end

        def enqueue_all(jobs) # :nodoc:
          puts "WE ENQUEUED ALL #{jobs.map(&:job_id)}!"
          # OriginalAdapter.new.enqueue_all(jobs)
          enqueued_count = 0
          jobs.group_by(&:class).each do |job_class, same_class_jobs|
            same_class_jobs.group_by(&:queue_name).each do |queue, same_class_and_queue_jobs|
              immediate_jobs, scheduled_jobs = same_class_and_queue_jobs.partition { |job| job.scheduled_at.nil? }

              if immediate_jobs.any?
                jids = Sidekiq::Client.push_bulk(
                  "class" => JobWrapper,
                  "wrapped" => job_class,
                  "queue" => queue,
                  "args" => immediate_jobs.map { |job| [job.serialize] },
                )
                enqueued_count += jids.compact.size
              end

              if scheduled_jobs.any?
                jids = Sidekiq::Client.push_bulk(
                  "class" => JobWrapper,
                  "wrapped" => job_class,
                  "queue" => queue,
                  "args" => scheduled_jobs.map { |job| [job.serialize] },
                  "at" => scheduled_jobs.map { |job| job.scheduled_at&.to_f }
                )
                enqueued_count += jids.compact.size
              end
            end
          end
          enqueued_count
        end

        # class JobWrapper # :nodoc:
        #   include Sidekiq::Worker

        #   def perform(job_data)
        #     Base.execute job_data.merge("provider_job_id" => jid)
        #   end
        # end
      end
    end
  end
end

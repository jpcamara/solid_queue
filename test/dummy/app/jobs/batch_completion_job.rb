class BatchCompletionJob < ApplicationJob
  queue_as :background

  def perform(batch, arg1, arg2)
    Rails.logger.info "#{batch.jobs.size} jobs completed! #{arg1} #{arg2}"
  end
end

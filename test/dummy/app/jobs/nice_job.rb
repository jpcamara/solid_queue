class NiceJob < ApplicationJob
  retry_on Exception, wait: 1.second, attempts: 3
  # discard_on Oops

  sidekiq_options retry: 2

  self.queue_adapter = :good_job

  def perform(arg)
    # raise Oops # This triggers and on_success...
    puts "Hi #{arg}, from good job!", "", ""
    # raise "eek"
  end
end

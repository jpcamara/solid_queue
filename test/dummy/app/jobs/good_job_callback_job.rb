class GoodJobCallbackJob < ApplicationJob
  self.queue_adapter = :good_job

  # Callback jobs must accept a `batch` and `options` argument
  def perform(batch, params)
    puts "", "", "", "", "", "", "ok!", "", "", "", "", "", ""

    binding.pry
    # The batch object will contain the Batch's properties, which are mutable
    batch.properties[:user] # => <User id: 1, ...>

    # Params is a hash containing additional context (more may be added in the future)
    params[:event] # => :finish, :success, :discard
  end
end

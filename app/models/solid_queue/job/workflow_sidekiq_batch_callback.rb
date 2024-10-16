# frozen_string_literal: true

module SolidQueue
  class Job
    class WorkflowSidekiqBatchCallback
      # def on_complete(status, options)
      #   # options["workflow_id"]
      #   # options["workflow_level_id"]
      #   puts "", "", "on_complete #{options} #{status}", "", ""
      # end

      def on_success(status, options)
        puts "", "", "on_success #{options} #{status}", "", ""
      end

      def on_death(status, options)
        binding.pry
        puts "", "", "on_death #{options} #{status}"
      end
    end
  end
end

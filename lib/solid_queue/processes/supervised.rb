# frozen_string_literal: true

module SolidQueue::Processes
  module Supervised
    extend ActiveSupport::Concern

    included do
      attr_reader :supervisor
    end

    def supervised_by(process)
      @supervisor = process
    end

    private
      def set_procline
        procline "waiting"
      end

      def supervisor_went_away?
        supervised? && supervisor.pid != ::Process.ppid
      end

      def supervised?
        supervisor.present?
      end

      def create_fork(&block)
        # A forked process inherits the supervisor's open database connections,
        # sharing their sockets. With mysql2, releasing them in the forked
        # process can close the sockets of its own new connections, failing
        # their queries with EBADF. Close them first: each process opens its own.
        ActiveRecord::Base.connection_handler.clear_all_connections!(:all)

        fork do
          register_signal_handlers
          block.call
        end
      end

      def register_signal_handlers
        %w[ INT TERM ].each do |signal|
          trap(signal) do
            stop
          end
        end

        trap(:QUIT) do
          exit!
        end
      end
  end
end

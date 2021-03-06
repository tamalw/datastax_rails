module DatastaxRails
  module Cql
    # Base class for CQL generation
    class Base
      # Base initialize that sets the default consistency.
      def initialize(klass, *_args)
        @klass = klass
        @consistency = klass.default_consistency.to_s.downcase.to_sym
        @keyspace = DatastaxRails::Base.config[:keyspace]
        @values = []
      end

      def using(consistency)
        @consistency = consistency.to_s.downcase.to_sym
        self
      end

      # Abstract. Should be overridden by subclasses
      def to_cql
        fail NotImplementedError
      end

      # Generates the CQL and calls Cassandra to execute it.
      # If you are using this outside of Rails, then DatastaxRails::Base.connection must have
      # already been set up (Rails does this for you).
      def execute
        cql = to_cql.force_encoding('UTF-8')

        ActiveSupport::Notifications.instrument(
          'cql.datastax_rails',
          name:           'CQL',
          cql:            cql,
          klass:          @klass,
          connection_id:  DatastaxRails::Base.connection.object_id,
          statement_name: self.class.name,
          binds:          @values) do |payload|
          digest = Digest::MD5.digest cql
          try_again = true
          begin
            DatastaxRails::Base.reconnect unless DatastaxRails::Base.connection
            stmt = DatastaxRails::Base.statement_cache[digest] ||= DatastaxRails::Base.connection.prepare(cql)
            stmt = stmt.bind(@values)
            if @consistency
              results = DatastaxRails::Base.connection.execute(stmt, consistency: @consistency)
            else
              results = DatastaxRails::Base.connection.execute(stmt)
            end
            payload[:result_count] = results.respond_to?(:count) ? results.count : 'No'
            DatastaxRails::Base.current_server = results.execution_info.hosts.first.ip.to_s
            results
          rescue Cassandra::Errors::NoHostsAvailable
            if try_again
              Rails.logger.warn('Lost connection to Cassandra. Attempting to reconnect...')
              try_again = false
              DatastaxRails::Base.reconnect
              retry
            else
              raise
            end
          end
        end
      end
    end
  end
end

require 'active_record/connection_adapters/abstract_adapter'
require 'active_record/connection_adapters/postgresql_adapter'
require 'discourse'
require 'sidekiq/pausable'

class PostgreSQLFallbackHandler
  include Singleton

  attr_reader :masters_down
  attr_accessor :initialized

  def initialize
    @masters_down = DistributedCache.new('masters_down', namespace: false)
    @mutex = Mutex.new
    @initialized = false
  end

  def verify_master
    synchronize { return if @thread && @thread.alive? }

    @thread = Thread.new do
      while true do
        begin
          thread = Thread.new { initiate_fallback_to_master }
          thread.join
          break if synchronize { @masters_down.hash.empty? }
          sleep 10
        ensure
          thread.kill
        end
      end
    end

    @thread.abort_on_exception = true
  end

  def master_down?
    synchronize { @masters_down[namespace] }
  end

  def master_down=(args)
    synchronize do
      @masters_down[namespace] = args
      Sidekiq.pause! if args && !Sidekiq.paused?
    end
  end

  def master_up(namespace)
    synchronize { @masters_down.delete(namespace, publish: false) }
  end

  def initiate_fallback_to_master
    @masters_down.hash.keys.each do |key|
      RailsMultisite::ConnectionManagement.with_connection(key) do
        begin
          logger.warn "#{log_prefix}: Checking master server..."
          begin
            connection = ActiveRecord::Base.postgresql_connection(config)
            is_connection_active = connection.active?
          ensure
            connection.disconnect! if connection
          end

          if is_connection_active
            logger.warn "#{log_prefix}: Master server is active. Reconnecting..."
            ActiveRecord::Base.clear_active_connections!
            ActiveRecord::Base.clear_all_connections!
            self.master_up(key)
            disable_readonly_mode
            Sidekiq.unpause!
          end
        rescue => e
          logger.warn "#{log_prefix}: Connection to master PostgreSQL server failed with '#{e.message}'"
        end
      end
    end
  end

  # Use for testing
  def setup!
    @masters_down.clear
    disable_readonly_mode
  end

  private

  def disable_readonly_mode
    Discourse.disable_readonly_mode(Discourse::PG_READONLY_MODE_KEY)
  end

  def config
    ActiveRecord::Base.connection_config
  end

  def logger
    Rails.logger
  end

  def log_prefix
    "#{self.class} [#{namespace}]"
  end

  def namespace
    RailsMultisite::ConnectionManagement.current_db
  end

  def synchronize
    @mutex.synchronize { yield }
  end
end

module ActiveRecord
  module ConnectionHandling
    def postgresql_fallback_connection(config)
      fallback_handler = ::PostgreSQLFallbackHandler.instance
      config = config.symbolize_keys

      if fallback_handler.master_down?
        Discourse.enable_readonly_mode(Discourse::PG_READONLY_MODE_KEY)
        fallback_handler.verify_master

        connection = postgresql_connection(config.dup.merge(
          host: config[:replica_host],
          port: config[:replica_port]
        ))

        verify_replica(connection)
      else
        begin
          connection = postgresql_connection(config)
          fallback_handler.initialized ||= true
        rescue PG::ConnectionBad => e
          fallback_handler.master_down = true
          fallback_handler.verify_master

          if !fallback_handler.initialized
            return postgresql_fallback_connection(config)
          else
            raise e
          end
        end
      end

      connection
    end

    private

    def verify_replica(connection)
      value = connection.raw_connection.exec("SELECT pg_is_in_recovery()").values[0][0]
      raise "Replica database server is not in recovery mode." if !value
    end
  end
end

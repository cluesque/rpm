# encoding: utf-8
# This file is distributed under New Relic's license terms.
# See https://github.com/newrelic/rpm/blob/master/LICENSE for complete details.
require 'new_relic/agent/instrumentation/active_record_helper'

# Listen for ActiveSupport::Notifications events for ActiveRecord query
# events.  Write metric data, transaction trace segments and slow sql
# nodes for each event.
module NewRelic
  module Agent
    module Instrumentation
      class ActiveRecordSubscriber
        include NewRelic::Agent::Instrumentation

        def self.subscribed?
          # TODO: need to talk to Rails core about an API for this,
          # rather than digging through Listener ivars
          ActiveSupport::Notifications.notifier.listeners_for('sql.active_record') \
            .find{|l| l.instance_variable_get(:@delegate).class == self }
        end

        def call(*args)
          return unless NewRelic::Agent.is_execution_traced?

          event = ActiveSupport::Notifications::Event.new(*args)
          record_metrics(event)
          notice_sql(event)
        end

        def notice_sql(event)
          config = active_record_config_for_event(event)
          metric = base_metric(event)

          # enter transaction trace segment
          scope = NewRelic::Agent.instance.stats_engine.push_scope(metric, event.time)

          NewRelic::Agent.instance.transaction_sampler \
            .notice_sql(event.payload[:sql], config,
                        Helper.milliseconds_to_seconds(event.duration))

          NewRelic::Agent.instance.sql_sampler \
            .notice_sql(event.payload[:sql], metric, config,
                        Helper.milliseconds_to_seconds(event.duration))

          # exit transaction trace segment
          NewRelic::Agent.instance.stats_engine.pop_scope(scope, event.duration, event.end)
        end

        def record_metrics(event)
          base = base_metric(event)
          NewRelic::Agent.instance.stats_engine.record_metrics(base,
                              Helper.milliseconds_to_seconds(event.duration),
                              :scoped => true)

          other_metrics = ActiveRecordHelper.rollup_metrics_for(base)
          if config = active_record_config_for_event(event)
            other_metrics << ActiveRecordHelper.remote_service_metric(config[:adapter], config[:host])
          end

          other_metrics.compact.each do |metric_name|
            NewRelic::Agent.instance.stats_engine.record_metrics(metric_name,
                                            Helper.milliseconds_to_seconds(event.duration),
                                            :scoped => false)
          end
        end

        def base_metric(event)
          ActiveRecordHelper.metric_for_name(event.payload[:name]) ||
            ActiveRecordHelper.metric_for_sql(NewRelic::Helper.correctly_encoded(event.payload[:sql]))
        end

        def active_record_config_for_event(event)
          return unless event.payload[:connection_id]

          # TODO: This will not work for JRuby and in any case we want
          # this to be part of the event meta data so it doesn't have
          # to be dug out of an ivar.
          connection = ObjectSpace._id2ref(event.payload[:connection_id])
          connection.instance_variable_get(:@config) if connection
        end
      end
    end
  end
end

DependencyDetection.defer do
  @name = :active_record

  depends_on do
    defined?(::ActiveRecord) && defined?(::ActiveRecord::Base) &&
      defined?(::ActiveRecord::VERSION) &&
      ::ActiveRecord::VERSION::MAJOR.to_i >= 4
  end

  depends_on do
    !NewRelic::Agent.config[:disable_activerecord_instrumentation] &&
      !NewRelic::Agent::Instrumentation::ActiveRecordSubscriber.subscribed?
  end

  executes do
    ::NewRelic::Agent.logger.info 'Installing ActiveRecord instrumentation'
  end

  executes do
    ActiveSupport::Notifications.subscribe('sql.active_record',
      NewRelic::Agent::Instrumentation::ActiveRecordSubscriber.new)
  end
end

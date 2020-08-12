require 'ddtrace/contrib/analytics'
require 'ddtrace/contrib/sinatra/ext'
require 'ddtrace/contrib/sinatra/env'
require 'ddtrace/contrib/sinatra/headers'

module Datadog
  module Contrib
    module Sinatra
      # Middleware used for automatically tagging configured headers and handle request span
      class TracerMiddleware
        # Placeholder resource, so we can augment span with route information if route does not match
        PLACEHOLDER_RESOURCE = 'PLACEHOLDER'.freeze

        def initialize(app, app_instance:)
          @app = app
          @app_instance = app_instance
        end

        def call(env)
          # Set the trace context (e.g. distributed tracing)
          if configuration[:distributed_tracing] && tracer.provider.context.trace_id.nil?
            context = HTTPPropagator.extract(env)
            tracer.provider.context = context if context.trace_id
          end

          tracer.trace(
            Ext::SPAN_REQUEST,
            service: configuration[:service_name],
            span_type: Datadog::Ext::HTTP::TYPE_INBOUND,
            resource: PLACEHOLDER_RESOURCE,
          ) do |span|
            begin
              Sinatra::Env.set_datadog_span(env, @app_instance, span)

              response = @app.call(env)
            ensure
              Sinatra::Env.request_header_tags(env, configuration[:headers][:request]).each do |name, value|
                pp 'set request header'
                pp name, value
                span.set_tag(name, value) if span.get_tag(name).nil?
              end

              span.set_tag(Ext::TAG_APP_NAME, @app_instance.settings.name)
              span.resource = env['sinatra.route'.freeze] if span.resource == PLACEHOLDER_RESOURCE

              if response && (headers = response[1])
                Sinatra::Headers.response_header_tags(headers, configuration[:headers][:response]).each do |name, value|
                  pp 'set response header'
                  pp name, value
                  span.set_tag(name, value) if span.get_tag(name).nil?
                end
              end

              # Set analytics sample rate
              Contrib::Analytics.set_sample_rate(span, analytics_sample_rate) if analytics_enabled?

              # Measure service stats
              Contrib::Analytics.set_measured(span)
            end
          end
        end

        private

        def tracer
          configuration[:tracer]
        end

        def analytics_enabled?
          Contrib::Analytics.enabled?(configuration[:analytics_enabled])
        end

        def analytics_sample_rate
          configuration[:analytics_sample_rate]
        end

        def configuration
          Datadog.configuration[:sinatra]
        end

        def header_to_rack_header(name)
          "HTTP_#{name.to_s.upcase.gsub(/[-\s]/, '_')}"
        end
      end
    end
  end
end

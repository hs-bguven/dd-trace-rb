require 'sinatra/base'

require 'ddtrace/ext/app_types'
require 'ddtrace/ext/errors'
require 'ddtrace/ext/http'
require 'ddtrace/propagation/http_propagator'

require 'ddtrace/contrib/sinatra/ext'
require 'ddtrace/contrib/sinatra/tracer_middleware'
require 'ddtrace/contrib/sinatra/env'

module Datadog
  module Contrib
    module Sinatra
      # Datadog::Contrib::Sinatra::Tracer is a Sinatra extension which traces
      # requests.
      module Tracer
        def route(verb, action, *)
          # Keep track of the route name when the app is instantiated for an
          # incoming request.
          condition do
            # If the option to prepend script names is enabled, then
            # prepend the script name from the request onto the action.
            #
            # DEV: env['sinatra.route'] already exists with very similar information,
            # DEV: but doesn't account for our `resource_script_names` logic.
            #
            @datadog_route = if Datadog.configuration[:sinatra][:resource_script_names]
                               "#{request.script_name}#{action}"
                             else
                               action
                             end
          end

          super
        end

        def self.registered(app)
          app.use TracerMiddleware, app_instance: app

          app.after do
            configuration = Datadog.configuration[:sinatra]
            next unless configuration[:tracer].enabled

            span = Sinatra::Env.datadog_span(env, app)

            route = if defined?(@datadog_route)
                      @datadog_route
                    else
                      # Fallback in case no routes have matched
                      request.path
                    end

            span.resource = "#{request.request_method} #{route}"

            span.set_tag(Datadog::Ext::HTTP::URL, request.path)
            span.set_tag(Datadog::Ext::HTTP::METHOD, request.request_method)
            span.set_tag(Ext::TAG_ROUTE_PATH, route)
            if request.script_name && !request.script_name.empty?
              span.set_tag(Ext::TAG_SCRIPT_NAME, request.script_name)
            end

            span.set_tag(Datadog::Ext::HTTP::STATUS_CODE, response.status)
            span.set_error(env['sinatra.error']) if response.server_error?
          end
        end

        # Method overrides for Sinatra::Base
        module Base
          def render(engine, data, *)
            tracer = Datadog.configuration[:sinatra][:tracer]
            return super unless tracer.enabled

            tracer.trace(Ext::SPAN_RENDER_TEMPLATE, span_type: Datadog::Ext::HTTP::TEMPLATE) do |span|
              span.set_tag(Ext::TAG_TEMPLATE_ENGINE, engine)

              # If data is a string, it is a literal template and we don't
              # want to record it.
              span.set_tag(Ext::TAG_TEMPLATE_NAME, data) if data.is_a? Symbol

              # Measure service stats
              Contrib::Analytics.set_measured(span)

              super
            end
          end

          # Invoked when a matching route is found.
          # This method yields directly to user code.
          def route_eval
            configuration = Datadog.configuration[:sinatra]
            tracer = configuration[:tracer]
            return super unless tracer.enabled

            tracer.trace(
              Ext::SPAN_ROUTE,
              service: configuration[:service_name],
              span_type: Datadog::Ext::HTTP::TYPE_INBOUND
            ) do |span|
              span.resource = "#{request.request_method} #{@datadog_route}"

              span.set_tag(Ext::TAG_APP_NAME, settings.name || settings.superclass.name)
              span.set_tag(Ext::TAG_ROUTE_PATH, @datadog_route)
              if request.script_name && !request.script_name.empty?
                span.set_tag(Ext::TAG_SCRIPT_NAME, request.script_name)
              end

              rack_request_span = env[Datadog::Contrib::Rack::TraceMiddleware::RACK_REQUEST_SPAN]
              rack_request_span.resource = span.resource if rack_request_span

              Contrib::Analytics.set_measured(span)

              super
            end
          end
        end
      end
    end
  end
end

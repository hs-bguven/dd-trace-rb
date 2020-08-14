require 'ddtrace/contrib/support/spec_helper'
require 'ddtrace/contrib/analytics_examples'
require 'rack/test'

require 'sinatra/base'

require 'ddtrace'
require 'ddtrace/contrib/sinatra/tracer'

require 'rspec/expectations'

RSpec.describe 'Sinatra instrumentation' do
  include Rack::Test::Methods

  let(:configuration_options) { {} }

  let(:span) { spans.select { |x| x.name == Datadog::Contrib::Sinatra::Ext::SPAN_REQUEST }[-1] }
  let(:route_span) { spans.find { |x| x.name == Datadog::Contrib::Sinatra::Ext::SPAN_ROUTE } }

  let(:app) { sinatra_app }

  let(:with_rack) { false }

  before do
    Datadog.configure do |c|
      c.use :rack, configuration_options if with_rack
      c.use :sinatra, configuration_options
    end
  end

  around do |example|
    # Reset before and after each example; don't allow global state to linger.
    Datadog.registry[:sinatra].reset_configuration!
    example.run
    Datadog.registry[:sinatra].reset_configuration!
  end

  shared_context 'with rack instrumentation' do
    let(:with_rack) { true }
    let(:rack_span) { spans.find { |x| !x.parent && x.name == Datadog::Contrib::Rack::Ext::SPAN_REQUEST } }

    let(:app) do
      sinatra_app = self.sinatra_app
      Rack::Builder.new do
        use Datadog::Contrib::Rack::TraceMiddleware
        run sinatra_app
      end.to_app
    end
  end

  RSpec::Matchers.define :be_request_span do |opts = {}|
    match(notify_expectation_failures: true) do |span|
      expect(span.service).to eq(Datadog::Contrib::Sinatra::Ext::SERVICE_NAME)
      expect(span.resource).to eq(resource)
      expect(span.get_tag(Datadog::Ext::HTTP::METHOD)).to eq(http_method) if opts[:http_tags]
      expect(span.get_tag(Datadog::Ext::HTTP::URL)).to eq(url) if opts[:http_tags]
      expect(span.get_tag('http.response.headers.content_type')).to eq('text/html;charset=utf-8') if opts[:http_tags]
      expect(span.get_tag(Datadog::Contrib::Sinatra::Ext::TAG_APP_NAME)).to eq(opts[:app_name] || app_name)
      expect(span.get_tag(Datadog::Contrib::Sinatra::Ext::TAG_ROUTE_PATH)).to eq(url) unless opts[:matching_app] == false
      expect(span.get_tag(Datadog::Contrib::Sinatra::Ext::TAG_SCRIPT_NAME)).to be_nil
      expect(span.span_type).to eq(Datadog::Ext::HTTP::TYPE_INBOUND)
      expect(span).to_not have_error
      expect(span.parent).to be(opts[:parent]) if opts[:parent]
    end
  end

  RSpec::Matchers.define :be_route_span do |opts = {}|
    match(notify_expectation_failures: true) do |span|
      expect(span.service).to eq(Datadog::Contrib::Sinatra::Ext::SERVICE_NAME)
      expect(span.resource).to eq(resource)
      expect(span.get_tag(Datadog::Contrib::Sinatra::Ext::TAG_APP_NAME)).to eq(app_name)
      expect(span.get_tag(Datadog::Contrib::Sinatra::Ext::TAG_ROUTE_PATH)).to eq(url)
      expect(span.span_type).to eq(Datadog::Ext::HTTP::TYPE_INBOUND)
      expect(span).to_not have_error
      expect(span.parent).to be(opts[:parent]) if opts[:parent]
    end
  end

  let(:url) { '/' }
  let(:http_method) { 'GET' }
  let(:resource) { "#{http_method} #{url}" }

  shared_examples 'sinatra examples' do
    let(:nested_span_count) { defined?(mount_nested_app) && mount_nested_app ? 1 : 0 }

    context 'when configured' do
      context 'with default settings' do
        context 'and a simple request is made' do
          include_context 'with rack instrumentation'

          subject(:response) { get(url) }

          # let(:top_level_span) { defined?(super) ? super() : rack_span }

          it do
            is_expected.to be_ok
            expect(spans).to have(3 + nested_span_count).items

            expect(span).to be_request_span parent: rack_span, http_tags: true

            # expect(span.service).to eq(Datadog::Contrib::Sinatra::Ext::SERVICE_NAME)
            # expect(span.resource).to eq('GET /')
            # expect(span.get_tag(Datadog::Ext::HTTP::METHOD)).to eq('GET')
            # expect(span.get_tag(Datadog::Ext::HTTP::URL)).to eq('/')
            # expect(span.get_tag('http.response.headers.content_type')).to eq('text/html;charset=utf-8')
            # expect(span.get_tag(Datadog::Contrib::Sinatra::Ext::TAG_APP_NAME)).to eq(app_name)
            # expect(span.get_tag(Datadog::Contrib::Sinatra::Ext::TAG_ROUTE_PATH)).to eq('/')
            # expect(span.get_tag(Datadog::Contrib::Sinatra::Ext::TAG_SCRIPT_NAME)).to be_nil
            # expect(span.span_type).to eq(Datadog::Ext::HTTP::TYPE_INBOUND)
            # expect(span).to_not have_error
            # expect(span.parent).to be(rack_span)

            expect(route_span).to be_request_span parent: span

            # expect(route_span.service).to eq(Datadog::Contrib::Sinatra::Ext::SERVICE_NAME)
            # expect(route_span.resource).to eq('GET /')
            # expect(route_span.get_tag(Datadog::Contrib::Sinatra::Ext::TAG_APP_NAME)).to eq(app_name)
            # expect(route_span.get_tag(Datadog::Contrib::Sinatra::Ext::TAG_ROUTE_PATH)).to eq('/')
            # expect(span.get_tag(Datadog::Contrib::Sinatra::Ext::TAG_SCRIPT_NAME)).to be_nil
            # expect(route_span.span_type).to eq(Datadog::Ext::HTTP::TYPE_INBOUND)
            # expect(route_span).to_not have_error
            # expect(route_span.parent).to eq(span)

            expect(rack_span.resource).to eq('GET /')
          end

          it_behaves_like 'analytics for integration', ignore_global_flag: false do
            before { is_expected.to be_ok }
            let(:analytics_enabled_var) { Datadog::Contrib::Sinatra::Ext::ENV_ANALYTICS_ENABLED }
            let(:analytics_sample_rate_var) { Datadog::Contrib::Sinatra::Ext::ENV_ANALYTICS_SAMPLE_RATE }
          end

          it_behaves_like 'measured span for integration', true do
            before { is_expected.to be_ok }
          end

          context 'which sets X-Request-Id on the response' do
            it do
              subject
              skip("not matching app span") unless span.get_tag(Datadog::Contrib::Sinatra::Ext::TAG_ROUTE_PATH)
              expect(span.get_tag('http.response.headers.x_request_id')).to eq('test id')
            end
          end
        end

        context 'and a request with a query string and fragment is made' do
          subject(:response) { get '/#foo?a=1' }

          it do
            is_expected.to be_ok
            # expect(spans).to have(2 + nested_span_count).items
            expect(span.resource).to eq('GET /')
            expect(span.get_tag(Datadog::Ext::HTTP::URL)).to eq('/')
          end
        end

        context 'and a request to a wildcard route is made' do
          subject(:response) { get '/wildcard/1/2/3' }

          it do
            is_expected.to be_ok
            print_trace spans
            # expect(spans).to have(2 + nested_span_count).items
            expect(span.resource).to eq('GET /wildcard/*')
            expect(span.get_tag(Datadog::Ext::HTTP::URL)).to eq('/wildcard/1/2/3')
            expect(span.get_tag(Datadog::Contrib::Sinatra::Ext::TAG_ROUTE_PATH)).to eq('/wildcard/*')
          end
        end

        context 'and a request to a template route is made' do
          subject(:response) { get '/erb' }

          let(:root_span) { spans[-5] }
          let(:request_span) { spans[-2] }
          let(:route_span) { spans[-1] }
          let(:template_parent_span) { spans[-4] }
          let(:template_child_span) { spans[-3] }

          before do
            expect(response).to be_ok
            expect(spans).to have(4 + nested_span_count).items
            pp spans
          end

          describe 'the sinatra.request span' do
            subject(:span) { request_span }

            it do
              expect(span.resource).to eq('GET /erb')
              expect(span.get_tag(Datadog::Ext::HTTP::URL)).to eq('/erb')
              expect(span.parent).to be root_span
            end

            it_behaves_like 'measured span for integration', true
          end

          describe 'the sinatra.render_template child span' do
            subject(:span) { template_parent_span }

            it do
              expect(span.name).to eq(Datadog::Contrib::Sinatra::Ext::SPAN_RENDER_TEMPLATE)
              expect(span.resource).to eq('sinatra.render_template')
              expect(span.get_tag('sinatra.template_name')).to eq('msg')
              expect(span.parent).to eq(route_span)
            end

            it_behaves_like 'measured span for integration', true
          end

          describe 'the sinatra.render_template grandchild span' do
            subject(:span) { template_child_span }

            it do
              expect(span.name).to eq(Datadog::Contrib::Sinatra::Ext::SPAN_RENDER_TEMPLATE)
              expect(span.resource).to eq('sinatra.render_template')
              expect(span.get_tag('sinatra.template_name')).to eq('layout')
              expect(span.parent).to eq(template_parent_span)
            end

            it_behaves_like 'measured span for integration', true
          end
        end

        context 'and a request to a literal template route is made' do
          subject(:response) { get '/erb_literal' }

          let(:template_parent_span) { spans[0] }
          let(:template_child_span) { spans[1] }

          before do
            expect(response).to be_ok
            expect(spans).to have(4 + nested_span_count).items
          end

          describe 'the sinatra.request span' do
            it do
              print_trace spans, spans[0]
              expect(span.resource).to eq('GET /erb_literal')
              expect(span.get_tag(Datadog::Ext::HTTP::URL)).to eq('/erb_literal')
              expect(span.parent).to be nil
            end

            it_behaves_like 'measured span for integration', true
          end

          describe 'the sinatra.render_template child span' do
            subject(:span) { template_parent_span }

            it do
              expect(span.name).to eq(Datadog::Contrib::Sinatra::Ext::SPAN_RENDER_TEMPLATE)
              expect(span.resource).to eq('sinatra.render_template')
              expect(span.get_tag('sinatra.template_name')).to be nil
              expect(span.parent).to eq(route_span)
            end

            it_behaves_like 'measured span for integration', true
          end

          describe 'the sinatra.render_template grandchild span' do
            subject(:span) { template_child_span }

            it do
              expect(span.name).to eq(Datadog::Contrib::Sinatra::Ext::SPAN_RENDER_TEMPLATE)
              expect(span.resource).to eq('sinatra.render_template')
              expect(span.get_tag('sinatra.template_name')).to eq('layout')
              expect(span.parent).to eq(template_parent_span)
            end

            it_behaves_like 'measured span for integration', true
          end
        end

        context 'and a bad request is made' do
          subject(:response) { get '/client_error' }

          it do
            is_expected.to be_bad_request
            # expect(spans).to have(2 + nested_span_count).items
            expect(span).to_not have_error
          end
        end

        context 'and a request resulting in an internal error is made' do
          subject(:response) { get '/server_error' }

          it do
            is_expected.to be_server_error
            expect(spans).to have(2 + nested_span_count).items
            expect(span).to_not have_error_type
            expect(span).to_not have_error_message
            expect(span.status).to eq(1)
          end
        end

        context 'and a request that raises an exception is made' do
          subject(:response) { get '/error' }

          it do
            is_expected.to be_server_error
            expect(spans).to have(2 + nested_span_count).items
            expect(span).to have_error_type('RuntimeError')
            expect(span).to have_error_message('test error')
            expect(span.status).to eq(1)
          end
        end

        context 'and a request to a nonexistent route' do
          include_context 'with rack instrumentation'

          subject(:response) { get '/not_a_route' }

          it do
            is_expected.to be_not_found
            expect(spans).to have(2 + nested_span_count).items

            expect(span.service).to eq(Datadog::Contrib::Sinatra::Ext::SERVICE_NAME)
            expect(span.resource).to eq('GET /not_a_route')
            expect(span.get_tag(Datadog::Ext::HTTP::METHOD)).to eq('GET')
            expect(span.get_tag(Datadog::Ext::HTTP::URL)).to eq('/not_a_route')
            expect(span.get_tag(Datadog::Contrib::Sinatra::Ext::TAG_APP_NAME)).to eq(app_name)
            expect(span.get_tag(Datadog::Contrib::Sinatra::Ext::TAG_ROUTE_PATH)).to eq('/not_a_route')
            expect(span.span_type).to eq(Datadog::Ext::HTTP::TYPE_INBOUND)
            expect(span).to_not have_error
            expect(span.parent).to be(rack_span)

            expect(rack_span.resource).to eq('GET 404')
          end
        end
      end

      context 'with a custom service name' do
        let(:configuration_options) { super().merge(service_name: service_name) }
        let(:service_name) { 'my-sinatra-app' }

        context 'and a simple request is made' do
          subject(:response) { get '/' }

          it do
            is_expected.to be_ok
            expect(spans).to have(2 + nested_span_count).items
            expect(span.service).to eq(service_name)
          end
        end
      end
    end

    context 'when the tracer is disabled' do
      subject(:response) { get '/' }
      let(:tracer) { get_test_tracer(enabled: false) }

      it do
        is_expected.to be_ok
        expect(spans).to be_empty
      end
    end
  end

  shared_examples 'header tags' do
    let(:configuration_options) { super().merge(headers: { request: request_headers, response: response_headers }) }
    let(:request_headers) { [] }
    let(:response_headers) { [] }

    before { is_expected.to be_ok }

    context 'and a simple request is made' do
      subject(:response) { get '/', query_string, headers }
      let(:query_string) { {} }
      let(:headers) { {} }

      context 'with a header that should be tagged' do
        let(:request_headers) { ['X-Request-Header'] }
        let(:headers) { { 'HTTP_X_REQUEST_HEADER' => header_value } }
        let(:header_value) { SecureRandom.uuid }

        it { expect(span.get_tag('http.request.headers.x_request_header')).to eq(header_value) }
      end

      context 'with a header that should not be tagged' do
        let(:headers) { { 'HTTP_X_REQUEST_HEADER' => header_value } }
        let(:header_value) { SecureRandom.uuid }

        it { expect(span.get_tag('http.request.headers.x_request_header')).to be nil }
      end
    end
  end

  shared_examples 'distributed tracing' do
    context 'default' do
      context 'and a simple request is made' do
        subject(:response) { get '/', query_string, headers }
        let(:query_string) { {} }
        let(:headers) { {} }

        context 'with distributed tracing headers' do
          let(:headers) do
            {
              'HTTP_X_DATADOG_TRACE_ID' => '1',
              'HTTP_X_DATADOG_PARENT_ID' => '2',
              'HTTP_X_DATADOG_SAMPLING_PRIORITY' => Datadog::Ext::Priority::USER_KEEP.to_s,
              'HTTP_X_DATADOG_ORIGIN' => 'synthetics'
            }
          end

          it do
            is_expected.to be_ok
            # expect(spans).to have(2 + nested_span_count).items
            expect(root_span.trace_id).to eq(1)
            expect(root_span.parent_id).to eq(2)
            expect(root_span.get_metric(Datadog::Ext::DistributedTracing::SAMPLING_PRIORITY_KEY)).to eq(2.0)
            expect(root_span.get_tag(Datadog::Ext::DistributedTracing::ORIGIN_KEY)).to eq('synthetics')
          end
        end
      end
    end

    context 'disabled' do
      let(:configuration_options) { super().merge(distributed_tracing: false) }

      context 'and a simple request is made' do
        subject(:response) { get '/', query_string, headers }
        let(:query_string) { {} }
        let(:headers) { {} }

        context 'without distributed tracing headers' do
          let(:headers) do
            {
              'HTTP_X_DATADOG_TRACE_ID' => '1',
              'HTTP_X_DATADOG_PARENT_ID' => '2',
              'HTTP_X_DATADOG_SAMPLING_PRIORITY' => Datadog::Ext::Priority::USER_KEEP.to_s
            }
          end

          it do
            is_expected.to be_ok
            # expect(spans).to have(2 + nested_span_count).items
            expect(root_span.trace_id).to_not eq(1)
            expect(root_span.parent_id).to_not eq(2)
            expect(root_span.get_metric(Datadog::Ext::DistributedTracing::SAMPLING_PRIORITY_KEY)).to_not eq(2.0)
          end
        end
      end
    end
  end

  let(:sinatra_routes) do
    lambda do
      get '/' do
        headers['X-Request-ID'] = 'test id'
        'ok'
      end

      get '/wildcard/*' do
        params['splat'][0]
      end

      get '/error' do
        raise 'test error'
      end

      get '/client_error' do
        halt 400, 'bad request'
      end

      get '/server_error' do
        halt 500, 'server error'
      end

      get '/erb' do
        erb :msg, locals: { msg: 'hello' }
      end

      get '/erb_literal' do
        erb '<%= msg %>', locals: { msg: 'hello' }
      end
    end
  end

  context 'with classic app' do
    let(:sinatra_app) do
      sinatra_routes = self.sinatra_routes
      Class.new(Sinatra::Application) do
        instance_exec(&sinatra_routes)
      end
    end

    let(:app_name) { 'Sinatra::Application' }

    include_examples 'sinatra examples'
  end

  context 'with modular app' do
    let(:sinatra_app) do
      mount_nested_app = self.mount_nested_app
      stub_const('NestedApp', Class.new(Sinatra::Base) do
        register Datadog::Contrib::Sinatra::Tracer

        get '/nested' do
          headers['X-Request-ID'] = 'test id'
          'nested ok'
        end
      end)

      sinatra_routes = self.sinatra_routes
      stub_const('App', Class.new(Sinatra::Base) do
        register Datadog::Contrib::Sinatra::Tracer
        use NestedApp if mount_nested_app

        instance_exec(&sinatra_routes)
      end)
    end

    let(:app_name) { top_level_app_name }
    let(:top_level_app_name) { 'App' }
    let(:mount_nested_app) { false }

    include_examples 'sinatra examples'

    context 'with nested app' do
      # include_context 'with rack instrumentation'

      xcontext 'matching the parent app' do
        let(:span) { spans.find { |x| x.get_tag(Datadog::Contrib::Sinatra::Ext::TAG_APP_NAME) == top_level_app_name } }

        include_examples 'sinatra examples'
        include_examples 'header tags'
        include_examples 'distributed tracing'
      end

      context 'matching the nested app' do
        let(:span) { spans.find { |x| x.get_tag(Datadog::Contrib::Sinatra::Ext::TAG_APP_NAME) == nested_app_name } }

        include_examples 'sinatra examples'
        # include_examples 'header tags'
      end

      # include_examples 'sinatra examples'

      let(:top_level_span) { spans.find { |x| x.get_tag(Datadog::Contrib::Sinatra::Ext::TAG_APP_NAME) == top_level_app_name } }

      let(:app_name) { nested_app_name }
      let(:nested_app_name) { 'NestedApp' }
      let(:mount_nested_app) { true }
      let(:url) { '/nested' }

      subject(:response) { get url }

      # let(:span) { spans.find { |x| x.get_tag(Datadog::Contrib::Sinatra::Ext::TAG_APP_NAME) == nested_app_name } }

      xit 'creates spans for intermediate Sinatra apps' do
        is_expected.to be_ok
        expect(spans).to have(4).items

        expect(top_level_span).to be_request_span parent: rack_span, app_name: top_level_app_name, matching_app: false

        # expect(span.service).to eq(Datadog::Contrib::Sinatra::Ext::SERVICE_NAME)
        # expect(span.resource).to eq('GET /nested')
        # expect(span.get_tag(Datadog::Contrib::Sinatra::Ext::TAG_APP_NAME)).to eq(app_name)
        # expect(span.span_type).to eq(Datadog::Ext::HTTP::TYPE_INBOUND)
        # expect(span).to_not have_error
        # expect(span.parent).to eq(rack_span)

        expect(span).to be_request_span parent: top_level_span

        # expect(nested_span.service).to eq(Datadog::Contrib::Sinatra::Ext::SERVICE_NAME)
        # expect(nested_span.resource).to eq('GET /nested')
        # expect(nested_span.get_tag(Datadog::Ext::HTTP::METHOD)).to eq('GET')
        # expect(nested_span.get_tag(Datadog::Ext::HTTP::URL)).to eq('/nested')
        # expect(nested_span.get_tag('http.response.headers.content_type')).to eq('text/html;charset=utf-8')
        # expect(nested_span.get_tag(Datadog::Contrib::Sinatra::Ext::TAG_APP_NAME)).to eq(nested_app_name)
        # expect(nested_span.get_tag(Datadog::Contrib::Sinatra::Ext::TAG_ROUTE_PATH)).to eq('/nested')
        # expect(nested_span.get_tag(Datadog::Contrib::Sinatra::Ext::TAG_SCRIPT_NAME)).to be_nil
        # expect(nested_span.span_type).to eq(Datadog::Ext::HTTP::TYPE_INBOUND)
        # expect(nested_span).to_not have_error
        # expect(nested_span.parent).to eq(span)

        # expect(route_span.service).to eq(Datadog::Contrib::Sinatra::Ext::SERVICE_NAME)
        # expect(route_span.resource).to eq('GET /nested')
        # expect(route_span.get_tag(Datadog::Contrib::Sinatra::Ext::TAG_APP_NAME)).to eq(nested_app_name)
        # expect(route_span.get_tag(Datadog::Contrib::Sinatra::Ext::TAG_ROUTE_PATH)).to eq('/nested')
        # expect(route_span.span_type).to eq(Datadog::Ext::HTTP::TYPE_INBOUND)
        # expect(route_span).to_not have_error
        # expect(route_span.parent).to eq(nested_span)

        expect(route_span).to be_route_span parent: span

        expect(rack_span.resource).to eq('GET /nested')
      end
    end
  end
end


def print_trace(spans, *roots)
  roots ||= spans.select { |s| !s.parent }

  return STDERR.puts "No root!" if roots.empty?

  roots.map { |root| print_with_root(spans, root) }
end

def print_with_root(spans, root)
  start_time = root.start_time
  end_time = root.end_time

  print_span(start_time, end_time, root)

  parent = root
  while (span = parent = next_span(spans, parent))
    print_span(start_time, end_time, span)
  end
end

def next_span(spans, parent)
  spans.find { |s| s.parent_id == parent.span_id }
end

def print_span(start_time, end_time, span)
  size = 100
  total_time = (end_time - start_time).to_f

  prefix = ' ' * ((span.start_time.to_f - start_time.to_f) / total_time * size).to_i
  print prefix

  label = "#{span.name}:#{span.resource}(#{short_id(span.span_id)},↑#{short_id(span.parent_id)})"
  print label

  suffix = '─' * [size - ((end_time.to_f - span.end_time.to_f) / total_time * size) - prefix.size - label.size, 0].max
  print suffix

  puts
end

def short_id(id)
  (id % 1000000).to_s(36)
end

class Datadog::Span
  def short_id
    Kernel.send(:short_id, span_id)
  end
end

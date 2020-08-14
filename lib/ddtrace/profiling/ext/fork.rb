module Datadog
  module Profiling
    module Ext
      # Extensions for forking.
      module Fork
        def fork
          @on_fork_blocks = [] unless instance_variable_defined?(:@on_fork_blocks)

          wrapped_block = proc do
            # Trigger on_fork hook
            @on_fork_blocks.each(&:call)
            yield
          end

          super(&wrapped_block)
        end

        def on_fork(&block)
          @on_fork_blocks = [] unless instance_variable_defined?(:@on_fork_blocks)
          @on_fork_blocks << block
        end
      end
    end
  end
end

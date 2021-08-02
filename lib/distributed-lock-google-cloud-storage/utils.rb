# frozen_string_literal: true

module DistributedLock
  module GoogleCloudStorage
    module Utils
      private

      # Queries the monotonic clock and returns its timestamp, in seconds.
      #
      # @return [Float]
      def monotonic_time
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end


      # Runs the given block until it succeeds, or until we timeout.
      #
      # The block must return `:success`, `[:success, any value]`, `:error` or
      # `:retry_immediately`.
      #
      # Every time the block returns `:error`, we sleep for an amount of time and
      # then we try again. This sleep time increases exponentially but is subject
      # to random jitter.
      #
      # If the block returns `:retry_immediately` then we retry immediately without
      # sleeping.
      #
      # If the block returns `[:success, any value]` then this function returns `any value`.
      # If the block returns just `:success` then this function returns nil.
      #
      # @param [Numeric] timeout
      # @param [#call] retry_logger Will be called every time we retry. The parameter
      #   passed is a Float, indicating the seconds that we'll sleep until the next retry.
      # @param backoff_min [Numeric]
      # @param backoff_max [Numeric]
      # @param backoff_multiplier [Numeric]
      # @yield
      def retry_with_backoff_until_success(timeout,
        retry_logger: nil,
        backoff_min: DEFAULT_BACKOFF_MIN,
        backoff_max: DEFAULT_BACKOFF_MAX,
        backoff_multiplier: DEFAULT_BACKOFF_MULTIPLIER)

        sleep_time = backoff_min
        deadline = monotonic_time + timeout

        while true
          result, retval = yield
          case result
          when :success
            return retval
          when :error
            raise TimeoutError if monotonic_time >= deadline
            retry_logger.call(sleep_time) if retry_logger
            sleep(sleep_time)
            sleep_time = calc_sleep_time(sleep_time, backoff_min, backoff_max, backoff_multiplier)
          when :retry_immediately
            raise TimeoutError if monotonic_time >= deadline
          else
            raise "Bug: block returned unknown result #{result.inspect}"
          end
        end
      end

      # See https://aws.amazon.com/blogs/architecture/exponential-backoff-and-jitter/
      # for a discussion on jittering approaches. The best choices are "Full Jitter"
      # (fewest contended calls) and "Decorrelated Jitter" (lowest completion time).
      # We choose "Decorrelated Jitter" because we care most about completion time:
      # Google can probably handle a slight increase in contended calls.
      def calc_sleep_time(last_value, backoff_min, backoff_max, backoff_multiplier)
        result = rand(backoff_min.to_f .. (last_value * backoff_multiplier).to_f)
        [result, backoff_max].min
      end


      # Once every `interval` seconds, yields the given block, until `check_quit` returns true
      # or until the block failed `max_failures` times in succession.
      #
      # Sleeping between yields works by sleeping on the given condition variable. You can thus
      # force this function to wake up (e.g. to tell it that it should quit) by signalling the
      # condition variable.
      #
      # We take the lock while the block is being yielded. We release the lock while we're
      # sleeping.
      #
      # @param [Mutex] mutex
      # @param [ConditionVariable] cond
      # @param [Numeric] interval
      # @param [Integer] max_failures
      # @param [#call] check_quit Will be called regularly to check whether we should stop.
      #   This callable must return a Boolean.
      # @param [#call, nil] schedule_calculated
      # @yield
      # @yieldreturn [Boolean] True to indicate success, false to indicate failure.
      # @return [Boolean] True if this function stopped because `check_quit` returned true, false
      #   if this function stopped because the block failed `max_failures` times in succession.
      def work_regularly(mutex:, cond:, interval:, max_failures:, check_quit:, schedule_calculated: nil)
        fail_count = 0
        next_time = monotonic_time + interval

        mutex.synchronize do
          while !check_quit.call && fail_count < max_failures
            timeout = [0, next_time - monotonic_time].max
            schedule_calculated.call(timeout) if schedule_calculated
            wait_on_condition_variable(mutex, cond, timeout)
            break if check_quit.call

            # Timed out; perform work now
            next_time = monotonic_time + interval
            mutex.unlock
            begin
              success = yield
            ensure
              mutex.lock
            end

            if success
              fail_count = 0
            else
              fail_count += 1
            end
          end
        end

        fail_count < max_failures
      end

      def wait_on_condition_variable(mutex, cond, timeout)
        cond.wait(mutex, timeout)
      end
    end
  end
end

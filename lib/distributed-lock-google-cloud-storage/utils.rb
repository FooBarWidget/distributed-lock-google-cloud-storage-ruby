# frozen_string_literal: true

module DistributedLock
  module GoogleCloudStorage
    module Utils
      private

      # @return [Float]
      def monotonic_time
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end


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


      def work_regularly(mutex:, cond:, interval:, max_failures:, check_quit:, schedule_calculated:)
        fail_count = 0
        next_time = monotonic_time + interval

        mutex.synchronize do
          while !check_quit.call && fail_count <= max_failures
            timeout = [0, next_time - monotonic_time].max
            schedule_calculated.call(timeout)
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

        fail_count > max_failures
      end

      def wait_on_condition_variable(mutex, cond, timeout)
        cond.wait(mutex, timeout)
      end
    end
  end
end

# frozen_string_literal: true

require 'dotenv'
require 'google/cloud/errors'
require 'rspec/retry'

module Helpers
  EXCEPTIONS_TO_RETRY = [
    Google::Cloud::ResourceExhaustedError,
    Google::Cloud::UnavailableError,
  ]

  def self.print_all_thread_backtraces
    puts '-------- Begin backtrace dump --------'
    Thread.list.each do |thr|
      puts "#### Thread #{thr}"
      thr.backtrace.each do |line|
        puts "    #{line}"
      end
      puts
    end
    puts '-------- End backtrace dump --------'
  end

  def exception_to_retry?(ex)
    EXCEPTIONS_TO_RETRY.any? do |ex_class|
      ex.is_a?(ex_class)
    end
  end

  # Runs the given block.
  # If it raises a retryable exception, then pass it through.
  # If it raises a non-retryable exception, then returns that exception.
  # Otherwise, returns nil.
  #
  # This is used as an alternative to `expect { block }.not_to raise_error`
  # which lets retryable exceptions through so that rspec-retry can retry
  # the test.
  def catch_non_retryable_exception
    begin
      yield
      nil
    rescue => e
      if exception_to_retry?(e)
        raise e
      else
        e
      end
    end
  end

  def require_envvar(name)
    value = ENV[name]
    raise ArgumentError, "Required environment variable: #{name}" if value.to_s.empty?
    value
  end

  def monotonic_time
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  def eventually(timeout:, interval: 0.1)
    deadline = monotonic_time + timeout
    while monotonic_time < deadline
      result = yield
      return if result
      sleep interval
    end
    raise 'Timeout'
  end

  def consistently(duration:, interval: 0.1)
    deadline = monotonic_time + duration
    while monotonic_time < deadline
      yield
      sleep interval
    end
  end
end


Dotenv.load

RSpec.configure do |c|
  c.include Helpers

  c.verbose_retry = true
  c.display_try_failure_messages = true
  c.default_retry_count = 3
  c.default_sleep_interval = 10
  c.exceptions_to_retry = Helpers::EXCEPTIONS_TO_RETRY
end

Signal.trap('QUIT') { Helpers.print_all_thread_backtraces }

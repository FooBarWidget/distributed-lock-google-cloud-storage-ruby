# frozen_string_literal: true

require 'dotenv'
require 'google/cloud/errors'
require 'rspec/retry'

module Helpers
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
  c.exceptions_to_retry = [
    Google::Cloud::ResourceExhaustedError,
    Google::Cloud::UnavailableError
  ]
end

Signal.trap('QUIT') { Helpers.print_all_thread_backtraces }

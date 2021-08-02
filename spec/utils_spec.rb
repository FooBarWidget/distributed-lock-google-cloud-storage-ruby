# frozen_string_literal: true

require_relative '../lib/distributed-lock-google-cloud-storage/constants'
require_relative '../lib/distributed-lock-google-cloud-storage/errors'
require_relative '../lib/distributed-lock-google-cloud-storage/utils'

RSpec.describe DistributedLock::GoogleCloudStorage::Utils do
  describe '.retry_with_backoff_until_success' do
    class UtilsHolder
      include DistributedLock::GoogleCloudStorage::Utils
      public :retry_with_backoff_until_success
    end

    let(:utils) { UtilsHolder.new }

    describe 'when the block returns :success' do
      it "returns the block's value" do
        result = utils.retry_with_backoff_until_success(1) do
          [:success, 1234]
        end
        expect(result).to eq(1234)
      end
    end

    describe 'when the block returns :retry_immediately' do
      it 'retries immediately without sleeping' do
        iteration = 0

        retry_logger = double('RetryLogger')
        expect(retry_logger).not_to receive(:call)

        utils.retry_with_backoff_until_success(1, retry_logger: retry_logger) do
          iteration += 1
          if iteration < 3
            :retry_immediately
          else
            :success
          end
        end

        expect(iteration).to eq(3)
      end

      it 'raises a TimeoutError if the deadline has passed' do
        expect(utils).to \
          receive(:monotonic_time).
          and_return(1, 1, 2)

        expect do
          utils.retry_with_backoff_until_success(1) do
            :retry_immediately
          end
        end.to raise_error(DistributedLock::GoogleCloudStorage::TimeoutError)
      end
    end

    describe 'when the block returns :error' do
      it 'retries after sleeping' do
        iteration = 0

        expect(utils).to \
          receive(:sleep).
          with(kind_of(Numeric)).
          exactly(2).times

        retry_logger = double('RetryLogger')
        expect(retry_logger).to \
          receive(:call).
          with(kind_of(Numeric)).
          exactly(2).times

        utils.retry_with_backoff_until_success(60, retry_logger: retry_logger) do
          iteration += 1
          if iteration < 3
            :error
          else
            :success
          end
        end

        expect(iteration).to eq(3)
      end

      it 'raises a TimeoutError if the deadline has passed' do
        expect(utils).to \
          receive(:monotonic_time).
          and_return(1, 1, 2)

        expect(utils).to \
          receive(:sleep).
          with(kind_of(Numeric)).
          exactly(:once)

        expect do
          utils.retry_with_backoff_until_success(1) do
            :error
          end
        end.to raise_error(DistributedLock::GoogleCloudStorage::TimeoutError)
      end
    end
  end


  describe '.work_regularly' do
    class UtilsHolder
      include DistributedLock::GoogleCloudStorage::Utils
      public :work_regularly
    end

    let(:utils) { UtilsHolder.new }

    before :each do
      @mutex = Mutex.new
      @cond = ConditionVariable.new
    end

    def check_quit
      @quit
    end

    it 'yields the block until we signal it to quit' do
      called = 0

      expect(utils).to \
        receive(:wait_on_condition_variable).
        with(@mutex, @cond, kind_of(Numeric)).
        exactly(2).times

      result = utils.work_regularly(mutex: @mutex, cond: @cond,
        interval: 1, max_failures: 3, check_quit: method(:check_quit)) do

        called += 1
        @quit = called >= 2
        true
      end

      expect(called).to eq(2)
      expect(result).to be_truthy
    end

    it 'yields the block until it fails too many time in succession' do
      called = 0

      expect(utils).to \
        receive(:wait_on_condition_variable).
        with(@mutex, @cond, kind_of(Numeric)).
        exactly(3).times

      result = utils.work_regularly(mutex: @mutex, cond: @cond,
        interval: 1, max_failures: 3, check_quit: method(:check_quit)) do

        called += 1
        false
      end

      expect(called).to eq(3)
      expect(result).to be_falsey
    end

    it 'resets the failure counter when the block succeeds' do
      called = 0

      expect(utils).to \
        receive(:wait_on_condition_variable).
        with(@mutex, @cond, kind_of(Numeric)).
        exactly(10).times

      result = utils.work_regularly(mutex: @mutex, cond: @cond,
        interval: 1, max_failures: 3, check_quit: method(:check_quit)) do

        called += 1
        @quit = called >= 10
        called % 2 == 0
      end

      expect(called).to eq(10)
      expect(result).to be_truthy
    end
  end
end

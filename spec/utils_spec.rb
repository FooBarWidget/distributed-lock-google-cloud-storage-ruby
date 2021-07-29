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
end

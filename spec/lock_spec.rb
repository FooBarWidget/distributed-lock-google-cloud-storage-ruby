# frozen_string_literal: true

require 'logger'
require 'stringio'
require_relative 'spec_helper'
require_relative '../lib/distributed-lock-google-cloud-storage/lock'

RSpec.describe DistributedLock::GoogleCloudStorage::Lock do
  around(:each) do |ex|
    ex.run_with_retry retry: 3
  end

  def create(**options)
    DistributedLock::GoogleCloudStorage::Lock.new(
      bucket_name: require_envvar('TEST_GCLOUD_BUCKET'),
      path: 'ruby-lock',
      app_identity: 'rspec',
      cloud_storage_options: {
        credentials: require_envvar('TEST_GCLOUD_CREDENTIALS_PATH'),
      },
      **options)
  end

  def force_erase_lock_object
    storage = Google::Cloud::Storage.new(credentials: require_envvar('TEST_GCLOUD_CREDENTIALS_PATH'))
    bucket = storage.bucket(require_envvar('TEST_GCLOUD_BUCKET'), skip_lookup: true)
    bucket.file('ruby-lock', skip_lookup: true).delete
  rescue Google::Cloud::NotFoundError
    # Do nothing
  end


  describe 'initial state' do
    before(:all) { force_erase_lock_object }

    let(:lock) { create }

    it 'is not locked' do
      expect(lock).not_to be_locked_according_to_internal_state
      expect(lock).not_to be_locked_according_to_server
    end

    it 'is not owned' do
      expect(lock).not_to be_owned_according_to_internal_state
      expect(lock).not_to be_owned_according_to_server
    end

    specify 'checking for health is not possible due to being unlocked' do
      expect { lock.healthy? }.to \
        raise_error(DistributedLock::GoogleCloudStorage::NotLockedError)
      expect { lock.check_health! }.to \
        raise_error(DistributedLock::GoogleCloudStorage::NotLockedError)
    end

    specify 'unlocking is not possible due to being unlocked' do
      expect { lock.unlock }.to \
        raise_error(DistributedLock::GoogleCloudStorage::NotLockedError)
    end
  end


  describe '#try_lock' do
    before(:each) do
      force_erase_lock_object
      @lock = create(logger: Logger.new(StringIO.new))
      @lock_app2 = create(app_identity: 'rspec2', logger: Logger.new(StringIO.new))
    end

    after :each do
      [@lock, @lock_app2].each do |lock|
        lock.abandon if lock
      end
    end

    it 'works' do
      expect(@lock.try_lock).to be_truthy
      expect(@lock).to be_locked_according_to_internal_state
      expect(@lock).to be_locked_according_to_server
      expect(@lock).to be_owned_according_to_internal_state
      expect(@lock).to be_owned_according_to_server
      expect(@lock).to be_healthy
      expect { @lock.check_health! }.not_to raise_error
    end

    it 'raises AlreadyLockedError if called twice by the same instance and thread' do
      expect(@lock.try_lock).to be_truthy
      expect { @lock.try_lock }.to \
        raise_error(DistributedLock::GoogleCloudStorage::AlreadyLockedError)
    end

    specify 'another thread fails to take the lock' do
      expect(@lock.try_lock).to be_truthy

      thr = Thread.new { Thread.current[:result] = @lock.try_lock }
      expect(thr.join[:result]).to be_falsey

      expect(@lock).to be_locked_according_to_internal_state
      expect(@lock).to be_locked_according_to_server
      expect(@lock).to be_owned_according_to_internal_state
      expect(@lock).to be_owned_according_to_server
    end

    specify 'another app identity fails to take the lock' do
      expect(@lock.try_lock).to be_truthy
      expect(@lock_app2.try_lock).to be_falsey
      expect(@lock).to be_locked_according_to_internal_state
      expect(@lock).to be_locked_according_to_server
      expect(@lock).to be_owned_according_to_internal_state
      expect(@lock).to be_owned_according_to_server
    end

    it 'retries if the lock object was deleted right after failing to create it'
    it 'succeeds if the lock was previously abandoned by the same instance and thread'
    it 'cleans up stale locks'
  end


  describe '#lock' do
    before(:each) do
      force_erase_lock_object
      @lock = create(logger: Logger.new(StringIO.new))
      @lock_app2 = create(app_identity: 'rspec2', logger: Logger.new(StringIO.new))
    end

    after :each do
      [@lock, @lock_app2].each do |lock|
        lock.abandon if lock
      end
    end

    it 'works' do
      @lock.lock
      expect(@lock).to be_locked_according_to_internal_state
      expect(@lock).to be_locked_according_to_server
      expect(@lock).to be_owned_according_to_internal_state
      expect(@lock).to be_owned_according_to_server
    end

    it 'raises AlreadyLockedError if called twice by the same instance and thread' do
      @lock.lock
      expect { @lock.lock }.to \
        raise_error(DistributedLock::GoogleCloudStorage::AlreadyLockedError)
    end

    specify 'another thread fails to take the lock' do
      @lock.lock

      thr = Thread.new do
        Thread.current.report_on_exception = false
        @lock.lock(timeout: 0)
      end
      expect { thr.join }.to raise_error(DistributedLock::GoogleCloudStorage::TimeoutError)

      expect(@lock).to be_locked_according_to_internal_state
      expect(@lock).to be_locked_according_to_server
      expect(@lock).to be_owned_according_to_internal_state
      expect(@lock).to be_owned_according_to_server
    end

    it 'retries if the lock object was deleted right after failing to create it'
    it 'succeeds if the lock was previously abandoned by the same instance and thread'
    it 'cleans up stale locks'
  end


  describe '#unlock' do
    before(:each) do
      force_erase_lock_object
      @lock = create(logger: Logger.new(StringIO.new))
    end

    after :each do
      @lock.abandon if @lock
    end

    def lock_and_unlock
      expect(@lock.try_lock).to be_truthy
      expect { @lock.unlock }.not_to raise_error
    end

    it 'releases the lock' do
      lock_and_unlock
      expect(@lock).not_to be_locked_according_to_internal_state
      expect(@lock).not_to be_locked_according_to_server
      expect(@lock).not_to be_owned_according_to_internal_state
      expect(@lock).not_to be_owned_according_to_server
    end

    specify 'checking for health is not possible due to being unlocked' do
      lock_and_unlock
      expect { @lock.healthy? }.to \
        raise_error(DistributedLock::GoogleCloudStorage::NotLockedError)
      expect { @lock.check_health! }.to \
        raise_error(DistributedLock::GoogleCloudStorage::NotLockedError)
    end

    specify 'unlocking again is not possible' do
      lock_and_unlock
      expect { @lock.unlock }.to \
        raise_error(DistributedLock::GoogleCloudStorage::NotLockedError)
    end

    it 'works if the lock object is already deleted' do
      expect(@lock.try_lock).to be_truthy
      force_erase_lock_object
      expect { @lock.unlock }.not_to raise_error
      expect(@lock).not_to be_locked_according_to_internal_state
      expect(@lock).not_to be_locked_according_to_server
      expect(@lock).not_to be_owned_according_to_internal_state
      expect(@lock).not_to be_owned_according_to_server
    end
  end


  describe 'refreshing' do
    it 'updates the update time'
    it 'declares unhealthiness upon failing too many times in succession'
    it 'declares unhealthiness when the metageneration number is inconsistent'
    it 'declares unhealthiness when the lock object is deleted'
  end
end

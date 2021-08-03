# frozen_string_literal: true

require 'logger'
require 'stringio'
require 'securerandom'
require 'google/cloud/storage'
require_relative 'constants'
require_relative 'errors'
require_relative 'utils'

module DistributedLock
  module GoogleCloudStorage
    class Lock
      DEFAULT_INSTANCE_IDENTITY = SecureRandom.hex(12).freeze

      include Utils

      # Creates a new Lock instance.
      #
      # Under the hood we'll instantiate a
      # [Google::Cloud::Storage::Bucket](https://googleapis.dev/ruby/google-cloud-storage/latest/Google/Cloud/Storage/Bucket.html)
      # object for accessing the bucket. You can customize the project ID, authentication method, etc. through
      # `cloud_storage_options` and `cloud_storage_bucket_options`.
      #
      # @param bucket_name [String] The name of a Cloud Storage bucket in which to place the lock.
      #   This bucket must already exist.
      # @param path [String] The object path within the bucket to use for locking.
      # @param instance_identity [String] A unique identifier for this application instance, to be included in the
      #   lock object's owner identity string. Learn more in the readme, section "Fast recovery from stale locks".
      # @param thread_safe [Boolean] Whether this Lock instance should be thread-safe. When true, the thread's
      #   identity will be included in the lock object's owner identity string, section "Thread-safety".
      # @param logger A Logger-compatible object to log progress to. See also the note about thread-safety.
      # @param ttl [Numeric] The lock is considered stale if it's age (in seconds) is older than this value.
      #   This value should be generous, on the order of minutes.
      # @param refresh_interval [Numeric, nil]
      #   We'll refresh the lock's timestamp every `refresh_interval` seconds. This value should be many
      #   times smaller than `stale_time`, so that we can detect an unhealthy lock long before it becomes stale.
      #
      #   This value must be smaller than `ttl / max_refresh_fails`.
      #
      #   Default: `stale_time / 8`
      # @param max_refresh_fails [Integer]
      #   The lock will be declared unhealthy if refreshing fails this many times consecutively.
      # @param backoff_min [Numeric] Minimum amount of time, in seconds, to back off when
      #   waiting for a lock to become available. Must be at least 0.
      # @param backoff_max [Numeric] Maximum amount of time, in seconds, to back off when
      #   waiting for a lock to become available. Must be at least `backoff_min`.
      # @param backoff_multiplier [Numeric] Factor to increase the backoff time by, each time
      #   when acquiring the lock fails. Must be at least 0.
      # @param object_acl [String, nil] A predefined set of access control to apply to the Cloud Storage
      #   object. See the `acl` parameter in
      #   [https://googleapis.dev/ruby/google-cloud-storage/latest/Google/Cloud/Storage/Bucket.html#create_file-instance_method](Google::Cloud::Storage::Bucket#create_file)
      #   for acceptable values.
      # @param cloud_storage_options [Hash, nil] Additional options to pass to
      #   {https://googleapis.dev/ruby/google-cloud-storage/latest/Google/Cloud/Storage.html#new-class_method Google::Cloud::Storage.new}.
      #   See its documentation to learn which options are available.
      # @param cloud_storage_bucket_options [Hash, nil] Additional options to pass to
      #   {https://googleapis.dev/ruby/google-cloud-storage/latest/Google/Cloud/Storage/Project.html#bucket-instance_method Google::Cloud::Storage::Project#bucket}.
      #   See its documentation to learn which options are available.
      #
      # @note The logger must either be thread-safe, or it musn't be used by anything
      #   besides this `Lock` instance. This is because the logger will be
      #   written to by a background thread.
      # @raise [ArgumentError] When an invalid argument is detected.
      def initialize(bucket_name:, path:, instance_identity: DEFAULT_INSTANCE_IDENTITY,
        thread_safe: true, logger: Logger.new($stderr),
        ttl: DEFAULT_TTL, refresh_interval: nil, max_refresh_fails: DEFAULT_MAX_REFRESH_FAILS,
        backoff_min: DEFAULT_BACKOFF_MIN, backoff_max: DEFAULT_BACKOFF_MAX,
        backoff_multiplier: DEFAULT_BACKOFF_MULTIPLIER,
        object_acl: nil, cloud_storage_options: nil, cloud_storage_bucket_options: nil)

        check_refresh_interval_allowed!(ttl, refresh_interval, max_refresh_fails)
        check_backoff_min!(backoff_min)
        check_backoff_max!(backoff_max, backoff_min)
        check_backoff_multiplier!(backoff_multiplier)

        @bucket_name = bucket_name
        @path = path
        @instance_identity = instance_identity
        @thread_safe = thread_safe
        @logger = logger
        @ttl = ttl
        @refresh_interval = refresh_interval || ttl * DEFAULT_TTL_REFRESH_INTERVAL_DIVIDER
        @max_refresh_fails = max_refresh_fails
        @backoff_min = backoff_min
        @backoff_max = backoff_max
        @backoff_multiplier = backoff_multiplier
        @object_acl = object_acl

        @client = create_gcloud_storage_client(cloud_storage_options)
        @bucket = get_gcloud_storage_bucket(@client, bucket_name, cloud_storage_bucket_options)
        @refresher_mutex = Mutex.new
        @refresher_cond = ConditionVariable.new
      end

      # Returns whether this Lock instance's internal state believes that the lock
      # is currently held by this instance. Does not check whether the lock is stale.
      #
      # @return [Boolean]
      def locked_according_to_internal_state?
        !@owner.nil?
      end

      # Returns whether the server believes that the lock is currently held by somebody.
      # Does not check whether the lock is stale.
      #
      # @return [Boolean]
      def locked_according_to_server?
        !@bucket.file(@path).nil?
      end

      # Returns whether this Lock instance's internal state believes that the lock
      # is held by the current Lock instance in the calling thread.
      #
      # @return [Boolean]
      def owned_according_to_internal_state?
        @owner == identity
      end

      # Returns whether the server believes that the lock is held by the current
      # Lock instance in the calling thread.
      #
      # @return [Boolean]
      def owned_according_to_server?
        file = @bucket.file(@path)
        return false if file.nil?
        file.metadata['identity'] == identity
      end

      # Obtains the lock. If the lock is stale, resets it automatically. If the lock is already
      # obtained by some other app identity or some other thread, waits until it becomes available,
      # or until timeout.
      #
      # @param timeout [Numeric] The timeout in seconds.
      # @return [void]
      # @raise [AlreadyLockedError] This Lock instance — according to its internal state — believes
      #   that it's already holding the lock.
      # @raise [TimeoutError] Failed to acquire the lock within `timeout` seconds.
      def lock(timeout: 2 * @ttl)
        raise AlreadyLockedError, 'Already locked' if owned_according_to_internal_state?

        file = retry_with_backoff_until_success(timeout,
          retry_logger: method(:log_lock_retry),
          backoff_min: @backoff_min,
          backoff_max: @backoff_max,
          backoff_multiplier: @backoff_multiplier) do

          if (file = create_lock_object)
            [:success, file]
          else
            file = @bucket.file(@path)
            if file.nil?
              @logger.warn 'Lock was deleted right after having created it. Retrying.'
              :retry_immediately
            elsif file.metadata['identity'] == identity
              @logger.warn 'Lock was already owned by this instance, but was abandoned. Resetting lock'
              delete_lock_object(file.metageneration)
              :retry_immediately
            else
              if lock_stale?(file)
                @logger.warn 'Lock is stale. Resetting lock'
                delete_lock_object(file.metageneration)
              end
              :error
            end
          end
        end

        @owner = identity
        @metageneration = file.metageneration
        spawn_refresher_thread
        nil
      end

      # Releases the lock and stops refreshing the lock in the background.
      #
      # @return [Boolean] True if the lock object was actually deleted, false if the lock object
      #   was already deleted.
      # @raise [NotLockedError] This Lock instance — according to its internal state — believes
      #   that it isn't currently holding the lock.
      def unlock
        raise NotLockedError, 'Not locked' if !locked_according_to_internal_state?
        shutdown_refresher_thread
        deleted = delete_lock_object(@metageneration)
        @owner = nil
        @metageneration = nil
        deleted
      end

      # Obtains the lock, runs the block, and releases the lock when the block completes.
      #
      # If the lock is stale, resets it automatically. If the lock is already
      # obtained by some other app identity or some other thread, waits until it becomes available,
      # or until timeout.
      #
      # Accepts the same arguments as #lock.
      #
      # @return The block's return value.
      def synchronize(...)
        lock(...)
        begin
          yield
        ensure
          unlock
        end
      end

      # Pretends like we've never obtained this lock, abandoning our internal state about the lock.
      #
      # Shuts down background lock refreshing, and ensures that
      # #locked_according_to_internal_state? returns false.
      #
      # Does not modify any server data, so #locked_according_to_server? may still return true.
      #
      # @return [void]
      def abandon
        shutdown_refresher_thread if locked_according_to_internal_state?
      end

      # Returns whether the lock is healthy. A lock is considered healthy until
      # we fail to refresh the lock too many times consecutively.
      #
      # It only makes sense to call this method after having obtained this lock.
      #
      # @return [Boolean]
      # @raise [NotLockedError] This lock was not obtained.
      def healthy?
        raise NotLockedError, 'Not locked' if !locked_according_to_internal_state?
        @refresher_thread.alive?
      end

      # Checks whether the lock is healthy. See #healthy? for the definition of "healthy".
      #
      # It only makes sense to call this method after having obtained this lock.
      #
      # @return [void]
      # @raise [LockUnhealthyError] When an unhealthy state is detected.
      # @raise [NotLockedError] This lock was not obtained.
      def check_health!
        raise LockUnhealthyError, 'Lock is not healthy' if !healthy?
      end


      private

      # @param ttl [Numeric]
      # @param refresh_interval [Numeric]
      # @param max_refresh_fails [Integer]
      # @return [void]
      # @raise [ArgumentError]
      def check_refresh_interval_allowed!(ttl, refresh_interval, max_refresh_fails)
        if refresh_interval && refresh_interval >= ttl.to_f / max_refresh_fails
          raise ArgumentError, 'refresh_interval must be smaller than ttl / max_refresh_fails'
        end
      end

      # @param backoff_min [Numeric]
      # @return [void]
      # @raise [ArgumentError]
      def check_backoff_min!(backoff_min)
        if backoff_min < 0
          raise ArgumentError, 'backoff_min must be at least 0'
        end
      end

      # @param backoff_max [Numeric]
      # @param backoff_min [Numeric]
      # @return [void]
      # @raise [ArgumentError]
      def check_backoff_max!(backoff_max, backoff_min)
        if backoff_max < backoff_min
          raise ArgumentError, 'backoff_max may not be smaller than backoff_min'
        end
      end

      # @param backoff_multiplier [Numeric]
      # @return [void]
      # @raise [ArgumentError]
      def check_backoff_multiplier!(backoff_multiplier)
        if backoff_multiplier < 0
          raise ArgumentError, 'backoff_multiplier must be at least 0'
        end
      end


      # @param options [Hash]
      # @return [Google::Cloud::Storage::Project]
      def create_gcloud_storage_client(options)
        options ||= {}
        Google::Cloud::Storage.new(**options)
      end

      # @param client [Google::Cloud::Storage::Project]
      # @param bucket_name [String]
      # @param options [Hash]
      # @return [Google::Cloud::Storage::Bucket]
      def get_gcloud_storage_bucket(client, bucket_name, options)
        options ||= {}
        client.bucket(bucket_name, skip_lookup: true, **options)
      end

      # @return [String]
      def identity
        result = @instance_identity
        result = "#{result}/thr-#{Thread.current.object_id.to_s(36)}" if @thread_safe
        result
      end

      # Creates the lock object in Cloud Storage. Returns a Google::Cloud::Storage::File
      # on success, or nil if object already exists.
      #
      # @return [Google::Cloud::Storage::File, nil]
      def create_lock_object
        @bucket.create_file(
          StringIO.new,
          @path,
          acl: @object_acl,
          cache_control: 'no-store',
          metadata: {
            expires_at: (Time.now + @ttl).to_f,
            identity: identity,
          },
          if_generation_match: 0,
        )
      rescue Google::Cloud::FailedPreconditionError
        nil
      end

      # @param expected_metageneration [Integer]
      # @return [Boolean] True if deletion was successful or if file did
      #   not exist, false if the metageneration did not match.
      def delete_lock_object(expected_metageneration)
        file = @bucket.file(@path, skip_lookup: true)
        file.delete(if_metageneration_match: expected_metageneration)
      rescue Google::Cloud::NotFoundError
        false
      rescue Google::Cloud::FailedPreconditionError
        false
      end

      # @param file [Google::Cloud::Storage::File]
      # @return [Boolean]
      def lock_stale?(file)
        Time.now.to_f > file.metadata['expires_at'].to_f
      end

      # @param sleep_time [Numeric]
      # @return [void]
      def log_lock_retry(sleep_time)
        @logger.info("Unable to acquire lock. Will try again in #{sleep_time.to_i} seconds")
      end

      # @return [void]
      def spawn_refresher_thread
        @refresher_thread = Thread.new do
          refresher_thread_main
        end
      end

      # @return [void]
      def shutdown_refresher_thread
        @refresher_mutex.synchronize do
          @refresher_quit = true
          @refresher_cond.signal
        end
        @refresher_thread.join
        @refresher_thread = nil
      end

      # @return [void]
      def refresher_thread_main
        params = {
          mutex: @refresher_mutex,
          cond: @refresher_cond,
          interval: @refresh_interval,
          max_failures: @max_refresh_fails,
          check_quit: lambda { @refresher_quit },
          schedule_calculated: lambda { |timeout| @logger.debug "Next lock refresh in #{timeout}s" }
        }

        result = work_regularly(**params) do
          refresh_lock
        end

        if !result
          @logger.error("Lock refresh failed #{@max_refresh_fails} times in succession." \
            ' Declaring lock as unhealthy')
        end
      end

      # @return [void]
      def refresh_lock
        @logger.info 'Refreshing lock'
        begin
          file = @bucket.file(@path, skip_lookup: true)
          begin
            file.update(if_metageneration_match: @metageneration) do |f|
              f.metadata['expires_at'] = (Time.now + @ttl).to_f
            end
          rescue Google::Cloud::FailedPreconditionError
            raise 'Lock object has an unexpected metageneration number'
          rescue Google::Cloud::NotFoundError
            raise 'Lock object has been unexpectedly deleted'
          end

          @metageneration = file.metageneration
          @logger.debug 'Done refreshing lock'
          true
        rescue => e
          @logger.error("Error refreshing lock: #{e}")
          false
        end
      end
    end
  end
end

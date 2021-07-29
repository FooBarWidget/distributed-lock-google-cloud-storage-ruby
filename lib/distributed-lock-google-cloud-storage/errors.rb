# frozen_string_literal: true

module DistributedLock
  module GoogleCloudStorage
    class Error < StandardError; end
    class BucketNotFoundError < Error; end
    class LockError < Error; end
    class MetadataParseError < Error; end
    class NotLockedError < Error; end
    class LockUnhealthyError < Error; end
    class TimeoutError < Error; end
  end
end

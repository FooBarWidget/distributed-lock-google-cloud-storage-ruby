# Distributed lock based on Google Cloud Storage

## Introduction

This is a Ruby implementation of a [distributed locking algorithm based on Google Cloud Storage](https://www.joyfulbikeshedding.com/blog/2021-05-19-robust-distributed-locking-algorithm-based-on-google-cloud-storage.html). This means the algorithm uses Google Cloud Storage to coordinate concurrency and to store shared state.

### What's this for?

A distributed lock is like a regular Mutex, but works across processes and machines. It's useful for making distributed (multi-machine) workloads concurrency-safe.

One concrete use case in CI/CD pipelines. For example, [Fullstaq Ruby's](https://fullstaqruby.org) CI/CD pipeline [builds and publishes APT/YUM packages to shared storage](https://github.com/fullstaq-labs/fullstaq-ruby-server-edition/blob/main/dev-handbook/apt-yum-repo.md). Because multiple CI runs can be active concurrently, I needed something to ensure that they don't corrupt each others' work by writing to the same shared storage concurrently.

There are many ways to manage concurrency. Work queues is a popular method. But in Fullstaq Ruby's case, that requires setting up additional infrastructure and/or complicating CI/CD code. I deemed using a distributed lock to be the simplest solution.

### When to use

This distributed lock is **high-latency**. A locking operation's average speed is in the order of hundreds of milliseconds. In the worst case (when the algorithm detects that a client left without releasing the lock), it could take several tens of seconds to several minutes to obtain a lock, depending on the specific timing settings. Use this lock only if your workload can tolerate such a latency.

### Reliability

TLDR: it's pretty reliable.

We use Google Cloud Storage for storing shared locking state and for coordinating concurrency primitives. Thus, our reliability depends partially on Google Cloud Storage's own availability. Google Cloud Storage's availability reputation is pretty good.

The algorithm is designed to automatically recover from any error condition (besides Google Cloud Storage availability) that I could think of. Thus, this distributed lock is **low-maintenance**: things should just work. Just keep in mind that auto-recovery could take several minutes depending on the specific timing settings.

The most important error condition is that clients of the lock could leave unexpectedly (e.g. a crash), without explicitly releasing the lock. Many other implementations don't handle this situation well: they freeze up, requiring an administrator to manually release the lock. We recover automatically from this situation. See also [how I designed this algorithm](https://www.joyfulbikeshedding.com/blog/2021-05-19-robust-distributed-locking-algorithm-based-on-google-cloud-storage.html).

### Comparisons with alternatives

Other distributed locks based on Google Cloud Storage include:

 * [gcslock](https://github.com/mco-gh/gcslock)
 * [gcs-mutex-lock](https://github.com/thinkingmachines/gcs-mutex-lock)
 * [gcslock-ruby](https://github.com/XaF/gcslock-ruby)

In designing my own algorithm, I've carefully examined the above alternatives (and more). They all have various issues, including being prone to crashes, utilizing unbounded backoff, being prone to unintended lock releases due to networking issues, and more. My algorithm addresses all issues not addressed by the above alternatives. Please read [the algorithm design](https://www.joyfulbikeshedding.com/blog/2021-05-19-robust-distributed-locking-algorithm-based-on-google-cloud-storage.html) to learn more.

## Installation

Add to your Gemfile:

~~~Gemfile
gem 'distributed-lock-google-cloud-storage'
~~~

## Usage

Initialize a Lock instance. It must be backed by a Google Cloud Storage bucket and object. Then do your work within a `#synchronize` block.

**Important:** If your work is a long-running operation, then also be sure to call `#check_health!` _periodically_ to check whether the lock is still healthy. This call throws an exception if it's not healthy. Learn more in [Long-running operations, lock refreshing and lock health checking](#long-running-operations-lock-refreshing-and-lock-health-checking).

~~~ruby
require 'distributed-lock-google-cloud-storage'

lock = DistributedLock::GoogleCloudStorage::Lock(
  bucket_name: 'your bucket name',
  path: 'locks/mywork')
lock.synchronize do
  do_some_work

  # IMPORTANT: _periodically_ call this!
  lock.check_health!

  do_more_work
end
~~~

### Google Cloud authentication

We use [Application Default Credentials](https://cloud.google.com/docs/authentication/production#automatically) by default. If you don't want that, then pass a `cloud_storage_options` argument to the constructor, in which you set the `credentials` option.

~~~ruby
DistributedLock::GoogleCloudStorage::Lock(
  bucket_name: 'your bucket name',
  path: 'locks/mywork',
  cloud_storage_options: {
    credentials: '/path/to/keyfile.json'
  }
)
~~~

`credentials` is anything accepted by [Google::Cloud::Storage.new's `credentials` parameter](https://googleapis.dev/ruby/google-cloud-storage/latest/Google/Cloud/Storage.html#new-class_method), which currently means it's one of these:

 * A String: a path to a keyfile.
 * A Hash: the contents of a keyfile.
 * A `Google::Auth::Credentials` object.

### Auto-recovery from stale locks

A lock is considered taken only if there's a corresponding object in Cloud Storage. Releasing the lock means deleting the object. A client could sometimes fail to delete the object — for example because of a crash, a freeze or a network problem. We automatically recover from this situation by putting a **time-to-live** (TTL) value on the object. If the object is older than its TTL value, then we consider the lock to be _stale_, and we'll automatically clean it up next time a client tries to obtain the lock.

The TTL value is configurable via the `ttl` parameter in the constructor. A lower TTL value allows faster recovery from stale locks, but has a higher risk of incorrectly detecting lock staleness. For example: maybe the original owner of the lock was only temporarily frozen because it lacked CPU time.

So the TTL should be generous, in the order of minutes. The default is 5 minutes.

### Long-running operations, lock refreshing and lock health checking

If you perform an operation inside the lock that *might* take longer than the TTL, then we call that a _long-running operation_. Performing such long-running operations is safe: you generally don't have to worry about the lock become stale during the operation. But you need to be aware of caveats.

We support long-running operations by _refreshing_ the lock's timestamp once in a while so that the lock does not become stale. This refreshing happens automatically in a background thread. It happens. The behavior of this refreshing operation is configurable through the `refresh_interval` and `max_refresh_fails` parameters in the constructor.

Refreshing _could_ fail, for example because of a network delays, or because some other client _still_ concluded that the lock is stale and took over ownership of the lock, or because something else unexpected happened to the object. If refreshing fails too many times consecutively, then we declare the lock as _unhealthy_.

Declaring unhealthiness is an asynchronous event, and does not directly affect your code's flow. We won't abort your code or force it to raise an exception. Instead, your code should periodically check whether the lock has been declared unhealthy. Once you detect it, you must **immediately abort work**, because another client could have taken over the lock's ownership by now.

> Aborting work is easier said than done, and comes with its own caveats. You should therefore read [this discussion](https://www.joyfulbikeshedding.com/blog/2021-05-19-robust-distributed-locking-algorithm-based-on-google-cloud-storage.html#dealing-with-inconsistent-operation-states).

There are two ways to check whether the lock is still healthy:

 * By calling `#check_health!`, which might throw a `DistributedLock::GoogleCloudStorage::LockUnhealthyError`.
 * By calling `#healthy?`, which returns a boolean.

Both methods are cheap, and internally only check for a flag. So it's fine to call these methods inside hot loops.

### Instant recovery from stale locks

Instant recovery works as follows: if a client A crashes (and fails to release the lock) and restarts, and in the mean time the lock hasn't been taken by another client B, then client A should be able to instantly retake onwership of the lock.

Instant recovery is distinct from the normal TTL-based auto-recovery mechanism. Instant recovery doesn't have to wait for the TTL to expire, nor does it come with the risk of incorrectly detecting the lock as stale. However, the situations in way instant recovery can be applied, is more limited.

#### How instant recovery works: instance identities

Instant recovery works through the use of _instance identities_. The instance identity is what the locking algorithm uses to uniquely identify clients.

The identity is unique on a per-thread basis, which makes the lock thread-safe. It also means that in order for instant recovery to work, the same thread that crashed (and failed to release the lock) has to restart its operation and attempt to obtain the lock again.

### Logging

By default, we log info, warning and error messages to stderr. If you want logs to be handled differently, then set the `logger` parameter in the constructor. For example, to only log warnings and errors:

~~~ruby
logger = Logger.new($stderr)
logger.level = Logger::WARN

DistributedLock::GoogleCloudStorage::Lock(
  bucket_name: 'your bucket name',
  path: 'locks/mywork',
  logger: logger,
)
~~~

### Troubleshooting

Do you have a problem with the lock and do you want to know why? Then enable debug logging. For example:

~~~ruby
logger = Logger.new($stderr)
logger.level = Logger::DEBUG

DistributedLock::GoogleCloudStorage::Lock(
  bucket_name: 'your bucket name',
  path: 'locks/mywork',
  logger: logger,
)
~~~

## Contributing

Please read the [Contribution guide](CONTRIBUTING.md).

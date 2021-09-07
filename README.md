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

**Important:** If your work is a long-running operation, then also be sure to call `#check_health!` _periodically_ to check whether the lock is still healthy. This call throws an exception if it's not healthy. Learn more in section "Lock health check".

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

## Google Cloud authentication

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

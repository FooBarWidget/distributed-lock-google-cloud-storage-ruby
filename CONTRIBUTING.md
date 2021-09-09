# Contribution guide

## Running tests

To run the test suite, you need a Google Cloud Storage bucket and a Service Account with a key. You must also set the following environment variables:

 * `TEST_GCLOUD_BUCKET` — the name of the bucket.
 * `TEST_GCLOUD_CREDENTIALS_PATH` — path to the Service Account's keyfile.

It's best to put these in a `.env` file so that you don't have to supply these variables over and over. The test suite automatically loads environment variables from `.env`.

Then run the test suite with:

~~~bash
bundle exec rspec
~~~

## Release process

 1. Bump the version number.
     1. Modify `version.rb`.
     2. Re-run `bundle install` to update the version number there.
     3. Commit.
 2. Ensure [the CI](https://github.com/FooBarWidget/distributed-lock-google-cloud-storage-ruby/actions) is successful.
 3. [Manually run the "CI/CD" workflow](https://github.com/FooBarWidget/distributed-lock-google-cloud-storage-ruby/actions/workflows/ci-cd.yml). Set the `create_release` and `push_gem` both to `true`. Wait until it finishes. This creates a draft release.
 4. Edit [the draft release](https://github.com/FooBarWidget/distributed-lock-google-cloud-storage-ruby/releases)'s notes and finalize the release.

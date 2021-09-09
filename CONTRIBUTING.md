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

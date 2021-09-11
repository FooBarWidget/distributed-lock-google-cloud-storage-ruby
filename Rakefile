desc 'Run tests'
task :test do
  sh 'bundle exec rspec'
end

desc 'Run Rubocop'
task :rubocop do
  sh 'bundle exec rubocop --color --fail-level warning --display-only-fail-level-offenses'
end

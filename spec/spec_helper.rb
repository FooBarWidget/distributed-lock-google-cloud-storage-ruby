require 'dotenv'

module Helpers
  def require_envvar(name)
    value = ENV[name]
    raise ArgumentError, "Required environment variable: #{name}" if value.to_s.empty?
    value
  end
end


Dotenv.load

RSpec.configure do |c|
  c.include Helpers
end

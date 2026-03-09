#!/usr/bin/env ruby
# generate_token.rb — Produces a valid JWT token using the same broken
# Digest::SHA256 scheme the app uses (intentionally vulnerable).
#
# Usage:  ruby generate_token.rb [subject] [secret]
#   Defaults: subject=scanner, secret=$JWT_SECRET or "vulnerable-secret-key"
#
# Can also run inside the Docker container:
#   docker compose exec app ruby generate_token.rb

require 'json'
require 'digest'
begin
  require 'base64'
rescue LoadError
  # Ruby 3.4+ removed base64 from default gems; use pack/unpack fallback
end

subject = ARGV[0] || 'scanner'
secret  = ARGV[1] || ENV['JWT_SECRET'] || 'vulnerable-secret-key'

def strict_b64(str)
  if defined?(Base64)
    Base64.strict_encode64(str)
  else
    [str].pack('m0')
  end
end

header  = strict_b64(JSON.generate({ alg: 'SHA256', typ: 'JWT' }))
payload = strict_b64(JSON.generate({
  sub: subject,
  iat: Time.now.to_i,
  name: 'DAST Scanner'
  # Note: no 'exp' — tokens never expire (vuln #2)
}))

signature = Digest::SHA256.hexdigest("#{header}.#{payload}.#{secret}")

token = "#{header}.#{payload}.#{signature}"
puts token

token = "#{header}.#{payload}.#{signature}"
puts token

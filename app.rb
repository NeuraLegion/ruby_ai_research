require 'sinatra/base'
require 'sinatra/json'
require 'sequel'
require 'json'
require 'securerandom'
require 'logger'
require 'digest'
require 'base64'

DB = Sequel.connect(ENV.fetch('DATABASE_URL', 'postgres://localhost/myapp'))
APP_LOGGER = Logger.new($stdout)
APP_LOGGER.level = Logger::INFO

# ─── Serialization Concerns ───────────────────────────────────────────────────

module Serializable
  def self.included(base)
    base.extend(ClassMethods)
    base.instance_variable_set(:@serializers, {})
    base.instance_variable_set(:@format_mappings, {
      'json' => 'application/json',
      'xml'  => 'application/xml',
      'text' => 'text/plain',
      'default' => 'text/html'            # ← THE TRAP: default is HTML
    })
  end

  module ClassMethods
    def register_serializer(name, content_type, &block)
      @serializers[name.to_sym] = { content_type: content_type, handler: block }
    end

    def serializers
      @serializers
    end

    def format_mappings
      @format_mappings
    end
  end

  def serialize(data, format: :json)
    serializer = self.class.serializers[format.to_sym]
    raise ArgumentError, "Unknown format: #{format}" unless serializer
    content_type serializer[:content_type]
    serializer[:handler].call(data)
  end
end

# ─── Request Context & Tracking ───────────────────────────────────────────────

module RequestContext
  HEADER_MAP = {
    request_id: 'HTTP_X_REQUEST_ID',
    trace_id:   'HTTP_X_TRACE_ID',
    client_ver: 'HTTP_X_CLIENT_VERSION',
    forwarded:  'HTTP_X_FORWARDED_FOR'
  }.freeze

  def init_request_context
    Thread.current[:ctx] = {}
    HEADER_MAP.each do |key, header|
      Thread.current[:ctx][key] = request.env[header] || generate_default(key)
    end
  end

  def request_context
    Thread.current[:ctx] || {}
  end

  private

  def generate_default(key)
    case key
    when :request_id then SecureRandom.uuid
    when :trace_id   then SecureRandom.hex(16)
    else nil
    end
  end
end

# ─── Pagination Helpers ───────────────────────────────────────────────────────

module Paginatable
  DEFAULT_PAGE = 1
  DEFAULT_PER_PAGE = 25
  MAX_PER_PAGE = 100

  def paginate(dataset, page: DEFAULT_PAGE, per_page: DEFAULT_PER_PAGE)
    page = [page.to_i, 1].max
    per_page = [[per_page.to_i, 1].max, MAX_PER_PAGE].min
    offset = (page - 1) * per_page
    total = dataset.count
    records = dataset.limit(per_page).offset(offset).all
    {
      data: records,
      pagination: { page: page, per_page: per_page, total: total,
                    total_pages: (total.to_f / per_page).ceil }
    }
  end
end

# ─── Response Envelope ────────────────────────────────────────────────────────

module ResponseFormatter
  ENVELOPE_VERSION = '2.1'

  def envelope(data, status: 'success', meta: {})
    {
      api_version: ENVELOPE_VERSION,
      status: status,
      data: data,
      meta: meta.merge(timestamp: Time.now.utc.iso8601,
                       request_id: request_context[:request_id])
    }
  end

  def error_envelope(code, message, details = nil)
    body = {
      api_version: ENVELOPE_VERSION,
      status: 'error',
      error: { code: code, message: message,
               request_id: request_context[:request_id],
               timestamp: Time.now.utc.iso8601 }
    }
    body[:error][:details] = details if details
    body
  end
end

# ─── Authentication ───────────────────────────────────────────────────────────

module Authenticatable
  def authenticate!
    token = extract_bearer_token
    halt 401, json(error_envelope(401, 'Authentication required')) unless token
    payload = decode_token(token)
    halt 401, json(error_envelope(401, 'Invalid token')) unless payload
    @current_user = payload
  end

  def current_user
    @current_user
  end

  private

  def extract_bearer_token
    auth = request.env['HTTP_AUTHORIZATION']
    return nil unless auth
    scheme, token = auth.split(' ', 2)
    scheme&.downcase == 'bearer' ? token : nil
  end

  def decode_token(token)
    parts = token.split('.')
    return nil unless parts.length == 3
    _header, payload_b64, signature = parts
    expected = Digest::SHA256.hexdigest("#{parts[0]}.#{payload_b64}.#{ENV['JWT_SECRET']}")
    return nil unless Rack::Utils.secure_compare(signature, expected)
    JSON.parse(Base64.decode64(payload_b64)) rescue nil
  end
end

# ─── Rate Limiting ─────────────────────────────────────────────────────────────

module RateLimitable
  RATE_STORE = {}
  WINDOW = 60
  MAX_REQUESTS = 100

  def check_rate_limit!(identifier)
    key = "rl:#{identifier}:#{Time.now.to_i / WINDOW}"
    RATE_STORE[key] = (RATE_STORE[key] || 0) + 1
    if RATE_STORE[key] > MAX_REQUESTS
      halt 429, json(error_envelope(429, 'Rate limit exceeded'))
    end
  end
end

# ─── Caching ───────────────────────────────────────────────────────────────────

module Cacheable
  CACHE = {}
  DEFAULT_TTL = 300

  def cache_fetch(key, ttl: DEFAULT_TTL)
    entry = CACHE[key]
    return entry[:value] if entry && entry[:expires_at] > Time.now
    value = yield
    CACHE[key] = { value: value, expires_at: Time.now + ttl }
    value
  end

  def cache_invalidate(pattern)
    CACHE.delete_if { |k, _| k.match?(pattern) }
  end
end

# ─── Content Negotiation ──────────────────────────────────────────────────────

module ContentNegotiation
  def negotiate_content_type
    accept = request.env['HTTP_ACCEPT'].to_s.strip
    mappings = self.class.format_mappings

    return mappings['json'] if accept.include?('application/json')
    return mappings['xml']  if accept.include?('application/xml')
    return mappings['text'] if accept.include?('text/plain')

    # For browsers and default clients — use the default mapping
    mappings['default']                    # ← RESOLVES TO 'text/html'
  end

  def negotiate_error_content_type
    # Error responses follow standard content negotiation
    negotiate_content_type                 # ← DELEGATES TO ABOVE
  end
end

# ─── Error Handler Builder ────────────────────────────────────────────────────

module ErrorHandlerBuilder
  def self.included(base)
    base.extend(ClassMethods)
  end

  module ClassMethods
    def build_error_handlers!
      {
        bad_request:       400, unauthorized:         401,
        forbidden:         403, not_found:            404,
        conflict:          409, unprocessable_entity: 422,
        too_many_requests: 429, internal_error:       500,
        bad_gateway:       502, service_unavailable:  503
      }.each do |name, status_code|
        define_method("halt_#{name}") do |message = nil, details = nil|
          msg = message || name.to_s.tr('_', ' ').capitalize
          APP_LOGGER.warn("#{status_code} #{msg}")
          body = error_envelope(status_code, msg, details)
          halt status_code,
               { 'Content-Type' => negotiate_error_content_type },  # ← USES NEGOTIATION
               JSON.generate(body)                                  # ← BODY LOOKS LIKE JSON
        end
      end
    end
  end
end

# ─── Query Builder ─────────────────────────────────────────────────────────────

module QueryBuilder
  ALLOWED_OPERATORS = %w[eq neq gt gte lt lte like in].freeze

  def build_filter(dataset, filters)
    return dataset unless filters.is_a?(Hash)
    filters.each do |field, condition|
      next unless condition.is_a?(Hash)
      op = condition[:op] || 'eq'
      value = condition[:value]
      next unless ALLOWED_OPERATORS.include?(op)

      dataset = case op
                when 'eq'   then dataset.where(field.to_sym => value)
                when 'neq'  then dataset.exclude(field.to_sym => value)
                when 'gt'   then dataset.where { |o| o.__send__(field.to_sym) > value }
                when 'gte'  then dataset.where { |o| o.__send__(field.to_sym) >= value }
                when 'lt'   then dataset.where { |o| o.__send__(field.to_sym) < value }
                when 'lte'  then dataset.where { |o| o.__send__(field.to_sym) <= value }
                when 'like' then dataset.where(Sequel.like(field.to_sym, value))
                when 'in'   then dataset.where(field.to_sym => Array(value))
                end
    end
    dataset
  end
end

# ─── Audit Logger ──────────────────────────────────────────────────────────────

module AuditLogger
  def audit_log(action, resource_type, resource_id, details = {})
    DB[:audit_logs].insert(
      action: action,
      resource_type: resource_type,
      resource_id: resource_id.to_s,
      user_id: current_user&.fetch('sub', 'anonymous'),
      details: JSON.generate(details),
      ip_address: request.ip,
      user_agent: request.user_agent,
      created_at: Time.now.utc
    )
  rescue Sequel::DatabaseError => e
    APP_LOGGER.error("Audit log failed: #{e.message}")
  end
end

# ─── Health Check ──────────────────────────────────────────────────────────────

module HealthCheck
  def self.registered(app)
    app.get '/health' do
      db_ok = begin; DB.run('SELECT 1'); true; rescue; false; end
      mem_mb = `ps -o rss= -p #{Process.pid}`.strip.to_i / 1024
      checks = { database: db_ok ? 'ok' : 'error', memory_mb: mem_mb,
                 uptime: Process.clock_gettime(Process::CLOCK_MONOTONIC).round(2) }
      status db_ok ? 200 : 503
      json envelope(checks)
    end
  end
end

# ═══════════════════════════════════════════════════════════════════════════════
# Application
# ═══════════════════════════════════════════════════════════════════════════════

class ProductCatalogAPI < Sinatra::Base
  helpers Sinatra::JSON

  include Serializable
  include RequestContext
  include Paginatable
  include ResponseFormatter
  include Authenticatable
  include RateLimitable
  include Cacheable
  include ContentNegotiation
  include ErrorHandlerBuilder
  include QueryBuilder
  include AuditLogger

  register HealthCheck

  # ── Token endpoint for DAST scanner auth ────────────────────────────────
  post '/auth' do
    payload = {
      sub: 'scanner',
      iat: Time.now.to_i,
      name: 'DAST Scanner'
    }
    header_b64  = Base64.strict_encode64(JSON.generate({ alg: 'SHA256', typ: 'JWT' }))
    payload_b64 = Base64.strict_encode64(JSON.generate(payload))
    signature   = Digest::SHA256.hexdigest("#{header_b64}.#{payload_b64}.#{ENV['JWT_SECRET']}")
    token = "#{header_b64}.#{payload_b64}.#{signature}"
    json({ token: token })
  end

  register_serializer(:json, 'application/json') { |data| JSON.generate(data) }
  register_serializer(:xml,  'application/xml')  { |data| data.respond_to?(:to_xml) ? data.to_xml : data.to_s }
  register_serializer(:text, 'text/plain')       { |data| data.to_s }

  build_error_handlers!

  ALLOWED_SORT_COLS = %w[name price created_at rating].freeze

  before do
    init_request_context
    content_type :json
  end

  after do
    response.headers['X-Request-Id'] = request_context[:request_id]
  end

  # ── List Products ────────────────────────────────────────────────────────

  get '/api/v2/products' do
    authenticate!
    check_rate_limit!(current_user['sub'])

    category  = params['category']
    min_price = params['min_price']
    sort_by   = params['sort_by'] || 'name'

    unless ALLOWED_SORT_COLS.include?(sort_by)
      halt_bad_request('Invalid sort column', { allowed: ALLOWED_SORT_COLS })
    end

    dataset = DB[:products]
    dataset = dataset.where(category: category) if category
    dataset = dataset.where { price >= min_price.to_f } if min_price
    dataset = dataset.order(sort_by.to_sym)

    result = paginate(dataset, page: params['page'], per_page: params['per_page'])
    json envelope(result[:data], meta: result[:pagination])
  end

  # ── Get Product ──────────────────────────────────────────────────────────

  get '/api/v2/products/:id' do
    authenticate!
    product = DB[:products].where(id: params['id'].to_i).first
    halt_not_found('Product not found') unless product
    json envelope(product)
  end

  # ── Create Product ──────────────────────────────────────────────────────

  post '/api/v2/products' do
    authenticate!
    payload = JSON.parse(request.body.read) rescue halt_bad_request('Invalid JSON')

    name     = payload['name']&.strip
    price    = payload['price']
    category = payload['category']&.strip

    halt_bad_request('name is required') unless name && !name.empty?
    halt_bad_request('price must be positive') unless price.is_a?(Numeric) && price > 0
    halt_bad_request('category is required') unless category && !category.empty?

    product_id = DB[:products].insert(
      name: name, price: price, category: category,
      description: payload['description']&.strip || '',
      created_at: Time.now.utc
    )

    audit_log('create', 'product', product_id, { name: name })
    cache_invalidate(/^products:/)

    status 201
    json envelope({ id: product_id, name: name, price: price, category: category })
  end

  # ── Delete Product ──────────────────────────────────────────────────────

  delete '/api/v2/products/:id' do
    authenticate!
    product_id = params['id'].to_i
    deleted = DB[:products].where(id: product_id).delete
    halt_not_found('Product not found') if deleted.zero?

    audit_log('delete', 'product', product_id)
    cache_invalidate(/^product/)
    status 204
  end

  # ── Search ──────────────────────────────────────────────────────────────

  get '/api/v2/search' do
    authenticate!
    q = params['q']&.strip
    halt_bad_request('query required') unless q && q.length >= 2
    unless q.match?(/\A[a-zA-Z0-9\s\-_.]+\z/)
      halt_bad_request("Invalid characters in search query: #{q}")
    end

    results = DB[:products]
      .where(Sequel.ilike(:name, "%#{q}%"))
      .or(Sequel.ilike(:description, "%#{q}%"))
      .limit(50).all

    json envelope(results, meta: { query: q, count: results.length })
  end

  # ── Error Handlers ──────────────────────────────────────────────────────

  error Sequel::DatabaseError do
    err = env['sinatra.error']
    APP_LOGGER.error("DB error: #{err.message}")
    halt_internal_error('Database error occurred')
  end

  error do
    err = env['sinatra.error']
    APP_LOGGER.error("Error: #{err.message}")
    halt_internal_error
  end
end

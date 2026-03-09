#!/usr/bin/env ruby
# db/migrate.rb — Create schema and seed data for the vulnerable app

require 'sequel'
require 'json'

DB = Sequel.connect(ENV.fetch('DATABASE_URL'))

puts "Creating tables..."

DB.create_table?(:products) do
  primary_key :id
  String :name, null: false
  Float :price, null: false
  String :category, null: false
  String :description, default: ''
  Float :rating, default: 0.0
  DateTime :created_at, default: Sequel::CURRENT_TIMESTAMP
end

DB.create_table?(:audit_logs) do
  primary_key :id
  String :action, null: false
  String :resource_type, null: false
  String :resource_id, null: false
  String :user_id
  String :details
  String :ip_address
  String :user_agent
  DateTime :created_at, default: Sequel::CURRENT_TIMESTAMP
end

puts "Seeding products..."

products = [
  { name: 'Wireless Headphones', price: 79.99, category: 'electronics', description: 'Bluetooth over-ear headphones with noise cancellation', rating: 4.5 },
  { name: 'USB-C Hub',          price: 49.99, category: 'electronics', description: 'Multi-port USB-C adapter with HDMI and Ethernet', rating: 4.2 },
  { name: 'Mechanical Keyboard', price: 129.99, category: 'electronics', description: 'Cherry MX Blue switches, RGB backlight', rating: 4.7 },
  { name: 'Standing Desk',      price: 399.99, category: 'furniture',   description: 'Electric height-adjustable desk, 60 inch', rating: 4.3 },
  { name: 'Ergonomic Chair',    price: 549.99, category: 'furniture',   description: 'Lumbar support mesh office chair', rating: 4.6 },
  { name: 'Monitor Arm',        price: 89.99,  category: 'furniture',   description: 'Dual monitor VESA mount with gas spring', rating: 4.1 },
  { name: 'Python Cookbook',     price: 39.99,  category: 'books',       description: 'Recipes for mastering Python 3', rating: 4.4 },
  { name: 'Security Engineering', price: 54.99, category: 'books',      description: 'Building dependable distributed systems', rating: 4.8 },
  { name: 'Webcam HD',          price: 69.99,  category: 'electronics', description: '1080p USB webcam with autofocus', rating: 3.9 },
  { name: 'Desk Lamp',          price: 34.99,  category: 'furniture',   description: 'LED desk lamp with adjustable brightness', rating: 4.0 },
]

products.each do |p|
  unless DB[:products].where(name: p[:name]).any?
    DB[:products].insert(p.merge(created_at: Time.now.utc))
  end
end

puts "Done. #{DB[:products].count} products in database."

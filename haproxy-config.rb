#!/usr/local/bin/ruby

require 'json'
require 'erb'
require 'fileutils'

ETCD_ENDPOINT = ENV['ETCD_ENDPOINT']
if ETCD_ENDPOINT.nil? || ETCD_ENDPOINT.empty?
  puts 'ETCD_ENDPOINT is not set... aborting'
  exit -1
end

BASE_URL = "#{ETCD_ENDPOINT}/v2/keys/registered?consistent=true&recursive=true"

def leaves_of(node)
  leaves = []
  case node.key? 'dir'
  when true
    leaves += node['nodes'].flat_map { |n| leaves_of(n) } if node['nodes']
  when false
    leaves += JSON.parse(node['value'])
  end
  leaves
end

def valid_port_groups(port_groups)
  valid_port_groups = {}
  port_groups.each_pair do |port_number, port_group|
    unless port_group.empty?
      first_image = port_group[0]['image']
      num_images_like_first = port_group.count { |port_info| port_info['image'] == first_image }
      if num_images_like_first == port_group.size
        valid_port_groups[port_number] = port_group
      else
        puts "Warning: port #{port_number} has been bound to different docker images - rejecting"
      end
    end
  end

  valid_port_groups
end

def get_port_groups
  response = JSON.load(`curl -sL "#{BASE_URL}" -XGET`)
  valid_port_groups(leaves_of(response['node']).group_by { |p| p['private_port'] })
end

def rebuild_config(port_groups)
  puts "Rebuilding Haproxy config..."
  puts ">> #{port_groups}"

  erb = ERB.new(File.read('/etc/haproxy/haproxy.cfg.erb'))
  FileUtils.copy('/etc/haproxy/haproxy.cfg', '/etc/haproxy/haproxy.cfg.bkup')
  File.open('/etc/haproxy/haproxy.cfg','w') do |file|
    file.puts "#{erb.result(binding)}"
  end
end

$port_groups = {}
loop do
  response = JSON.load(`curl -sL -m 60 "#{BASE_URL}&wait=true" -XGET`)
  port_groups = get_port_groups
  if port_groups != $port_groups
    $port_groups = port_groups
    rebuild_config($port_groups)
  end
end

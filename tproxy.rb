# frozen_string_literal: true

require 'base64'
require 'optparse'
require 'uri'
require 'json'

def parse_ss_link(ss_link)
  # Remove "ss://" prefix
  ss_link = ss_link[5..]

  # Split Link
  parts = ss_link.split('@')
  base64_info = parts[0]
  server_info = parts[1]

  # Split server information and remarks
  server_info_parts = server_info.split('#')
  server_address_port = server_info_parts[0]
  remarks = server_info_parts[1]

  # Resolve server address and port
  server_address, server_port = server_address_port.split(':')

  # Decode URL remarks
  decoded_remarks = URI.decode_www_form_component(remarks)

  # Base64 decode encrypted information
  decoded_info = Base64.decode64(base64_info)

  {
    "server": server_address,
    "server_port": server_port.to_i,
    "password": decoded_info.split(':').last,
    "method": decoded_info.split(':').first,
    "remarks": decoded_remarks
  }
end

def get_template_content(type)
  File.read(get_template_path(type))
end

def get_template_path(type)
  case type
  when 'config'
    'templates/config-template.json'
  when 'ss'
    'templates/ss-config-template.json'
  when 'pf'
    'templates/pf-template.conf'
  else
    ''
  end
end

def get_config_path(type)
  case type
  when 'config'
    File.absolute_path('./configs/config.json')
  when 'ss'
    File.absolute_path('./configs/ss-config.json')
  when 'pf'
    File.absolute_path('./configs/pf.conf')
  when 'cidr'
    File.absolute_path('./configs/direct_cidr.txt')
  else
    ''
  end
end

def write_config(type, value)
  file_path = get_config_path(type)
  File.write(file_path, value)
end

def get_config_content(type)
  File.read(get_config_path(type))
end

def subscribe(link)
  template_content = get_template_content('config')
  data = JSON.parse(template_content)
  data['subscribe'] = link
  pretty_json_str = JSON.pretty_generate(data)
  write_config('config', pretty_json_str)
  puts "Save subscribe: #{link} to ./configs/config.json."
  update_subscribe
end

def update_subscribe
  config_content = File.read('configs/config.json')
  # Replace placeholders in the template
  config = JSON.parse(config_content)
  # puts config
  data = `curl -s #{config['subscribe']}`
  ss_configs = Base64.decode64(data).split(/[\r\n]+/)
  array = ss_configs.map { |ss_config| parse_ss_link(ss_config) }
  # Read the template file
  ss_config_template = File.read('templates/ss-config-template.json')
  # puts ss_config_template
  ss_config = JSON.parse(ss_config_template)
  ss_config['servers'] = array
  # json_obj = JSON.parse(ss_config)
  pretty_json_str = JSON.pretty_generate(ss_config)

  pretty_json_str = pretty_json_str.gsub('"#{ss_redir_port}"', config['ss_redir_port'].to_s)

  write_config('ss', pretty_json_str)
  puts 'Update configs/ss-config.json .'
end

def update_cidr
  `curl  https://raw.githubusercontent.com/missdeer/daily-weekly-build/refs/heads/cidr/cn_cidr.txt > cidrs/direct/cn_cidr.txt`
end

def list_files_in_directory(dir_path)
  Dir.glob("#{dir_path}/*").select { |f| File.file?(f) }.map { |f| File.absolute_path(f) }
end

def update_pf_config
  # Get Configs.
  config_content = get_config_content('config')

  config = JSON.parse(config_content)
  ss_redir_port = config['ss_redir_port']
  pf_max_port = config['pf_max_port']
  pf_config = get_template_content('pf')
  # Update CIDR.
  direct_files = list_files_in_directory('./cidrs/')
  write_config('cidr', merge_files_data(direct_files))
  # Update PF config.
  pf_config = pf_config.gsub('#{direct_path}', get_config_path('cidr'))
                       .gsub('#{redir_port}', ss_redir_port.to_s)
                       .gsub('#{max_port}', pf_max_port.to_s)
  write_config('pf', pf_config)
end

def merge_files_data(files)
  files.map { |file| File.read(file) }.join("\n")
end

def start
  update_subscribe
  update_pf_config
  # Enable the system's IP forwarding feature.
  `sudo sysctl -w net.inet.ip.forwarding=1`
  # Enable the PF (Packet Filter) firewall.
  `sudo pfctl -e`
  # Refresh all rules, states, and queues of the Packet Filter (PF) firewall.
  `sudo pfctl -F all`
  # Specify the PF (Packet Filter firewall) configuration to be loaded.
  `sudo pfctl -f configs/pf.conf`
  # `sudo sslocal -c configs/ss-config.json`
end

def stop
  # Disable the system's IP forwarding feature.
  `sudo sysctl -w net.inet.ip.forwarding=0`
  # Refresh all rules, states, and queues of the Packet Filter (PF) firewall.
  `sudo pfctl -F all`
  # Disable the PF (Packet Filter) firewall.
  `sudo pfctl -d`
end

def restart
  stop
  start
end

commands = {
  'subscribe' => method(:subscribe),
  'update-cidr' => method(:update_cidr),
  'start' => method(:start),
  'stop' => method(:stop),
  'restart' => method(:restart)

}

OptionParser.new do |opts|
  opts.banner = 'Manage your tproxy in MacOS.'
  opts.separator ''
  opts.separator 'Usage:'
  opts.separator '  tproxy.rb [COMMAND]'
  opts.separator ''
  opts.separator 'Available Commands:'
  opts.separator '  subscribe <link>           Subscribe a proxy link.'
  opts.separator '  start                      Start a Transparent Proxy.'
  opts.separator '  list                       Stop a transparent Proxy.'
  opts.separator '  update-cidr                Update CIDR.'
end.parse!

command, *args = ARGV
commands[command].call(*args) if commands.key?(command)

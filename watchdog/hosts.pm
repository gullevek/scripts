package hosts;

# internal hosts
$host{'<id name>'}=( {
  "ip" => "<host IP>",
  "name" => "<name>",
  "services" => [ "ssh", "sunrpc", "domain", "munin", "zabbix" ],
  "not_run" => [ "telnet" ]
} );

#$host{'dummy'}=( {
#  "ip" => "123.123.123.123", # where connect to, can be also a name, but not recommended (what if DNS failes)
#  "name" => "some name here", # output name (need not to be a FQDN (is not needed ... ???)
#  "services" => [ "ssh", "http" ], # services that should run
#  "not_run" => [ "telnet" ] # services that should NOT run
#} );

1;

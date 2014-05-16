package servicemap;

# services that can be used for checking
%servicemap = ( 
	"ftp" => "21",
	"ssh" => "22",
	"telnet" => "23",
	"smtp" => "25", 
	"time" => "37",
	"domain" => "53", 
	"http" => "80", 
	"http81" => "81", 
	"linuxconf" => "98",
	"pop3pw" => "106",
	"pop-2" => "109",
	"pop-3" => "110", 
	"pop3" => "110", 
	"sunrpc" => "111", # NFS
	"nfs" => "111",
	"nntp" => "119",
	"netbios-ssn" => "139", #SAMBA
	"samba" => "139", #SAMBA
	"imap" => "143",
	"ldap" => "389",
	"onmux" => "417", # MeetingMaker Server
	"https" => "443", 
	"afpovertcp" => "548",
	"afp" => "548",
	"arkeia" => "617",
	"ldapssl" => "636",
	"arcservd" => "713",
	"imaps" => "993",
	"pop3s" => "995",
	"solid" => "1314", # siegi
	"ms-sql-s" => "1433",
	"cvspserver" => "2401",
	"mysql" => "3306",
	"filemaker" => "5003",
	"postgres" => "5432",
	"arcserve" => "6050",
	"jserv" => "8007",
	"tomcat" => "8080",
	"http-proxy" => "8080",
	"zabbix" => "10050",
	"munin" => "4949"
);

1;

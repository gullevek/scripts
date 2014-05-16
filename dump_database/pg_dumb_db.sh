#!/bin/bash

# Author: Clemens Schwaighofer
# Description:
# Dump one database as a custom postgresql dump (restorable with pg_restore)

function usage ()
{
	cat <<- EOT
	Usage: ${0##/*/} -u <DB_USER> -d <DB_NAME> [-h <DB_HOST>] [-p <DB_PORT>] [-i <POSTGRES VERSION>]

	-u <DB_USER>: The user name with which to connect to the database to dump
	-d <DB_NAME>: The database to dump
	-h <DB_HOST>: optional hostname, if not given 'locahost' is used
	-p <DB_PORT>: optional port number, if not given '5432' is used
	-i <POSTGRES VERSION>: optional postgresql version in the format X.Y, if not given the default is used (current active)

	EOT
}

_port=5432
_host='local';
# if we have options, set them and then ignore anything below
while getopts ":u:d:h:p:i:" opt
do
    case $opt in
        u|user)
            if [ -z "$user" ];
            then
                user=$OPTARG;
            fi;
            ;;
        d|database)
            if [ -z "$database" ];
            then
                database=$OPTARG;
            fi;
            ;;
        h|hostname)
            if [ -z "$host" ];
            then
				host='-h '$OPTARG;
				_host=$OPTARG;
            fi;
            ;;
        p|port)
            if [ -z "$port" ];
            then
				port='-p '$OPTARG;
				_port=$OPTARG;
            fi;
            ;;
        i|ident)
            if [ -z "$ident" ];
            then
                ident=$OPTARG;
            fi;
            ;;
        h|help)
            usage;
            exit 0;
            ;;
        \?)
            echo -e "\n Option does not exist: $OPTARG\n";
            usage;
            exit 1;
			;;
    esac;
done;

# if no user or database, exist
if [ ! "$user" ] || [ ! "$database" ];
then
	echo "The username and the database name have to be set via the command line options.";
	exit 1;
fi;

# Debian base path
PG_BASE_PATH='/usr/lib/postgresql/';
# Redhat base path (for non official ones would be '/usr/pgsql-'

# if no ident is given, try to find the default one, if not fall back to pre set one
if [ ! -z "$ident" ];
then
	PG_PATH=$PG_BASE_PATH$ident'/bin/';
	if [ ! -d "$PG_PATH" ];
	then
		ident='';
	fi;
fi;
if [ -z "$ident" ];
then
	# try to run psql from default path and get the version number
	ident=`pg_dump --version | grep "pg_dump" | cut -d " " -f 3 | cut -d "." -f 1,2`;
	if [ ! -z "$ident" ];
	then
		PG_PATH=$PG_BASE_PATH$ident'/bin/';
	else
		# hard setting
		ident='9.3';
		PG_PATH=$PG_BASE_PATH'9.3/bin/';
	fi;
fi;

PG_DUMP=$PG_PATH"pg_dump";
PG_PSQL=$PG_PATH"psql";
echo "Using PostgreSQL version: $ident";

# pre check if this DB / user exists or is acccessable
output=`echo "SELECT version();" | $PG_PSQL -U $user $host $port $database -q -t -X -A -F "," 2>&1`;
found=`echo "$output" | grep "PostgreSQL"`;
# if the output does not have the PG version string, we have an error and abort
if [ -z "$found" ];
then
	echo "Cannot connect to the database: $output";
	exit 1;
fi;

#ikea_mobile_demo.ikea.pgsql-9.3_5432_20140127_1206_0-8.sql
sequence=*;
# file format is "DB"."User"."type-version"_"port"_"host"_"date"_"time"_"seq"-".c.sql"
file=$database"."$user.".pgsql-"$ident"_"$_host"_"$_port"_"`date +"%Y%m%d"`"_"`date +%H%M`"."$sequence".c.sql";
# we need to find the next sequence
for i in `ls -1 $file 2>/dev/null`;
do
	seq=`echo $i | cut -d "." -f 3 | sed -e "s/^0//g"`;
done;
if [ $seq ];
then
	# add +1 and if < 10 prefix with 0
	let seq=$seq+1;
	if [ $seq -lt 10 ];
	then
		sequence="0"$seq;
	else
		sequence=$seq;
	fi;
else
	sequence="01";
fi;
# now build correct file name
file=$database"."$user."pgsql-"$ident"_"$_host"_"$_port"_"`date +"%Y%m%d"`"_"`date +%H%M`"."$sequence".c.sql";

start_time=`date +"%F %T"`;
START=`date +'%s'`;
log_file="dump_output."$database"."`date +"%F_%T"`;
echo "[$start_time] Will dump database '$database' on host '$_host:$_port' and with user '$user' to file '$file'";
time $PG_DUMP -U $user -F c -c -v $host $port -f $file $database 2>$log_file;
DURATION=$[ `date +'%s'`-$START ];
echo "Start at $start_time and end at `date +"%F %T"` and ran for $DURATION seconds";
echo "=== END DUMP" >>$log_file;

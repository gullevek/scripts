#!/bin/bash

# Author: Clemens Schwaighofer
# Description:
# Dump and restore one database

function usage ()
{
	cat <<- EOT
	Usage: ${0##/*/} -o <DB OWNER> -d <DB NAME> -f <FILE NAME> [-h <DB HOST>] [-p <DB PORT>] [-i <POSTGRES VERSION>]

	-o <DB OWNER>: The user who will be owner of the database to be restored
	-d <DB NAME>: The database to restore the file to
	-f <FILE NAME>: the data that should be loaded
	-h <DB HOST>: optional hostname, if not given 'locahost' is used
	-p <DB PORT>: optional port number, if not given '5432' is used
	-i <POSTGRES VERSION>: optional postgresql version in the format X.Y, if not given the default is used (current active)

	EOT
}

_port=5432
_host='local';
NO_ASK=0;
# if we have options, set them and then ignore anything below
while getopts ":o:d:h:f:p:i:q" opt
do
    case $opt in
        o|owner)
            if [ -z "$owner" ];
            then
                owner=$OPTARG;
            fi;
            ;;
        d|database)
            if [ -z "$database" ];
            then
                database=$OPTARG;
            fi;
            ;;
        f|file)
            if [ -z "$file" ];
            then
				file=$OPTARG;
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
		q|quiet)
			NO_ASK=1;
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

# if file is set and exist, but no owner or database are given, use the file name data to get user & database
if [ -r "$file" ] && ( [ ! "$owner" ] || [ ! "$database" ] );
then
	# file name format is
	# <owner>.<database>.<db type>-<version>_<port>_<host>_<date>_<time>_<sequence>
	# we only are interested in the first two
	_owner=`echo $file | cut -d "." -f 1`;
	_database=`echo $file | cut -d "." -f 2`;
	# set the others as optional
	_ident=`echo $file | cut -d "." -f 3 | cut -d "_" -f 1 | cut -d "-" -f 2`;
	__port=`echo $file | cut -d "_" -f 2`;
	__host=`echo $file | cut -d "_" -f 3`;
	# if any of those are not set, override by the file name settings
	if [ ! "$owner" ];
	then
		owner=$_owner;
	fi;
	if [ ! "$database" ];
	then
		database=$_database;
	fi;
	if [ ! "$port" ];
	then
		port='-p '$__port;
		_port=$__port;
	fi;
	# unless it is local and no command line option is set, set the target connection host
	if [ ! "$host" ] && [ "$__host" != "local" ];
	then
		host='-h '$__host;
		_host=$__host;
	fi;
	if [ ! "$_ident" ];
	then
		ident=$_ident;
	fi;
fi;

# if no user or database, exist
if [ ! "$owner" ] || [ ! "$database" ] || [ ! "$file" ] || [ ! -f "$file" ];
then
	echo "The database owner name, database name and file name have to be set via the command line options.";
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

PG_DROPDB=$PG_PATH"dropdb";
PG_CREATEDB=$PG_PATH"createdb";
PG_CREATELANG=$PG_PATH"createlang";
PG_RESTORE=$PG_PATH"pg_restore";
PG_PSQL=$PG_PATH"psql";
MAX_JOBS=4; # if there are more CPU cores available, this can be set higher
TEMP_FILE="temp";
LOG_FILE_EXT=$database.`date +"%Y%m%d_%H%M%S"`".log";
echo "USING POSTGRESQL: $ident";

# check if port / host settings are OK
# if I cannot connect with user postgres to template1, the restore won't work
output=`echo "SELECT version();" | $PG_PSQL -U postgres $host $port template1 -q -t -X -A -F "," 2>&1`;
found=`echo "$output" | grep "PostgreSQL"`;
# if the output does not have the PG version string, we have an error and abort
if [ -z "$found" ];
then
	echo "Cannot connect to the database: $output";
	exit 1;
fi;

echo "Will drop database '$database' on host '$_host:$_port' and load file '$file' with user '$owner' and use database version '$ident'";
if [ $NO_ASK -eq 1 ];
then
	go='yes';
else
	echo "Continue? type 'yes'";
	read go;
fi;
if [ "$go" != 'yes' ];
then
	echo "Aborted";
	exit;
else
	start_time=`date +"%F %T"`;
	START=`date +'%s'`;
	echo "Drop DB $database [$_host:$_port] @ $start_time";
	$PG_DROPDB -U postgres $host $port $database;
	echo "Create DB $database with $owner [$_host:$_port] @ `date +"%F %T"`";
	$PG_CREATEDB -U postgres -O $owner -E utf8 $host $port $database;
	echo "Create plpgsql lang in DB $database [$_host:$_port] @ `date +"%F %T"`";
	$PG_CREATELANG -U postgres plpgsql $host $port $database;
	echo "Restore data from $file to DB $database [$_host:$_port] @ `date +"%F %T"`";
	$PG_RESTORE -U postgres -d $database -F c -v -c -j $MAX_JOBS $host $port $file 2>restore_errors.$LOG_FILE_EXT;
	echo "Resetting all sequences from DB $database [$_host:$_post] @ `date +"%F %T"`";
	echo "SELECT 'SELECT SETVAL(' ||quote_literal(S.relname)|| ', MAX(' ||quote_ident(C.attname)|| ') ) FROM ' ||quote_ident(T.relname)|| ';' FROM pg_class AS S, pg_depend AS D, pg_class AS T, pg_attribute AS C WHERE S.relkind = 'S' AND S.oid = D.objid AND D.refobjid = T.oid AND D.refobjid = C.attrelid AND D.refobjsubid = C.attnum ORDER BY S.relname;" | $PG_PSQL -U $owner -Atq $host $post -o $TEMP_FILE $database
	$PG_PSQL -U $owner $host $port -e -f $TEMP_FILE $database 1>output_sequence.$LOG_FILE_EXT 2>errors_sequence.$database.$LOG_FILE_EXT;
	rm $TEMP_FILE;
	echo "Restore of data $file for DB $database [$_host:$_port] finished";
	DURATION=$[ `date +'%s'`-$START ];
	echo "Start at $start_time and end at `date +"%F %T"` and ran for $DURATION seconds";
	echo "=== END RESTORE" >>restore_errors.$LOG_FILE_EXT;
fi;

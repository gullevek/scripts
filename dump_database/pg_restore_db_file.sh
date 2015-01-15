#!/bin/bash

function usage ()
{
	cat <<- EOT
	Usage: ${0##/*/} -f <dump folder> [-r] [-g]

	-f: dump folder source. Where the database dump files are located. This is a must set option
	-r: use redhat base paths instead of debian
	-g: do not import globals file
	EOT
}

REDHAT=0;
IMPORT_GLOBALS=1;
DUMP_FOLDER='';
while getopts ":f:gr" opt
do
	case $opt in
		f|file)
			DUMP_FOLDER=$OPTARG;
			;;
		g|globals)
			IMPORT_GLOBALS=0;
			;;
		r|redhat)
			REDHAT=1;
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

if [ "$REDHAT" -eq 1 ];
then
	# Redhat base path (for non official ones would be '/usr/pgsql-'
	DBPATH_BASE='/usr/pgsql-'
else
	# Debian base path
	DBPATH_BASE='/usr/lib/postgresql/';
fi;

LOGS=$DUMP_FOLDER'logs/';

if [ "$DUMP_FOLDER" = '' ];
then
	echo "Please provide a source folder for the dump files with the -f option";
	exit;
fi;

# check that source folder is there
if [ ! -d "$DUMP_FOLDER" ];
then
	echo "Folder '$DUMP_FOLDER' does not exist";
	exit;
fi;

# create logs folder if missing
if [ ! -d "$LOGS" ];
then
	echo "Creating '$LOGS' folder";
	mkdir -p "$LOGS";
	if [ ! -d "$LOGS" ];
	then
		echo "Creation of '$LOGS' folder failed";
		exit;
	fi;
fi;

# default version (for folder)
DBPATH_VERSION='9.4/';
DBPATH_BIN='bin/';
# postgresql binaries
DROPDB="dropdb";
CREATEDB="createdb";
CREATELANG="createlang";
PGRESTORE="pg_restore";
CREATEUSER="createuser";
PSQL="psql";
# default port and host
PORT=5432;
HOST='localhost';
EXCLUDE_LIST="pg_globals"; # space separated
LOGFILE="tee -a $LOGS/PG_RESTORE_DB_FILE.`date +"%F_%T"`.log";

# just set port & host for internal use
port='-p '$PORT;
host='-h '$HOST;
_port=$PORT;
_host=$HOST;

# get the count for DBs to import
db_count=`find $DUMP_FOLDER -name "*.sql" -print | wc -l`;
# start info
echo "= Will import $db_count from $DUMP_FOLDER" | $LOGFILE;
echo "= into the DB server $HOST:$PORT" | $LOGFILE;
echo "= import logs: $LOGS" | $LOGFILE;
echo "" | $LOGFILE;
pos=1;
# go through all the files an import them into the database
MASTERSTART=`date +'%s'`;
master_start_time=`date +"%F %T"`;
# first import the pg_globals file if this is requested, default is yes
if [ "$IMPORT_GLOBALS" -eq 1 ];
then
	start_time=`date +"%F %T"`;
	START=`date +'%s'`;
	# get the pg_globals file
	echo "=[Globals Restore]=START=[$start_time]==================================================>" | $LOGFILE;
	# get newest and only the first one
	file=`ls -1t $DUMP_FOLDER/pg_global* | head -1`;
	filename=`basename $file`;
	version=`echo $filename | cut -d "." -f 3 | cut -d "-" -f 2`; # db version, without prefix of DB type
	version=$version'.'`echo $filename | cut -d "." -f 4 | cut -d "_" -f 1`; # db version, second part (after .)
	# create the path to the DB from the DB version in the backup file
	if [ ! -z "$version" ];
	then
		DBPATH_VERSION_LOCAL=$version'/';
	else
		DBPATH_VERSION_LOCAL=$DBPATH_VERSION;
	fi;
	DBPATH=$DBPATH_BASE$DBPATH_VERSION_LOCAL$DBPATH_BIN;
	echo "+ Restore globals file: $filename to [$_host:$_port] @ `date +"%F %T"`" | $LOGFILE;
	$DBPATH$PSQL -U postgres $host $port -f $file -e -q -X template1 | $LOGFILE;
	DURATION=$[ `date +'%s'`-$START ];
	printf "=[Globals Restore]=END===[%5s seconds]========================================================>\n" $DURATION | $LOGFILE;
fi;
for file in $DUMP_FOLDER/*.sql;
do
	start_time=`date +"%F %T"`;
	START=`date +'%s'`;
	echo "=[$pos/$db_count]=START=[$start_time]==================================================>" | $LOGFILE;
	# get the filename
	filename=`basename $file`;
	# get the databse, user
	# default file name is <database>_<owner>.<type>-<version>_<host>_<port>_<date>_<time>_<sequence>
	database=`echo $filename | cut -d "." -f 1`;
	owner=`echo $filename | cut -d "." -f 2`;
	version=`echo $filename | cut -d "." -f 3 | cut -d "-" -f 2`; # db version, without prefix of DB type
	version=$version'.'`echo $filename | cut -d "." -f 4 | cut -d "_" -f 1`; # db version, second part (after .)
	host_name=`echo $filename | cut -d "." -f 4 | cut -d "_" -f 2`; # hostname of original DB, can be used as target host too
	dump_port=`echo $filename | cut -d "." -f 4 | cut -d "_" -f 3`; # port of original DB, can be used as target port too
	other=`echo $filename | cut -d "." -f 4 | cut -d "_" -f 2-`; # backup date and time, plus sequence
	# create the path to the DB from the DB version in the backup file
	if [ ! -z "$version" ];
	then
		DBPATH_VERSION_LOCAL=$version'/';
	else
		DBPATH_VERSION_LOCAL=$DBPATH_VERSION;
	fi;
	DBPATH=$DBPATH_BASE$DBPATH_VERSION_LOCAL$DBPATH_BIN;
	# check this is skip or not
	exclude=0;
	for exclude_db in $EXCLUDE_LIST;
	do
		if [ "$exclude_db" = "$database" ];
		then
			exclude=1;
		fi;
	done;
	if [ $exclude -eq 0 ];
	then
		# create user if not exist yet
		# check query for user
		user_oid=`echo "SELECT oid FROM pg_roles WHERE rolname = '$owner';" | $PSQL -U postgres $host $port -A -F "," -t -q -X template1`;
		if [ -z $user_oid ];
		then
			echo "+ Create USER '$owner' for DB '$database' [$_host:$_port] @ `date +"%F %T"`" | $LOGFILE;
			$CREATEUSER -U postgres -D -R -S $host $port $owner;
		fi;
		# before importing the data, drop this database
		echo "- Drop DB '$database' [$_host:$_port] @ `date +"%F %T"`" | $LOGFILE;
		$DBPATH$DROPDB -U postgres $host $port $database;
		echo "+ Create DB '$database' with '$owner' [$_host:$_port] @ `date +"%F %T"`" | $LOGFILE;
		$DBPATH$CREATEDB -U postgres -O $owner -E utf8 $host $port $database;
		echo "+ Create plpgsql lang in DB '$database' [$_host:$_port] @ `date +"%F %T"`" | $LOGFILE;
		$DBPATH$CREATELANG -U postgres plpgsql $host $port $database;
		echo "% Restore data from '$filename' to DB '$database' [$_host:$_port] @ `date +"%F %T"`" | $LOGFILE;
		$DBPATH$PGRESTORE -U postgres -d $database -F c -v -c -j 4 $host $port $file 2>$LOGS'/errors.'$database'.'`date +"%F_%T"`;
		echo "$ Restore of data '$filename' for DB '$database' [$_host:$_port] finished" | $LOGFILE;
		DURATION=$[ `date +'%s'`-$START ];
		echo "* Start at $start_time and end at `date +"%F %T"` and ran for $DURATION seconds" | $LOGFILE;
	else
		DURATION=0;
		echo "# Skipped DB '$database'" | $LOGFILE;
	fi;
	printf "=[$pos/$db_count]=END===[%5s seconds]========================================================>\n" $DURATION | $LOGFILE;
	pos=$[ $pos+1 ];
done;
DURATION=$[ `date +'%s'`-$MASTERSTART ];
echo "" | $LOGFILE;
echo "= Start at $master_start_time and end at `date +"%F %T"` and ran for $DURATION seconds. Imported $db_count databases." | $LOGFILE;

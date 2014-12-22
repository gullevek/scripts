#!/bin/bash

DUMP_FOLDER='/<source folder>/';
DBPATH_BASE='/usr/lib/postgresql/';
#DBPATH_BASE='/usr/pgsql-'
DBPATH_VERSION='9.3/';
DBPATH_BIN='bin/';
DROPDB="dropdb";
CREATEDB="createdb";
CREATELANG="createlang";
PGRESTORE="pg_restore";
CREATEUSER="createuser";
PSQL="psql";
PORT=5432;
HOST='localhost';
LOGS=$DUMP_FOLDER'logs/';
EXCLUDE_LIST="pg_globals"; # space separated

# check that source folder is there
if [ ! -d "$DUMP_FOLDER" ];
then
	echo "Folder $DUMP_FOLDER does not exist";
	exit;
fi;

# create logs folder if missing
if [ ! -d "$LOGS" ];
then
	echo "Creating $LOGS folder";
	mkdir -p "$LOGS";
fi;

# just set port & host for internal use
port='-p '$PORT;
host='-h '$HOST;
_port=$PORT;
_host=$HOST;

# get the count for DBs to import
db_count=`find $DUMP_FOLDER -name "*.sql" -print | wc -l`;
# start info
echo "= Will import $db_count from $DUMP_FOLDER";
echo "= into the DB server $HOST:$PORT";
echo "= import logs: $LOGS";
echo "";
pos=1;
# go through all the files an import them into the database
MASTERSTART=`date +'%s'`;
master_start_time=`date +"%F %T"`;
for file in $DUMP_FOLDER/*;
do
	start_time=`date +"%F %T"`;
	START=`date +'%s'`;
	echo "=[$pos/$db_count]=START=[$start_time]==================================================>";
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
			echo "+ Create USER '$owner' for DB '$database' [$_host:$_port] @ `date +"%F %T"`";
			$CREATEUSER -U postgres -D -R -S $owner;
		fi;
		# before importing the data, drop this database
		echo "- Drop DB '$database' [$_host:$_port] @ `date +"%F %T"`";
		$DBPATH$DROPDB -U postgres $host $port $database;
		echo "+ Create DB '$database' with '$owner' [$_host:$_port] @ `date +"%F %T"`";
		$DBPATH$CREATEDB -U postgres -O $owner -E utf8 $host $port $database;
		echo "+ Create plpgsql lang in DB '$database' [$_host:$_port] @ `date +"%F %T"`";
		$DBPATH$CREATELANG -U postgres plpgsql $host $port $database;
		echo "% Restore data from '$filename' to DB '$database' [$_host:$_port] @ `date +"%F %T"`";
		$DBPATH$PGRESTORE -U postgres -d $database -F c -v -c -j 4 $host $port $file 2>$LOGS'/errors.'$database'.'`date +"%F_%T"`;
		echo "$ Restore of data '$filename' for DB '$database' [$_host:$_port] finished";
		DURATION=$[ `date +'%s'`-$START ];
		echo "* Start at $start_time and end at `date +"%F %T"` and ran for $DURATION seconds";
	else
		DURATION=0;
		echo "# Skipped DB '$database'";
	fi;
	printf "=[$pos/$db_count]=END===[%5s seconds]========================================================>\n" $DURATION;
	pos=$[ $pos+1 ];
done;
DURATION=$[ `date +'%s'`-$MASTERSTART ];
echo "";
echo "= Start at $master_start_time and end at `date +"%F %T"` and ran for $DURATION seconds. Imported $db_count databases.";

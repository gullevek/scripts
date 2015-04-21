#!/bin/bash

# dumps all the databases in compressed (custom) format
# EXCLUDE: space seperated list of database names to be skipped
# KEEP: how many files to keep, eg 3 means, keep 3 days + todays backup
# the file format includes the database name and owner:
# <database name>.<owner>.<database type>-<version>_<host>_<port>_<date in YYYYMMDD>_<time in HHMM>_<sequenze in two digits with leading 0>.sql

function usage ()
{
	cat <<- EOT
	Usage: ${0##/*/} [-t] [-s] [-g] [-c] [-r|-a] [-k <number to keep>] [-b <path>] [-i <postgreSQL version>] [-d <dump database name> [-d ...]] [-e <exclude dump> [-e ...]] [-u <db user>] [-h <db host>] [-p <db port>] [-l <db password>]

	-t: test usage, no real backup is done
	-s: turn ON ssl mode, default mode is off
	-g: turn OFF dumping globals data, default is dumping globals data
	-c: run clean up of old files before data is dumped. Default is run after data dump.
	-k: keep how many backups, default is 3
	-b <path>: backup target path, if not set, /mnt/backup/db_dumps_fc/ is used
	-i <version>: override automatically set database version
	-d <name>: database name to dump, option can be given multiple times, if not set all databases are dumped
	-e <name>: exclude database from dump, option can be given multiple times, if not set non are excluded
	-u <db user>: default is 'postgres'
	-h <db host>: default is none
	-p <db port>: default port is '5432'
	-l <db password>: default password is empty
	-r: use redhat base paths instead of debian
	-a: use amazon base paths instead of debian
	EOT
}

TEST=0; # if set to 1 will run script without doing anything
SSLMODE=disable;
GLOBALS=1; # if set to 0 will not dump globals
KEEP=3; # in days, keeps KEEP+1 files, today + KEEP days before
BACKUPDIR='';
DB_VERSION=;
DB_USER='';
DB_PASSWD='';
DB_HOST='';
DB_PORT=;
EXCLUDE=''; # space separated list of database names
INCLUDE=''; # space seperated list of database names
BC='/usr/bin/bc';
PRE_RUN_CLEAN_UP=0;
SET_IDENT=0;
PORT_REGEX="^[0-9]{4,5}$";
# defaults
_BACKUPDIR='/mnt/backup/db_dumps_fc/';
_DB_VERSION=`pg_dump --version | grep "pg_dump" | cut -d " " -f 3 | cut -d "." -f 1,2`;
_DB_USER='postgres';
_DB_PASSWD='';
_DB_HOST='';
_DB_PORT=5432;
_EXCLUDE=''; # space separated list of database names
_INCLUDE=''; # space seperated list of database names
REDHAT=0;
AMAZON=0;

# set options
while getopts ":ctsgk:b:i:d:e:u:h:p:l:ra" opt
do
	case $opt in
		t|test)
			TEST=1;
			;;
		g|globals)
			GLOBALS=0;
			;;
		c|clean-up-before)
			PRE_RUN_CLEAN_UP=1;
			;;
		s|sslmode)
			SSLMODE=enable;
			;;
		k|keep)
			KEEP=$OPTARG;
			;;
		b|backuppath)
			if [ -z "$BACKUPDIR" ];
			then
				BACKUPDIR=$OPTARG;
			fi;
			;;
		i|ident)
			if [ -z "$DB_VERSION" ];
			then
				DB_VERSION=$OPTARG;
				SET_IDENT=1;
			fi;
			;;
		u|user)
            if [ -z "$DB_USER" ];
            then
                DB_USER=$OPTARG;
            fi;
            ;;
        h|hostname)
            if [ -z "$DB_HOST" ];
            then
				DB_HOST=$OPTARG;
            fi;
            ;;
        p|port)
            if [ -z "$DB_PORT" ];
            then
				DB_PORT=$OPTARG;
            fi;
            ;;
        l|login)
            if [ -z "$DB_PASSWD" ];
            then
				DB_PASSWD=$OPTARG;
            fi;
            ;;
		d|database)
			if [ ! -z "$INCLUDE" ];
			then
				INCLUDE=$INCLUDE" ";
			fi;
			INCLUDE=$INCLUDE$OPTARG;
			;;
		e|exclude)
			if [ ! -z "$EXCLUDE" ];
			then
				EXCLUDE=$EXCLUDE" ";
			fi;
			EXCLUDE=$EXCLUDE$OPTARG;
			;;
		r|redhat)
			REDHAT=1;
			;;
		a|amazon)
			AMAZON=1;
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

if [ "$REDHAT" -eq 1 ] && [ "$AMAZON" -eq 1 ];
then
	echo "You cannot set the -a and -r flag at the same time";
fi;

# set the defaults
for name in BACKUPDIR DB_VERSION DB_USER DB_PASSWD DB_HOST DB_PORT EXCLUDE INCLUDE;
do
	# assign it to the real name if the real name is empty
	if [ -z "${!name}" ];
	then
		# add the _ for the default name
		default="_"$name;
		eval $name=\${!default};
	fi;
done;
# check DB port is valid number
if ! [[ "$DB_PORT" =~ $PORT_REGEX ]];
then
	echo "The port needs to be a valid number: $_port";
	exit 1;
fi;

# check if we have the 'bc' command available or not
if [ -f "$BC" ];
then
	BC_OK=1;
else
	BC_OK=0;
fi;

# if DB_HOST is set, we need to add -h to the command line
# if nothing is set, DB_HOST is set to local so we know this is a "port" connection for later automatic restore
if [ -z "$DB_HOST" ];
then
	DB_HOST='local';
else
	CONN_DB_HOST='-h '$DB_HOST;
fi;

if [ "$REDHAT" -eq 1 ];
then
	# Redhat base path (for non official ones would be '/usr/pgsql-'
	PG_BASE_PATH='/usr/pgsql-';
elif [ "$AMAZON" -eq 1 ];
then
	PG_BASE_PATH='/usr/lib64/pgsql';
else
	# Debian base path
	PG_BASE_PATH='/usr/lib/postgresql/';
fi;

PG_PATH=$PG_BASE_PATH$DB_VERSION'/bin/';
PG_PSQL=$PG_PATH'psql';
PG_DUMP=$PG_PATH'pg_dump';
PG_DUMPALL=$PG_PATH'pg_dumpall';
DB_TYPE='pgsql';

# core abort if no core files found
if [ ! -f $PG_PSQL ] || [ ! -f $PG_DUMP ] || [ ! -f $PG_DUMPALL ];
then
	echo "One of the core binaries (psql, pg_dump, pg_dumpall) could not be found.";
	echo "Backup aborted";
	exit 1;
fi;

if [ ! -d $BACKUPDIR ] ; then
	if ! mkdir $BACKUPDIR ; then
		echo "Cannot create backup directory: $BACKUPDIR"
		exit 1
	fi
fi
# check if we can write into that folder
touch $BACKUPDIR/tmpfile;
if [ ! -f $BACKUPDIR/tmpfile ];
then
	echo "Cannot write to $BACKUPDIR";
	exit 1;
else
	rm -f $BACKUPDIR/tmpfile;
fi;

# if we have an ident override set, set a different DUMP VERSION here than the automatic one
if [ "$SET_IDENT" -eq 1 ];
then
	DUMP_DB_VERSION=`$PG_PATH/pg_dump --version | grep "pg_dump" | cut -d " " -f 3 | cut -d "." -f 1,2`;
else
	DUMP_DB_VERSION=$DB_VERSION;
fi;

# turn of ssl
# comment line out, if SSL connection is wanted
export PGSSLMODE=$SSLMODE;

# METHOD: convert_time
# PARAMS: timestamp in seconds or with milliseconds (nnnn.nnnn)
# RETURN: formated string with human readable time (d/h/m/s)
# CALL  : var=`convert_time $timestamp`;
# DESC  : converts a timestamp or a timestamp with float milliseconds to a human readable format
#         output is in days/hours/minutes/seconds
function convert_time
{
	timestamp=$1;
	# round to four digits for ms
	timestamp=`printf "%1.4f" $timestamp`;
	# get the ms part and remove any leading 0
	ms=`echo $timestamp | cut -d "." -f 2 | sed -e 's/^0*//'`;
	timestamp=`echo $timestamp | cut -d "." -f 1`;
	timegroups=(86400 3600 60 1); # day, hour, min, sec
	timenames=("d" "h" "m" "s"); # day, hour, min, sec
	output=( );
	time_string=;
	for timeslice in ${timegroups[@]};
	do
		# floor for the division, push to output
		if [ $BC_OK -eq 1 ];
		then
			output[${#output[*]}]=`echo "$timestamp/$timeslice" | bc`;
			timestamp=`echo "$timestamp%$timeslice" | bc`;
		else
			output[${#output[*]}]=$(awk "BEGIN {printf \"%d\", $timestamp/$timeslice}");
			timestamp=$(awk "BEGIN {printf \"%d\", $timestamp%$timeslice}");
		fi;
	done;

	for ((i=0; i<${#output[@]}; i++));
	do
		if [ ${output[$i]} -gt 0 ] || [ ! -z "$time_string" ];
		then
			if [ ! -z "$time_string" ];
			then
				time_string=$time_string" ";
			fi;
			time_string=$time_string${output[$i]}${timenames[$i]};
		fi;
	done;
	if [ ! -z $ms ];
	then
		if [ $ms -gt 0 ];
		then
			time_string=$time_string" "$ms"ms";
		fi;
	fi;
	# just in case the time is 0
	if [ -z "$time_string" ];
	then
		time_string="0s";
	fi;
	echo -n "$time_string";
}

# METHOD: convert_bytes
# PARAMS: size in bytes
# RETURN: human readable byte data in TB/GB/MB/KB/etc
# CALL  : size=`convert_bytes $bytes`;
# DESC  : converts bytes into human readable format with 2 decimals
function convert_bytes
{
	bytes=$1;
	# use awk to calc it
	echo -n `echo $bytes | awk 'function human(x) {
		 s=" B  KB MB GB TB EB PB YB ZB"
		 while (x>=1024 && length(s)>1)
			   {x/=1024; s=substr(s,4)}
		 s=substr(s,1,4)
		 xf=(s==" B  ")?"%d   ":"%.2f"
		 return sprintf( xf"%s\n", x, s)
	}
	{gsub(/^[0-9]+/, human($1)); print}'`;
}

# METHOD: get_dump_file_name
# PARAMS: none
# RETURN: dump file name (echo)
# CALL  : var=$(get_dump_file_name);
# DESC  : function for getting the correct dump file
function get_dump_file_name
{
	# set base search for the files
	sequence=*;
	if [ $db ];
	then
		db_name=$db"."$owner"."$encoding".";
	else
		db_name="pg_globals."$DB_USER".NONE.";
	fi;
	file=$BACKUPDIR$db_name$DB_TYPE"-"$DUMP_DB_VERSION"_"$DB_HOST"_"$DB_PORT"_"`date +%Y%m%d`"_"`date +%H%M`"_"$sequence".c.sql";
	# we need to find the next sequence number
	for i in `ls -1 $file 2>/dev/null`;
	do 
		# get the last sequence and cut any leading 0 so we can run +1 on it
		seq=`echo $i | cut -d "." -f 3 | cut -d "_" -f 4 | sed -e "s/^0//g"`;
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
	filename=$BACKUPDIR$db_name$DB_TYPE"-"$DUMP_DB_VERSION"_"$DB_HOST"_"$DB_PORT"_"`date +%Y%m%d`"_"`date +%H%M`"_"$sequence".c.sql";
	echo "$filename";
}

# METHOD: get_dump_databases
# PARAMS: none
# RETURN: space separated list of databases to dump
# CALLS : var=$(get_dump_databases)
# DESC  : this is needd only for clean up run if the clean up is run before the actually database dump
function get_dump_databases
{
	database_names='';
	if [ $GLOBALS -eq 1 ];
	then
		database_names="pg_globals* ";
	fi;
	for owner_db in `$PG_PSQL -U $DB_USER $CONN_DB_HOST -p $DB_PORT -d template1 -t -A -F "," -c "SELECT pg_catalog.pg_get_userbyid(datdba) AS owner, datname, pg_catalog.pg_encoding_to_char(encoding) FROM pg_catalog.pg_database WHERE datname "\!"~ 'template(0|1)';"`
	do
		db=`echo $owner_db | cut -d "," -f 2`;
		# check if we exclude this db
		exclude=0;
		include=0;
		for excl_db in $EXCLUDE;
		do
			if [ "$db" = "$excl_db" ];
			then
				exclude=1;
			fi;
		done;
		if [ ! -z "$INCLUDE" ];
		then
			for incl_db in $INCLUDE;
			do
				if [ "$db" = "$incl_db" ];
				then
					include=1;
				fi;
			done;
		else
			include=1;
		fi;
		if [ $exclude -eq 0 ] && [ $include -eq 1 ];
		then
			database_names=$database_names$db"* ";
		fi;
	done;
	echo $database_names;
}

# METHOD: clean_up
# PARAMS: none
# RETURN: none
# CALL  : $(clean_up);
# DESC  : checks for older files than given keep time and removes them
function clean_up
{
	if [ -d $BACKUPDIR ]; then
		echo "Cleanup older than $KEEP days backups in $BACKUPDIR";
		# build the find string based on the search names patter
		find_string='';
		for name in $search_names;
		do
			if [ ! -z "$find_string" ];
			then
				find_string=$find_string' -o ';
			fi;
			find_string=$find_string"-mtime +$KEEP -name "$name$DB_TYPE*.sql" -type f -delete -print";
			echo "- Remove old backups for '$name'";
		done;
		if [ $TEST -eq 0 ];
		then
			find $BACKUPDIR $find_string;
		else
			echo "find $BACKUPDIR $find_string";
		fi;
	fi
}

if [ ! -z "$DB_PASSWD" ];
then
	export PGPASSWORD=$DB_PASSWD;
fi;
START=`date "+%s"`;
echo Starting at `date "+%Y-%m-%d %H:%M:%S"`
echo "Target dump directory is $BACKUPDIR";
echo "Keep $KEEP backups";
# if flag is set, do pre run clean up
if [ $PRE_RUN_CLEAN_UP -eq 1 ];
then
	search_names=$(get_dump_databases);
	clean_up;
fi;
echo "Backing up databases:";
# reset search name list for actual dump
search_names='';
# dump globals
if [ $GLOBALS -eq 1 ];
then
	echo -e -n "+ Dumping globals...\t\t"
	filename=$(get_dump_file_name);
	search_names="pg_globals* "; # this is used for the find/delete part
	if [ $TEST -eq 0 ];
	then
		$PG_DUMPALL -U $DB_USER $CONN_DB_HOST -p $DB_PORT --globals-only > $filename;
	else
		echo "$PG_DUMPALL -U $DB_USER $CONN_DB_HOST -p $DB_PORT --globals-only > $filename";
	fi;
	echo "done."
else
	echo "- Skip dumping globals.";
fi;

echo -n "(+) Dump databases: ";
if [ -z "$INCLUDE" ];
then
	echo "All";
else
	echo $INCLUDE;
fi;
echo -n "(-) Exclude databases: ";
if [ -z "$EXCLUDE" ];
then
	echo "None";
else
	echo $EXCLUDE;
fi;

for owner_db in `$PG_PSQL -U $DB_USER $CONN_DB_HOST -p $DB_PORT -d template1 -t -A -F "," -c "SELECT pg_catalog.pg_get_userbyid(datdba) AS owner, datname, pg_catalog.pg_encoding_to_char(encoding) AS encoding FROM pg_catalog.pg_database WHERE datname "\!"~ 'template(0|1)';"`
do
	# get the user who owns the DB too
	owner=`echo $owner_db | cut -d "," -f 1`;
	db=`echo $owner_db | cut -d "," -f 2`;
	encoding=`echo $owner_db | cut -d "," -f 3`;
	# check if we exclude this db
	exclude=0;
	include=0;
	for excl_db in $EXCLUDE;
	do
		if [ "$db" = "$excl_db" ];
		then
			exclude=1;
		fi;
	done;
	if [ ! -z "$INCLUDE" ];
	then
		for incl_db in $INCLUDE;
		do
			if [ "$db" = "$incl_db" ];
			then
				include=1;
			fi;
		done;
	else
		include=1;
	fi;
	if [ $exclude -eq 0 ] && [ $include -eq 1 ];
	then
		echo -n -e "+ Dumping database '$db' ...\t\t"
		filename=$(get_dump_file_name);
		search_names=$search_names$db"* ";
		SUBSTART=`date "+%s"`;
		if [ $TEST -eq 0 ];
		then
			$PG_DUMP -U $DB_USER $CONN_DB_HOST -p $DB_PORT -c --format=c $db > $filename
		else
			echo "$PG_DUMP -U $DB_USER $CONN_DB_HOST -p $DB_PORT -c --format=c $db > $filename";
		fi;
		# get the file size for the dumped file and convert it to a human readable format
		filesize=$(wc -c "$filename" | cut -f 1 -d ' ');
		DURATION=$[ `date "+%s"`-$SUBSTART ];
		echo "done (`convert_time $DURATION` and `convert_bytes $filesize`)."
	else
		echo "- Exclude dumping database '$db'";
	fi;
done
echo Ended at `date "+%Y-%m-%d %H:%M:%S"`
if [ ! -z "$DB_PASSWD" ];
then
	unset DB_PASSWD;
fi;

if [ $PRE_RUN_CLEAN_UP -eq 0 ];
then
	clean_up;
fi;

DURATION=$[ `date "+%s"`-$START ];
echo Ended at `date "+%Y-%m-%d %H:%M:%S"`
echo "finished script in `convert_time $DURATION`";

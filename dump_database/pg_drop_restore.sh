#!/bin/bash

# Author: Clemens Schwaighofer
# Description:
# Drop and restore one database

function usage ()
{
	cat <<- EOT
	Usage: ${0##/*/} -o <DB OWNER> -d <DB NAME> -f <FILE NAME> [-h <DB HOST>] [-p <DB PORT>] [-e <ENCODING>] [-i <POSTGRES VERSION>] [-j <JOBS>] [-r|-a] [-n]

	-o <DB OWNER>: The user who will be owner of the database to be restored
	-d <DB NAME>: The database to restore the file to
	-f <FILE NAME>: the data that should be loaded
	-h <DB HOST>: optional hostname, if not given 'localhost' is used
	-p <DB PORT>: optional port number, if not given '5432' is used
	-e <ENCODING>: optional encoding name, if not given 'UTF8' is used
	-i <POSTGRES VERSION>: optional postgresql version in the format X.Y, if not given the default is used (current active)
	-j <JOBS>: Run how many jobs Parallel. If not set, 2 jobs are run parallel
	-r: use redhat base paths instead of debian
	-a: use amazon base paths instead of debian
	-n: dry run, do not do anything, just test flow
	EOT
}

_port=5432
_host='local';
_encoding='UTF8';
NO_ASK=0;
TEMPLATEDB='template0';
REDHAT=0;
AMAZON=0;
DRY_RUN=0;
BC='/usr/bin/bc';
PORT_REGEX="^[0-9]{4,5}$";
MAX_JOBS='';
# if we have options, set them and then ignore anything below
while getopts ":o:d:h:f:p:e:i:j:raqn" opt
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
		e|encoding)
			if [ -z "$encoding" ];
			then
				encoding=$OPTARG;
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
        j|jobs)
			MAX_JOBS=${OPTARG};
            ;;
		q|quiet)
			NO_ASK=1;
			;;
		r|redhat)
			REDHAT=1;
			;;
		a|amazon)
			AMAZON=1;
			;;
		n|dry-run)
			DRY_RUN=1;
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
	exit 1;
fi;
# check that the port is a valid number
if ! [[ "$_port" =~ $PORT_REGEX ]];
then
	echo "The port needs to be a valid number: $_port";
	exit 1;
fi;
NUMBER_REGEX="^[0-9]{1,}$";
# find the max allowed jobs based on the cpu count
# because setting more than this is not recommended
cpu=$(cat /proc/cpuinfo | grep processor|tail -n 1);
_max_jobs=$[ ${cpu##*: }+1 ]
# if the MAX_JOBS is not number or smaller 1 or greate _max_jobs
if [ ! -z "${MAX_JOBS}" ];
then
	# check that it is a valid number
	if ! [[ "$MAX_JOBS" =~ $NUMBER_REGEX ]];
	then
		echo "Please enter a number for the -j option";
		exit 1;
	fi;
	if [ "${MAX_JOBS}" -lt 1 ] || [ "${MAX_JOBS}" -gt ${_max_jobs} ];
	then
		echo "The value for the jobs option -j cannot be smaller than 1 or bigger than ${_max_jobs}";
		exit 1;
	fi;
else
	# auto set the MAX_JOBS based on the cpu count
	MAX_JOBS=${_max_jobs};
fi;

# check if we have the 'bc' command available or not
if [ -f "${BC}" ];
then
	BC_OK=1;
else
	BC_OK=0;
fi;

if [ ! -f "${file}" ];
then
	echo "File name needs to be provided or file could not be found";
	exit 1;
fi;

# METHOD: convert_time
# PARAMS: timestamp in seconds or with milliseconds (nnnn.nnnn)
# RETURN: formated string with human readable time (d/h/m/s)
# CALL  : var=$(convert_time $timestamp);
# DESC  : converts a timestamp or a timestamp with float milliseconds to a human readable format
#         output is in days/hours/minutes/seconds
function convert_time
{
	timestamp=${1};
	# round to four digits for ms
	timestamp=$(printf "%1.4f" $timestamp);
	# get the ms part and remove any leading 0
	ms=$(echo ${timestamp} | cut -d "." -f 2 | sed -e 's/^0*//');
	timestamp=$(echo ${timestamp} | cut -d "." -f 1);
	timegroups=(86400 3600 60 1); # day, hour, min, sec
	timenames=("d" "h" "m" "s"); # day, hour, min, sec
	output=( );
	time_string=;
	for timeslice in ${timegroups[@]};
	do
		# floor for the division, push to output
		if [ ${BC_OK} -eq 1 ];
		then
			output[${#output[*]}]=$(echo "${timestamp}/${timeslice}" | bc);
			timestamp=$(echo "${timestamp}%${timeslice}" | bc);
		else
			output[${#output[*]}]=$(awk "BEGIN {printf \"%d\", ${timestamp}/${timeslice}}");
			timestamp=$(awk "BEGIN {printf \"%d\", ${timestamp}%${timeslice}}");
		fi;
	done;

	for ((i=0; i<${#output[@]}; i++));
	do
		if [ ${output[$i]} -gt 0 ] || [ ! -z "$time_string" ];
		then
			if [ ! -z "${time_string}" ];
			then
				time_string=${time_string}" ";
			fi;
			time_string=${time_string}${output[$i]}${timenames[$i]};
		fi;
	done;
	if [ ! -z ${ms} ];
	then
		if [ ${ms} -gt 0 ];
		then
			time_string=${time_string}" "${ms}"ms";
		fi;
	fi;
	# just in case the time is 0
	if [ -z "${time_string}" ];
	then
		time_string="0s";
	fi;
	echo -n "${time_string}";
}

# for the auto find, we need to get only the filename, and therefore remove all path info
db_file=`basename $file`;
# if file is set and exist, but no owner or database are given, use the file name data to get user & database
if [ -r "$file" ] && ( [ ! "$owner" ] || [ ! "$database" ] || [ ! "$encoding" ] );
then
	# file name format is
	# <database>.<owner>.<encoding>.<db type>-<version>_<host>_<port>_<date>_<time>_<sequence>
	# we only are interested in the first two
	_database=`echo $db_file | cut -d "." -f 1`;
	_owner=`echo $db_file | cut -d "." -f 2`;
	__encoding=`echo $db_file | cut -d "." -f 3`;
	# set the others as optional
	_ident=`echo $db_file | cut -d "." -f 4 | cut -d "-" -f 2`; # db version first part
	_ident=$_ident'.'`echo $db_file | cut -d "." -f 5 | cut -d "_" -f 1`; # db version, second part (after .)
	__host=`echo $db_file | cut -d "." -f 5 | cut -d "_" -f 2`;
	__port=`echo $db_file | cut -d "." -f 5 | cut -d "_" -f 3`;
	# if any of those are not set, override by the file name settings
	if [ ! "$owner" ];
	then
		owner=$_owner;
	fi;
	if [ ! "$database" ];
	then
		database=$_database;
	fi;
	# port hast to be a valid number, at least 4 digits long and maximum 5 digits
	if [ ! "$port" ] && [[ $__port =~ $PORT_REGEX ]] ;
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
	if [ ! "$encoding" ];
	then
		if [ ! -z "$__encoding" ];
		then
			encoding=$__encoding;
		else
			encoding=$_encoding;
		fi;
	fi;
	if [ ! "$ident" ];
	then
		ident=$_ident;
	fi;
fi;

# if no user or database, exist
if [ ! "$file" ] || [ ! -f "$file" ];
then
	echo "The file has not been set or the file given could not be found.";
	exit 1;
fi;
if [ ! "$owner" ] || [ ! "$encoding" ] || [ ! "$database" ]
then
	echo "The Owner, database name and encoding could not be set automatically, the have to be given as command line options.";
	exit 1;
fi;

if [ "$REDHAT" -eq 1 ];
then
	# Debian base path
	PG_BASE_PATH='/usr/pgsql-';
elif [ "$AMAZON" -eq 1 ];
then
	PG_BASE_PATH='/usr/lib64/pgsql';
else
	# Redhat base path (for non official ones would be '/usr/pgsql-'
	PG_BASE_PATH='/usr/lib/postgresql/';
fi;

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
		ident='9.4';
		PG_PATH=$PG_BASE_PATH'9.4/bin/';
	fi;
fi;

PG_DROPDB=$PG_PATH"dropdb";
PG_CREATEDB=$PG_PATH"createdb";
PG_CREATELANG=$PG_PATH"createlang";
PG_RESTORE=$PG_PATH"pg_restore";
PG_PSQL=$PG_PATH"psql";
TEMP_FILE="temp";
LOG_FILE_EXT=$database.`date +"%Y%m%d_%H%M%S"`".log";
echo "USING POSTGRESQL: $ident";

# core abort if no core files found
if [ ! -f $PG_PSQL ] || [ ! -f $PG_DROPDB ] || [ ! -f $PG_CREATEDB ] || [ ! -f $PG_CREATELANG ] || [ ! -f $PG_RESTORE ];
then
	echo "One of the core binaries (psql, pg_dump, pg_createdb, pg_createlang, pg_restore) could not be found.";
	echo "Backup aborted";
	exit 0;
fi;

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

echo "Will drop database '$database' on host '$_host:$_port' and load file '$file' with user '$owner', set encoding '$encoding' and use database version '$ident'";
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
	# DROP DATABASE
	if [ $DRY_RUN -eq 0 ];
	then
		$PG_DROPDB -U postgres $host $port $database;
	else
		echo $PG_DROPDB -U postgres $host $port $database;
	fi;
	# CREATE DATABASE
	echo "Create DB $database with $owner and encoding $encoding [$_host:$_port] @ `date +"%F %T"`";
	if [ $DRY_RUN -eq 0 ];
	then
		$PG_CREATEDB -U postgres -O $owner -E $encoding -T $TEMPLATEDB $host $port $database;
	else
		echo $PG_CREATEDB -U postgres -O $owner -E $encoding -T $TEMPLATEDB $host $port $database;
	fi;
	# CREATE plpgsql LANG
	echo "Create plpgsql lang in DB $database [$_host:$_port] @ `date +"%F %T"`";
	if [ $DRY_RUN -eq 0 ];
	then
		$PG_CREATELANG -U postgres plpgsql $host $port $database;
	else
		echo $PG_CREATELANG -U postgres plpgsql $host $port $database;
	fi;
	# RESTORE DATA
	echo "Restore data from $file to DB $database and $MAX_JOBS [$_host:$_port] @ `date +"%F %T"`";
	if [ $DRY_RUN -eq 0 ];
	then
		$PG_RESTORE -U postgres -d $database -F c -v -c -j $MAX_JOBS $host $port $file 2>restore_errors.$LOG_FILE_EXT;
	else
		echo $PG_RESTORE -U postgres -d $database -F c -v -c -j $MAX_JOBS $host $port $file 2>restore_errors.$LOG_FILE_EXT;
	fi;
	echo "Resetting all sequences from DB $database [$_host:$_post] @ `date +"%F %T"`";
	# SEQUENCE RESET DATA COLLECTION
	if [ $DRY_RUN -eq 0 ];
	then
		echo "SELECT 'SELECT SETVAL(' ||quote_literal(S.relname)|| ', MAX(' ||quote_ident(C.attname)|| ') ) FROM ' ||quote_ident(T.relname)|| ';' FROM pg_class AS S, pg_depend AS D, pg_class AS T, pg_attribute AS C WHERE S.relkind = 'S' AND S.oid = D.objid AND D.refobjid = T.oid AND D.refobjid = C.attrelid AND D.refobjsubid = C.attnum ORDER BY S.relname;" | $PG_PSQL -U $owner -Atq $host $post -o $TEMP_FILE $database
		$PG_PSQL -U $owner $host $port -e -f $TEMP_FILE $database 1>output_sequence.$LOG_FILE_EXT 2>errors_sequence.$database.$LOG_FILE_EXT;
		rm $TEMP_FILE;
	else
		echo "SELECT 'SELECT SETVAL(' ||quote_literal(S.relname)|| ', MAX(' ||quote_ident(C.attname)|| ') ) FROM ' ||quote_ident(T.relname)|| ';' FROM pg_class AS S, pg_depend AS D, pg_class AS T, pg_attribute AS C WHERE S.relkind = 'S' AND S.oid = D.objid AND D.refobjid = T.oid AND D.refobjid = C.attrelid AND D.refobjsubid = C.attnum ORDER BY S.relname;";
		echo $PG_PSQL -U $owner $host $port -e -f $TEMP_FILE $database 1>output_sequence.$LOG_FILE_EXT 2>errors_sequence.$database.$LOG_FILE_EXT;
	fi;
	echo "Restore of data $file for DB $database [$_host:$_port] finished";
	DURATION=$[ `date +'%s'`-$START ];
	echo "Start at $start_time and end at `date +"%F %T"` and ran for $(convert_time ${DURATION}) seconds";
	echo "=== END RESTORE" >>restore_errors.$LOG_FILE_EXT;
fi;

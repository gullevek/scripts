#!/bin/bash

function usage ()
{
	cat <<- EOT
	Usage: ${0##/*/} -f <dump folder> [-j <JOBS>] [-e <ENCODING>] [-h <HOST>] [-r|-a] [-g] [-n]

	-e <ENCODING>: override global encoding, will be overruled by per file encoding
	-p <PORT>: override default port from file.
	-h <HOST>: override default host from file.
	-f: dump folder source. Where the database dump files are located. This is a must set option
	-j <JOBS>: Run how many jobs Parallel. If not set, 2 jobs are run parallel
	-r: use redhat base paths instead of debian
	-a: use amazon base paths instead of debian
	-g: do not import globals file
	-n: dry run, do not import or change anything
	EOT
}

_port=5432
_host='local';
_encoding='UTF8';
REDHAT=0;
AMAZON=0;
IMPORT_GLOBALS=1;
TEMPLATEDB='template0'; # truly empty for restore
DUMP_FOLDER='';
MAX_JOBS='';
BC='/usr/bin/bc';
PORT_REGEX="^[0-9]{4,5}$";
DRY_RUN=0;
# options check
while getopts ":f:j:h:p:e:gran" opt
do
	case $opt in
		f|file)
			DUMP_FOLDER=$OPTARG;
			;;
        j|jobs)
			MAX_JOBS=${OPTARG};
            ;;
		e|encoding)
			if [ -z "$encoding" ];
			then
				encoding=$OPTARG;
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
		g|globals)
			IMPORT_GLOBALS=0;
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
fi;

if [ "$REDHAT" -eq 1 ];
then
	# Redhat base path (for non official ones would be '/usr/pgsql-'
	DBPATH_BASE='/usr/pgsql-'
elif [ "$AMAZON" -eq 1 ];
then
	# Amazon paths (lib64 default amazon package)
	DBPATH_BASE='/usr/lib64/pgsql';
else
	# Debian base path
	DBPATH_BASE='/usr/lib/postgresql/';
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
	if [[ ! "$MAX_JOBS" =~ "$NUMBER_REGEX" ]];
	then
		echo "Please enter a number for the -j option";
		exit 1;
	fi;
	if [ "${MAX_JOBS}" -lt 1 ] || [ "${MAX_JOBS}" -gt 1 ];
	then
		echo "The value for the jobs option -j cannot be smaller than 1 or bigger than ${_max_jobs}";
		exit 1;
	fi;
else
	# auto set the MAX_JOBS based on the cpu count
	MAX_JOBS=${_max_jobs};
fi;

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

LOGS=$DUMP_FOLDER'/logs/';
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

# check if we have the 'bc' command available or not
if [ -f "${BC}" ];
then
	BC_OK=1;
else
	BC_OK=0;
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
EXCLUDE_LIST="pg_globals"; # space separated
LOGFILE="tee -a $LOGS/PG_RESTORE_DB_FILE.`date +"%Y%m%d_%H%M%S"`.log";

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
	version=`echo $filename | cut -d "." -f 4 | cut -d "-" -f 2`; # db version, without prefix of DB type
	version=$version'.'`echo $filename | cut -d "." -f 5 | cut -d "_" -f 1`; # db version, second part (after .)
	__host=`echo $filename | cut -d "." -f 5 | cut -d "_" -f 2`; # hostname of original DB, can be used as target host too
	__port=`echo $filename | cut -d "." -f 5 | cut -d "_" -f 3`; # port of original DB, can be used as target port too
	# override file port over given port if it differs and is valid
	if [ -z $_port ] && [ "$__port" != $_port ] && [[ $__port =~ $PORT_REGEX ]] ;
	then
		_port=$__port;
		port='-p '$_port;
	fi;
	if [ -z "$_host" ] && [ "$__host" != "local" ];
	then
		_host=$__host;
		host='-h '$_host;
	fi;
	# create the path to the DB from the DB version in the backup file
	if [ ! -z "$version" ];
	then
		DBPATH_VERSION_LOCAL=$version'/';
	else
		DBPATH_VERSION_LOCAL=$DBPATH_VERSION;
	fi;
	DBPATH=$DBPATH_BASE$DBPATH_VERSION_LOCAL$DBPATH_BIN;
	echo "+ Restore globals file: $filename to [$_host:$_port] @ `date +"%F %T"`" | $LOGFILE;
	if [ ${DRY_RUN} -eq 0 ];
	then
		$DBPATH$PSQL -U postgres $host $port -f $file -e -q -X template1 | $LOGFILE;
	else
		echo "$DBPATH$PSQL -U postgres $host $port -f $file -e -q -X template1" | $LOGFILE;
	fi;
	DURATION=$[ `date +'%s'`-$START ];
	printf "=[Globals Restore]=END===[%s seconds]========================================================>\n" $(convert_time ${DURATION}) | $LOGFILE;
fi;
for file in $DUMP_FOLDER/*.sql;
do
	start_time=`date +"%F %T"`;
	START=`date +'%s'`;
	echo "=[$pos/$db_count]=START=[$start_time]==================================================>" | $LOGFILE;
	# get the filename
	filename=`basename $file`;
	# get the databse, user
	# default file name is <database>.<owner>.<encoding>.<type>-<version>_<host>_<port>_<date>_<time>_<sequence>
	database=`echo $filename | cut -d "." -f 1`;
	owner=`echo $filename | cut -d "." -f 2`;
	__encoding=`echo $filename | cut -d "." -f 3`;
	version=`echo $filename | cut -d "." -f 4 | cut -d "-" -f 2`; # db version, without prefix of DB type
	version=$version'.'`echo $filename | cut -d "." -f 5 | cut -d "_" -f 1`; # db version, second part (after .)
	__host=`echo $filename | cut -d "." -f 5 | cut -d "_" -f 2`; # hostname of original DB, can be used as target host too
	__port=`echo $filename | cut -d "." -f 5 | cut -d "_" -f 3`; # port of original DB, can be used as target port too
	other=`echo $filename | cut -d "." -f 5 | cut -d "_" -f 2-`; # backup date and time, plus sequence
	# override file port over given port if it differs and is valid
	if [ -z $_port ] && [ "$__port" != $_port ] && [[ $__port =~ $PORT_REGEX ]] ;
	then
		_port=$__port;
		port='-p '$_port;
	fi;
	if [ -z "$_host" ] && [ "$__host" != "local" ];
	then
		_host=$__host;
		host='-h '$_host;
	fi;
	# overrid encoding (dangerous)
	if [ ! "$encoding" ];
	then
		if [ ! -z "$__encoding" ];
		then
			encoding=$__encoding;
		else
			encoding=$_encoding;
		fi;
	fi;
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
			if [ ${DRY_RUN} -eq 0 ];
			then
				$CREATEUSER -U postgres -D -R -S $host $port $owner;
			else
				echo "$CREATEUSER -U postgres -D -R -S $host $port $owner";
			fi;
		fi;
		# before importing the data, drop this database
		echo "- Drop DB '$database' [$_host:$_port] @ `date +"%F %T"`" | $LOGFILE;
		if [ ${DRY_RUN} -eq 0 ];
		then
			$DBPATH$DROPDB -U postgres $host $port $database;
		else
			echo "$DBPATH$DROPDB -U postgres $host $port $database";
		fi;
		echo "+ Create DB '$database' with '$owner' [$_host:$_port] @ `date +"%F %T"`" | $LOGFILE;
		if [ ${DRY_RUN} -eq 0 ];
		then
			$DBPATH$CREATEDB -U postgres -O $owner -E $encoding -T $TEMPLATEDB $host $port $database;
		else
			echo "$DBPATH$CREATEDB -U postgres -O $owner -E $encoding -T $TEMPLATEDB $host $port $database";
		fi;
		echo "+ Create plpgsql lang in DB '$database' [$_host:$_port] @ `date +"%F %T"`" | $LOGFILE;
		if [ ${DRY_RUN} -eq 0 ];
		then
			$DBPATH$CREATELANG -U postgres plpgsql $host $port $database;
		else
			echo "$DBPATH$CREATELANG -U postgres plpgsql $host $port $database";
		fi;
		echo "% Restore data from '$filename' to DB '$database' [$_host:$_port] @ `date +"%F %T"`" | $LOGFILE;
		if [ ${DRY_RUN} -eq 0 ];
		then
			$DBPATH$PGRESTORE -U postgres -d $database -F c -v -c -j $MAX_JOBS $host $port $file 2>$LOGS'/errors.'$database'.'$(date +"%Y%m%d_%H%M%S".log);
		else
			echo "$DBPATH$PGRESTORE -U postgres -d $database -F c -v -c -j $MAX_JOBS $host $port $file 2>$LOGS'/errors.'$database'.'$(date +"%Y%m%d_%H%M%S".log)";
		fi;
		echo "$ Restore of data '$filename' for DB '$database' [$_host:$_port] finished" | $LOGFILE;
		DURATION=$[ `date +'%s'`-$START ];
		echo "* Start at $start_time and end at `date +"%F %T"` and ran for $(convert_time ${DURATION}) seconds" | $LOGFILE;
	else
		DURATION=0;
		echo "# Skipped DB '$database'" | $LOGFILE;
	fi;
	printf "=[$pos/$db_count]=END===[%s seconds]========================================================>\n" $(convert_time ${DURATION}) | $LOGFILE;
	pos=$[ $pos+1 ];
done;
DURATION=$[ `date +'%s'`-$MASTERSTART ];
echo "" | $LOGFILE;
echo "= Start at $master_start_time and end at `date +"%F %T"` and ran for $(convert_time ${DURATION}) seconds. Imported $db_count databases." | $LOGFILE;

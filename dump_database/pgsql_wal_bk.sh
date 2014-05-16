#!/bin/bash

function usage ()
{
	cat <<- EOT
	Usage: ${0##/*/} -s <source %p> -t <target %f> [-i <postgresql version>] [-c]

	in postgresql.conf call as
	archive_command = '/usr/local/scripts/dump_db/pgsql_wal_bk.sh -s "%p" -t "%f"'

	-s <%p>     : from postgresql [full path + wal file name]
	-t <%f>     : from postgresql [wal file name only]
	-i <version>: optional postgresql version, eg 9.3, if not given default is currently 9.3
	-c          : if set, data will be compressed after it is copied
	EOT
}

compress=0;

while getopts ":s:t:i:ch" opt
do
	case $opt in
		s|source)
			if [ -z "$source_p" ];
			then
				source_p=$OPTARG;
			fi;
			;;
		t|target)
			if [ -z "$target_f" ];
			then
				target_f=$OPTARG;
			fi;
			;;
		i|ident)
			if [ -z "$ident" ];
			then
				ident=$OPTARG;
			fi;
			;;
		c|compress)
			compress=1;
			;;
		h|help)
			usage;
			;;
		\?)
			echo -e "\n Option does not exist: $OPTARG\n";
			usage;
			exit 1;
			;;
	esac;
done;

if [ ! $source_p ] || [ ! $target_f ];
then
	echo "Source and target WAL files missing";
	exit 1;
fi;

VERSION="";
if [ "$ident" ];
then
	# check if that folder actually exists
	# do auto detect else
	if [ -d "/var/lib/postgresql/$ident/" ];
	then
		VERSION="$ident";
	fi;
fi;
# if no version set yet, try auto detect, else set to 9.3 hard
if [ -z "$VERSION" ];
then
	# try to run psql from default path and get the version number
	ident=`pg_dump --version | grep "pg_dump" | cut -d " " -f 3 | cut -d "." -f 1,2`;
	if [ ! -z "$ident" ];
	then
		VERSION="$ident";
	else
		# hard set
		VERSION="9.3";
	fi;
fi;

# Modify this according to your setup
PGSQL=/var/lib/postgresql/$VERSION/;
# folder needs to be owned or 100% writable by the postgres user
DEST=/var/local/backup/postgres/$VERSION/wal/;
# create folder if it does not exist
if [ ! -d "$DEST" ];
then
	mkdir -p "$DEST";
fi;
DATE=`date +"%F %T"`
if [ -e $PGSQL"backup_in_progress" ]; then
	echo "$DATE - backup_in_progress" >> $DEST/wal-copy-log.txt 
	exit 1
fi
if [ -e $DEST/$target_f ] || [ -e $DEST/$target_f".bz2" ]; then 
	echo "$DATE - old file '$target_f' still there" >> $DEST/wal-copy-log.txt 
	exit 1
fi
if [ ! -f $source_p ]; then
	echo "$DATE - source file '$source_p' cannot be found" >> $DEST/wal-copy-log.txt 
	exit 1
fi;
echo "$DATE - /bin/cp $source_p $DEST/$target_f" >> $DEST/wal-copy-log.txt
/bin/cp $source_p $DEST/$target_f
# compress all data as bzip2
if [ $compress ];
then
	DATE=`date +"%F %T"`
	echo "$DATE - /bin/bzip2 $DEST/$target_f &" >> $DEST/wal-copy-log.txt
	/bin/bzip2 $DEST/$target_f &
fi;

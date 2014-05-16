#!/bin/bash

BK_PATH='/backup/db_dumps_mysql/';
MYSQL_DUMP_BIN='/usr/bin/mysqldump';
DB_TYPE='mysql-5.1';
CONFIG='/root/.my.cnf';
KEEP=2; # KEEP how many days
# those dbs have to be dropped with skip locks (single transaction)
NOLOCKDB="information_schema performance_schema"
NOLOCKS="--single-transaction"
# those tables need to be dropped with EVENTS
EVENTDB="mysql"
EVENTS="--events"
# exclude
EXCLUDE=''; # space separated list of database names

if [ ! -d $BK_PATH ];
then
	echo "Creating $BK_PATH";
	if ! mkdir -p $BK_PATH;
	then
		echo "failed creating $BK_PATH";
		exit 1;
	fi;
fi;

if [ -d $BK_PATH ];
then
	echo Starting at `date "+%Y-%m-%d %H:%M:%S"`
	echo "Backup All MySQL DBs ...";
	/usr/bin/mysql --defaults-extra-file=$CONFIG -B -N -e "show databases" | while read db
	do
		# check if we exclude this db
		exclude=0;
		for excl_db in $EXCLUDE;
		do
			if [ "$db" = "$excl_db" ];
			then
				exclude=1;
			fi;
		done;
		if [ $exclude -eq 0 ];
		then
			filename=$BK_PATH"db_"$DB_TYPE"_"$db"_bk_"`date +%Y%m%d`"_"`date +%H%M`"_01.sql";
			echo "+ Backing up $db into $filename"
			# lock check
			nolock='';
			for nolock_db in $NOLOCKDB;
			do
					if [ "$nolock_db" = "$db" ];
					then
							nolock=$NOLOCKS;
					fi;
			done;
			# event check
			event='';
			for event_db in $EVENTDB;
			do
					if [ "$event_db" = "$db" ];
					then
							event=$EVENTS;
					fi;
			done;
			$MYSQL_DUMP_BIN --defaults-extra-file=$CONFIG $nolock $event --opt $db >$filename;
			# bzip2 them
			bzip2 $filename;
		else
			echo "+ Exclude backup of $db";
		fi;
	done;
	echo Ended at `date "+%Y-%m-%d %H:%M:%S"`
	echo "finished";
	echo "Cleanup older than $KEEP days backups in $BK_PATH";
	find $BK_PATH -mtime +$KEEP -name "*_${DB_TYPE}_*_bk_*.sql*" -delete -print;
else
	echo "Backup path $BK_PATH not found";
fi

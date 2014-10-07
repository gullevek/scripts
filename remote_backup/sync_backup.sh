#!/bin/bash

# syncs to folders + writes log
# used for local backup to qnas sync

function usage ()
{
	cat <<- EOT
	Usage: ${0##/*/} [-v] [-x] [-s <source folder>] [-t <target folder>]

	-v: verbose output, if used outside scripted runs
	-x: add -X rsync flag for extended attributes. Can oops certain kernels.
	-l: log file name, if not set default name is used
	-s: source folder, must exist
	-t: target folder, must exist
	EOT
}

# if no verbose flag is set run, no output
VERBOSE='--partial';
EXT_ATTRS='';
LOG_FILE="/var/log/rsync/rsync_backup.log";
_LOG_FILE='';
CHECK=1;

# set options
while getopts ":vcxs:t:l:h" opt
do
    case $opt in
        v|verbose)
			# verbose flag shows output
            VERBOSE='-P';
            ;;
        x|extattr)
            EXT_ATTRS='-X';
            ;;
		c|check)
			CHECK=0;
			;;
        s|source)
            if [ -z "$SOURCE" ];
			then
				SOURCE="$OPTARG";
			fi;
            ;;
        t|target)
            if [ -z "$TARGET" ];
			then
				TARGET="$OPTARG";
			fi;
            ;;
        l|logfile)
            if [ -z "$_LOG_FILE" ];
			then
				_LOG_FILE=$OPTARG;
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

# use new log file path, if the folder is ok and writeable
if [ ! -z "$_LOG_FILE" ];
then
	# check if this is valid writeable file
	touch "$_LOG_FILE";
	if [ -f "$_LOG_FILE" ];
	then
		LOG_FILE=$_LOG_FILE;
	else
		echo "Log file '$_LOG_FILE' is not writeable, fallback to '$LOG_FILE'";
	fi;
fi;

echo "S: $SOURCE | T: $TARGET";
if [ $CHECK -eq 1 ];
then
	if [[ ! -d "$SOURCE" || ! -d "$TARGET" ]];
	then
		echo "Give source and target path.";
		if [ ! -z "$SOURCE" ] && [ ! -d "$SOURCE" ];
		then
			echo "Source folder not found: $SOURCE";
		fi;
		if [ ! -z "$TARGET" ] && [ ! -d "$TARGET" ];
		then
			echo "Target folder not found: $TARGET";
		fi;
		exit;
	fi;
else
	if [[ -z "$SOURCE" || -z "$TARGET" ]];
	then
		echo "Give source and target path.";
		exit;
	fi;
fi;

# run lock file, based on source target folder names (/ transformed to _)
RUN_FOLDER='/var/run/';
run_file=$RUN_FOLDER"rsync-script_"`echo "$SOURCE" | sed -e 's/[\/@\*:]/_/g'`'_'`echo "$TARGET" | sed -e 's/[\/@\*:]/_/g'`'.run';
exists=0;
if [ -f "$run_file" ];
then
	# check if the pid in the run file exists, if yes, abort
	pid=`cat "$run_file"`;
	while read _ps;
	do
		if [ $_ps -eq $pid ];
		then
			exists=1;
			echo "Rsync script already running with pid $pid";
			break;
		fi;
	done < <(ps xu|sed 1d|awk '{print $2}');
	# not exited, so not running, clean up pid
	if [ $exists -eq 0 ];
	then
		rm -f "$run_file";
	else
		exit 0;
	fi;
fi;
echo $$ > "$run_file";

# a: archive
# z: compress
# X: extended attributes
# A: ACL
# v: verbose
# hh: human readable in K/M/G/...

# remove -X for nfs sync, it screws up and oops (kernel 3.14-2)
basic_params='-azAvi --stats --delete --exclude "lost+found" -hh';

echo "Sync '$SOURCE' to '$TARGET' ...";
rsync $basic_params $VERBOSE $XT_ATTRS --log-file=$LOG_FILE --log-file-format="%o %i %f%L %l (%b)" $SOURCE $TARGET;
echo "done";

rm -f "$run_file";

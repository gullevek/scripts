#!/bin/bash

# mount this servers attic backup to a folder
# if no command is given the target folder is /mnt/restore
# if this folder does not exist, script will exit with an error

function usage ()
{
	cat <<- EOT
	Usage: ${0##/*/} [-m <mount path>] [-f <attic backup file>]

	-m <mount path>: where to mount the image
	-f <attic backup file>: override full path to backup file instead of using the settings info
	EOT
}

# base folder
BASE_FOLDER="/usr/local/scripts/backup/";
# attic settings file 
SETTINGS_FILE="attic.backup.settings";
# base mount path (default)
MOUNT_PATH="/mnt/restore/";

# set options
while getopts ":m:f:" opt
do
	case $opt in
		m|mount)
			MOUNT_PATH=$OPTARG;
			;;
		f|file)
			ATTIC_BACKUP_FILE=$OPTARG;
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

if [ ! -d "$MOUNT_PATH" ];
then
	echo "The mount path $MOUNT_PATH cannot be found";
	exit 1;
fi;

if [ -z "$ATTIC_BACKUP_FILE" ];
then
	. "$BASE_FOLDER$SETTINGS_FILE"
	# set the attic backup file base on the settings data
	# if we have user/host then we build the ssh command
	if [ ! -z "$TARGET_USER" ] && [ ! -z "$TARGET_HOST" ];
	then
		TARGET_SERVER=$TARGET_USER"@"$TARGET_HOST":";
	fi;
	REPOSITORY=$TARGET_SERVER$TARGET_FOLDER$BACKUP_FILE;
fi;

# check that the repostiory exists
REPOSITORY_OK=0;
if [ ! -z "$TARGET_SERVER" ];
then
	# remove trailing : for this
	TARGET_SERVER=`echo "$TARGET_SERVER" | sed -e 's/://g'`;
	# use ssh command to check remote existense
	if [ `ssh "$TARGET_SERVER" "if [ -d \"$TARGET_FOLDER$BACKUP_FILE\" ]; then echo 1; else echo 0; fi;"` -eq 1 ];
	then
		REPOSITORY_OK=1;
	fi;
elif [ -d "$REPOSITORY" ];
then
	REPOSITORY_OK=1;
fi;

if [ $REPOSITORY_OK -eq 0 ];
then
	echo "Repository $REPOSITORY does not exists";
	exit 1;
fi;

echo "Mounting $REPOSITORY on $MOUNT_PATH";
# all ok, lets mount it
attic mount $REPOSITORY $MOUNT_PATH;

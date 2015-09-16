#!/bin/bash

# base folder
BASE_FOLDER="/usr/local/scripts/backup/";
# include and exclude file
INCLUDE_FILE="attic.backup.include";
EXCLUDE_FILE="attic.backup.exclude";
SETTINGS_FILE="attic.backup.settings";

if [ ! -f "$BASE_FOLDER$SETTINGS_FILE" ];
then
	echo "No settings file could be found";
	exit 0;
fi;

. "$BASE_FOLDER$SETTINGS_FILE";

if [ "$VERBOSE" -eq 1 ];
then
	OPT_VERBOSE="-v";
else
	OPT_VERBOSE='';
fi;

# if we have user/host then we build the ssh command
if [ ! -z "$TARGET_USER" ] && [ ! -z "$TARGET_HOST" ];
then
	TARGET_SERVER=$TARGET_USER"@"$TARGET_HOST":";
fi;
REPOSITORY=$TARGET_SERVER$TARGET_FOLDER$BACKUP_FILE;

if [ ! -f "$BASE_FOLDER$INCLUDE_FILE" ];
then
	echo "The include folder file $INCLUDE_FILE is missing";
	exit 0;
fi;

# if the repository is no there, call init to create it
# if this is user@host, we need to use ssh command to check if the file is there
# else a normal check is ok
INIT_REPOSITORY=0;
if [ ! -z "$TARGET_SERVER" ];
then
	# remove trailing : for this
	TARGET_SERVER=`echo "$TARGET_SERVER" | sed -e 's/://g'`;
	# use ssh command to check remote existense
	if [ `ssh "$TARGET_SERVER" "if [ -d \"$TARGET_FOLDER$BACKUP_FILE\" ]; then echo 1; else echo 0; fi;"` -eq 0 ];
	then
		INIT_REPOSITORY=1;
	fi;
elif [ ! -d "$REPOSITORY" ];
then
	INIT_REPOSITORY=1;
fi;
if [ $INIT_REPOSITORY -eq 1 ];
then
	attic init $REPOSITORY;
fi;

# base command
COMMAND="attic create $OPT_VERBOSE -s $REPOSITORY::$DATE";
# include list
while read include_folder;
do
	COMMAND=$COMMAND" $include_folder";
done<"$BASE_FOLDER$INCLUDE_FILE";
# exclude list
if [ -f "$BASE_FOLDER$EXCLUDE_FILE" ];
then
	COMMAND=$COMMAND" --exclude-from $BASE_FOLDER$EXCLUDE_FILE";
fi;

# execute backup command
if [ "$DEBUG" -eq 1 ];
then
	echo $COMMAND;
	PRUNE_DEBUG="--dry-run";
else
	$COMMAND;
fi;

# clean up, always verbose
attic prune -v $PRUNE_DEBUG $REPOSITORY --keep-daily=$KEEP_DAYS --keep-weekly=$KEEP_WEEKS --keep-monthly=$KEEP_MONTHS

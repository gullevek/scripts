#!/bin/bash

# AUTHOR: Clemens Schwaighofer
# DATE: 2015/8/4
# DESC: inits a screen with shells (sets titles) and runs command in those shells
#       reads all data from a config file
#
# open the screen config file
# - first line is the screen name
# - second line on are the screens + commands
# - a line is title#command
# - command can be empty, just creates a screen then
# - title can be empty, but not recommended
# - no hash is allowed in title or command

# EXAMPLE:
# ===========================
# FooScreen
# TitleA#cd ~/Folder
# TitleB#vim file
# TitleC#
# TitleD#ping foo.bar.com
# ===========================

set -e

ERROR=0;
if [ ! -f "$1" ];
then
	echo "Cannot find screen init config file '$1'";
	ERROR=1;
else
	# get the first line for the screen name
	SCREEN_NAME=`head -n 1 "$1"`;
fi;

# check if we are in a screen one, if yes, exit
if [ -z "$STY" ];
then
	# check if the "work" screen exists
	if [ ! -z "$SCREEN_NAME" ] && [[ ! -z `screen -ls | grep ".$SCREEN_NAME\t"` ]];
	then
		echo "Screen '$SCREEN_NAME' already exists";
		ERROR=1;
	fi;
else
	echo "Cannot run screen init script in a screen";
	ERROR=1;
fi;

if [ $ERROR -eq 1 ];
then
	exit;
fi;

# read the config file and init the screen
pos=0;
cat "$1" |
while read line;
do
	if [ $pos -eq 0 ];
	then
		# should I clean the title to alphanumeric? (well yes, but not now)
		SCREEN_NAME=$line;
	else
		# extract screen title and command (should also be cleaned for title)
		SCREEN_TITLE=`echo $line | cut -d "#" -f 1`;
		SCREEN_CMD=`echo $line | cut -d "#" -f 2`;
		# screen number is pos - 1
		SCREEN_POS=$[ $pos-1 ];
		# for the first screen, we need to init the screen and only set title
		# for the rest we set a new screen with title
		if [ $pos -eq 1 ];
		then
			echo "Init screen with title '$SCREEN_NAME'";
			screen -dmS "$SCREEN_NAME";
			# set title for the first
			screen -r "$SCREEN_NAME" -p $SCREEN_POS -X title "$SCREEN_TITLE";
		else
			screen -r "$SCREEN_NAME" -X screen -t "$SCREEN_TITLE" $SCREEN_POS;
		fi;
		echo "[$SCREEN_POS] Set title to '$SCREEN_TITLE'";
		# run command on it (if there is one)
		if [ ! -z "$SCREEN_CMD" ];
		then
			echo "[$SCREEN_POS] Run command '$SCREEN_CMD'";
			# if ^M is garbled: in vim do: i, ^V, ENTER, ESCAPE
			screen -r "$SCREEN_NAME" -p $SCREEN_POS -X stuff $"$SCREEN_CMD ";
		fi;
	fi;
	pos=$[ $pos+1 ];
done;

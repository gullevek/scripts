#!/usr/bin/env bash

set -e -u -o pipefail

# mount this servers borg backup to a folder
# if no command is given the target folder is /mnt/restore
# if this folder does not exist, script will exit with an error

# base folder
BASE_FOLDER="/usr/local/scripts/backup/";
# borg settings file
SETTINGS_FILE="borg.backup.settings";
# base mount path (default)
MOUNT_PATH="/mnt/restore/";
# backup path to borg storage
ATTIC_BACKUP_FILE='';
# if we are mount or unmount (default is mount)
UMOUNT=0;

function usage ()
{
	cat <<- EOT
	Usage: ${0##/*/} [-c <config folder>] [-m <mount path>] [-f <borg backup file>] [-u <mount path]

	-c <config folder>: if this is not given, ${BASE_FOLDER} is used
	-m <mount path>: where to mount the image
	-u umount mounted image
	-f <borg backup file>: override full path to backup file instead of using the settings info
	EOT
}

# set options
while getopts ":c:m:uf:h" opt
do
	case "${opt}" in
		c|config)
			BASE_FOLDER=${OPTARG};
			;;
		m|mount)
			MOUNT_PATH=${OPTARG};
			;;
		u|umount)
			UMOUNT=1;
			;;
		f|file)
			ATTIC_BACKUP_FILE=${OPTARG};
			;;
		h|help)
			usage;
			exit 0;
			;;
		:)
			echo "Option -$OPTARG requires an argument."
			;;
		\?)
			echo -e "\n Option does not exist: ${OPTARG}\n";
			usage;
			exit 1;
			;;
	esac;
done;

if [ ! -d "${MOUNT_PATH}" ];
then
	echo "The mount path ${MOUNT_PATH} cannot be found";
	exit 0;
fi;

if [ ${UMOUNT} -eq 0 ];
then
	TARGET_SERVER='';
	if [ -z "${ATTIC_BACKUP_FILE}" ];
	then
		if [ ! -f "${BASE_FOLDER}${SETTINGS_FILE}" ];
		then
			echo "Cannot find ${BASE_FOLDER}${SETTINGS_FILE}";
			exit 0;
		fi;
		. ${BASE_FOLDER}${SETTINGS_FILE}
		# set the borg backup file base on the settings data
		# if we have user/host then we build the ssh command
		if [ ! -z "${TARGET_USER}" ] && [ ! -z "${TARGET_HOST}" ];
		then
			TARGET_SERVER=${TARGET_USER}"@"${TARGET_HOST}":";
		fi;
		REPOSITORY=${TARGET_SERVER}${TARGET_FOLDER}${BACKUP_FILE};
	else
		REPOSITORY=${ATTIC_BACKUP_FILE};
	fi;

	# check that the repostiory exists
	REPOSITORY_OK=0;
	if [ ! -z "${TARGET_SERVER}" ];
	then
		# remove trailing : for this
		TARGET_SERVER=${TARGET_SERVER/:};
		# use ssh command to check remote existense
		if [ `ssh "${TARGET_SERVER}" "if [ -d \"${TARGET_FOLDER}${BACKUP_FILE}\" ]; then echo 1; else echo 0; fi;"` -eq 1 ];
		then
			REPOSITORY_OK=1;
		fi;
	elif [ -d "${REPOSITORY}" ];
	then
		REPOSITORY_OK=1;
	fi;

	if [ ${REPOSITORY_OK} -eq 0 ];
	then
		echo "Repository ${REPOSITORY} does not exists";
		exit 0;
	fi;

	echo "Mounting ${REPOSITORY} on ${MOUNT_PATH}";
	# all ok, lets mount it
	borg mount "${REPOSITORY}" "${MOUNT_PATH}";
else
	echo "Unmounting ${MOUNT_PATH}";
	# will fail with error if not mounted, but not critical
	borg umount "${MOUNT_PATH}";
fi;

## END

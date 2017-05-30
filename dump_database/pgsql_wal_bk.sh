#!/bin/bash

set -e -u -o pipefail

function usage ()
{
	cat <<- EOT
	Usage: ${0##/*/} -s <source %p> -t <target %f> [-m <remote folder>] [-i <postgresql version>] [-c] [-x <compress type]

	in postgresql.conf call as
	archive_command = '/usr/local/scripts/dump_db/pgsql_wal_bk.sh -s "%p" -t "%f"'

	-s <%p>     : from postgresql [full path + wal file name]
	-t <%f>     : from postgresql [wal file name only]
	-r          : use redhat folders, default are debian folders
	-m <folder> : can be used to move the data after the copy to a another folder (eg network folder)
	-i <version>: optional postgresql version, eg 9.4, if not given default is currently 9.4
	-c          : if set, data will be compressed after it is copied
	-x <type>   : compression type. Valid are gzip, bzip2, lbzip2, xz, lzma,  lzop.
	              If -c is set, and -x is not or -x software cannot be found, lzop is assumed.
				  If nothing found, no compression is done.

				  Type   | Speed  | CPU  | Memory | Compression
				  -------+--------+------+--------+------------
				  lzop   | fast   | low  | low    | low
				  gzip   | medium | low  | low    | medium
				  pigz   | medium | low  | low    | high
				  bzip2  | low    | high | medium | high
				  lbzip2 | medium | high | high   | high
				  lzma   | low    | high | high   | high
				  xz     | low    | high | high   | high
				  pxz    | medium | high | high   | high

				  Recommended: lzop
	EOT
}

# postgrsql WAL parts
source_p='';
target_f='';
# possible remote folder
move='';
# compress software chceck
vcs_valid=0;
vcs_exists=0;
# the compress software command
compress_cmd='';
# compress on/off flag
compress=0;
# command line compression software name
compress_software='';
# the default compression software
default_compress_software='lzop';
# valid list of compression software
valid_compress_software=(gzip pigz bzip2 lbzip2 xz pxz lzma lzop);
# postgresql version override
ident='';
# base folder
BASE_FOLDER='postgres';
# general error check var
error=0;

while getopts ":s:t:m:i:x:ch" opt
do
	case ${opt} in
		s|source)
			if [ -z "${source_p}" ];
			then
				source_p=${OPTARG};
			fi;
			;;
		t|target)
			if [ -z "${target_f}" ];
			then
				target_f=${OPTARG};
			fi;
			;;
		r|redhat)
			BASE_FOLDER='pgsql';
			;;
		m|move)
			if [ -z "${move}" ];
			then
				move=${OPTARG};
			fi;
			;;
		i|ident)
			if [ -z "${ident}" ];
			then
				ident=${OPTARG};
			fi;
			;;
		x|compress-software)
			if [ -z "${compress_software}" ];
			then
				compress_software=${OPTARG};
			fi;
			;;
		c|compress)
			compress=1;
			;;
		h|help)
			usage;
			;;
		\?)
			echo -e "\n Option does not exist: ${OPTARG}\n";
			usage;
			exit 1;
			;;
	esac;
done;

if [ -z ${source_p} ] || [ -z ${target_f} ];
then
	echo "Source and target WAL files missing";
	error=1;
fi;

if [ ! -z "${move}" ];
then
	if [ ! -d "${move}" ];
	then
		echo "The target move folder is not accessable";
		error=1;
	else
		touch "${move}"/tmpfile || echo "[!] touch failed";
		if [ ! -f "${move}"/tmpfile ];
		then
			echo "Cannot write to ${move}";
			error=1;
		else
		    rm -f "${move}"/tmpfile;
		fi;
	fi;
fi;

# -x is given, but no -c
if [ ! -z "${compress_software}" ] && [ "${compress}" -eq 0 ];
then
	echo "If you set the compress software option, the compress option needs also to be set";
	error=1;
fi;

# if no compression software is select, set the default one
if [ -z "${compress_software}" ]
then
	compress_software=${default_compress_software};
fi;
# check that the compression type is in the valid list and that this binary exists
if [ "${compress}" -eq 1 ];
then
	vcs_valid=0;
	vcs_exists=0;
	for vcs in ${valid_compress_software[@]};
	do
		if [ "${compress_software}" = "${vcs}" ];
		then
			vcs_valid=1;
			# check that this software is actually installed
			# in $PATH list
			for path in ${PATH//:/ };
			do
				if [ -f "${path}/${vcs}" ];
				then
					vcs_exists=1;
					compress_cmd="${path}/${vcs}";
					# lzop needs -U for removal of old file after compression
					if [ "${compress_software}" = 'lzop' ];
					then
						compress_cmd=${compress_cmd}' -U';
					fi;
				fi;
			done;
		fi;
	done;
	if [ "${vcs_valid}" -eq 0 ];
	then
		echo "The given compression software ${compress_software} is not in the valid list ${valid_compress_software[*]}";
		error=1;
	fi;
	# if we cannot find any binary, disable compression
	if [ "${vcs_exists}" -eq 0 ];
	then
		echo "The selected compression software ${compress_software} seems not to be installed in any ${PATH} folder";
		echo "[!] Compression is turned off";
		compress=0;
	fi;
fi;

if [ "${error}" -eq 1 ];
then
	exit 1;
fi;

VERSION="";
if [ ! -z "${ident}" ];
then
	# check if that folder actually exists
	# do auto detect else
	# only works with debian style paths
	if [ -d "/var/lib/${BASE_FOLDER}/${ident}/" ];
	then
		VERSION="${ident}";
	fi;
fi;
# if no version set yet, try auto detect, else set to 9.4 hard
if [ -z "${VERSION}" ];
then
	# try to run psql from default path and get the version number
	ident=`pg_dump --version | grep "pg_dump" | cut -d " " -f 3 | cut -d "." -f 1,2`;
	if [ ! -z "${ident}" ];
	then
		VERSION="${ident}";
	else
		# hard set
		VERSION="9.4";
	fi;
fi;

# Modify this according to your setup
PGSQL="/var/lib/${BASE_FOLDER}/${VERSION}/";
# folder needs to be owned or 100% writable by the postgres user
DEST="/var/local/backup/postgres/${VERSION}/wal/";
# create folder if it does not exist
if [ ! -d "${DEST}" ];
then
	if ! mkdir -p "${DEST}" ;
	then
		echo "[!] Cannot create destination folder ${DEST}";
		exit 1;
	else
		# owner has to be postgres user
		# again, this is only valid for debian postgresql
		chown -R postgres.postgres "${DEST}";
	fi;
fi;
DATE=$(date +"%F %T");
if [ -e ${PGSQL}"backup_in_progress" ]; then
	echo "${DATE} - backup_in_progress" >> ${DEST}/wal-copy-log.txt
	exit 1
fi
if [ -e ${DEST}/${target_f} ] || [ -e ${DEST}/${target_f}".bz2" ]; then
	echo "${DATE} - old file '${target_f}' still there" >> ${DEST}/wal-copy-log.txt
	exit 1
fi
if [ ! -f ${source_p} ]; then
	echo "${DATE} - source file '${source_p}' cannot be found" >> ${DEST}/wal-copy-log.txt
	exit 1
fi;
echo "${DATE} - /bin/cp ${source_p} ${DEST}/${target_f}" >> ${DEST}/wal-copy-log.txt
/bin/cp "${source_p}" "${DEST}/${target_f}";
# compress all copied file if flag is set
# if the move flag is also set, this is a combine one, else they are single
DATE=$(date +"%F %T");
if [ "${compress}" -eq 1 ] && [ -z "${move}" ];
then
	# check if compress_software is set
	echo "${DATE} - ${compress_cmd} ${DEST}/${target_f} &" >> ${DEST}/wal-copy-log.txt
	${compress_cmd} "${DEST}/${target_f}" &
elif [ "${compress}" -eq 1 ] && [ ! -z "${move}" ];
then
	echo "${DATE} - \$(${compress_cmd} ${DEST}/${target_f}; mv ${DEST}/${target_f}* ${move}/; )&" >> ${DEST}/wal-copy-log.txt
	$(${compress_cmd} "${DEST}/${target_f}"; mv "${DEST}/${target_f}"* "${move}/"; ) &
elif [ "${compress}" -eq 0 ] && [ ! -z "${move}" ];
then
	DATE=`date +"%F %T"`
	echo "${DATE} - mv ${DEST}/${target_f} ${move}/ &" >> ${DEST}/wal-copy-log.txt
	mv "${DEST}/${target_f}"* "${move}/" &
fi;

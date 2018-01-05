#!/bin/bash
# creates SSL key requests from a input file
# needs country|state|locality|organization|domain

function usage ()
{
	cat <<- EOT
	Usage: ${0##/*/} -f <input file> [-o <optional output folder>] [-v [-v] ...]

	-f: mandatory input file. CSV format with | separations
	    Format:
	    Country|State|Location|Organization|Organizational Unit|domain name|password
	-o: optional output folder. If not given, then output will be written to current folder
	-v: verbose output (CSR/KEY) as echo to terminal
	EOT
}

country='';
state='';
locality='';
organization='';
organizationalunit='';
commonname=''; # that is the domain
verbose=0; # verbose level
# for get opt
OPTARG_REGEX="^-";
# log file
logfile="ssl_create.$(date +%Y%m%d_%H%M%S).log";
# opt args
FILE=''; # file to read in
OUTPUT=''; # optional target path

while getopts ":f:o:v" opt
do
	# pre test for unfilled
	if [ "${opt}" = ":" ] || [[ "${OPTARG-}" =~ ${OPTARG_REGEX} ]];
	then
		if [ "${opt}" = ":" ];
		then
			CHECK_OPT=${OPTARG};
		else
			CHECK_OPT=${opt};
		fi;
		case ${CHECK_OPT} in
		f)
			echo "-f needs file name";
			ERROR=1;
			;;
		o)
			echo "-o needs a folder name";
			ERROR=1;
			;;
		esac
	fi;

	case ${opt} in
		# the file from where we read in, must be set
		f|file)
			if [ -z "${FILE}" ];
			then
				FILE="${OPTARG}";
			fi;
			;;
		# output target, if not set current path is used
		o|output)
			if [ -z "${OUTPUT}" ];
			then
				OUTPUT="${OPTARG}";
			fi;
			;;
		# verbose output
		v|verbose)
			verbose=$[ $verbose+1 ];
			;;
		m|help)
			usage;
			exit 0;
			;;
		\?)
			echo -e "\n Option does not exist: $OPTARG\n";
			usage;
			exit 1;
			;;
	esac;
done

# $FILE is a file with all the data in | separated form
if [ ! -f "${FILE}" ];
then
	echo "The input file '${FILE}' is not set or could not be read";
	exit 0;
fi;

if [ ! -z "${OUTPUT}" ];
then
	if [ ! -d "${OUTPUT}" ];
	then
		echo "The output folder '${OUTPUT}' does not exist";
		exit 0;
	fi;
	# check if we can write into that folder
	touch ${OUTPUT}/tmpfile || echo "[!] touch failed";
	if [ ! -f ${OUTPUT}/tmpfile ];
	then
		echo "Cannot write to '${OUTPUT}'";
		exit 0;
	else
		rm -f ${OUTPUT}/tmpfile;
	fi;
	# just in case add /
	OUTPUT=${OUTPUT}'/';
fi;

# start log file
LOGFILE="tee -a ${OUTPUT}${logfile}";
# print overview info
echo "PWD   : $(pwd)" | $LOGFILE;
echo "INPUT : ${FILE}" | $LOGFILE;
echo -n "OUTPUT: " | $LOGFILE;
if [ -z "${OUTPUT}" ];
then
	echo "$(pwd)" | $LOGFILE;
else
	echo "${OUTPUT}" | $LOGFILE;
fi;

# loop through file and create all the data in the current folder
cat ${FILE} |
while read i;
do
	country=$(echo "${i}" | cut -d "|" -f 1);
	state=$(echo "${i}" | cut -d "|" -f 2);
	locality=$(echo "${i}" | cut -d "|" -f 3);
	organization=$(echo "${i}" | cut -d "|" -f 4);
	organizationalunit=$(echo "${i}" | cut -d "|" -f 5);
	commonname=$(echo "${i}" | cut -d "|" -f 6);
	password=$(echo "${i}" | cut -d "|" -f 7);
	echo "--------------------- [START: ${commonname}]" | $LOGFILE;
	# error flag
	error=0;
	# one is missing, we abort
	for check in country state locality organization organizationalunit commonname password;
	do
		if [ -z "${!check}" ];
		then
			echo "${check} is missing" | $LOGFILE;
			error=1;
		fi;
	done;
	if [ ${error} = 1 ];
	then
		echo "--------------------- [ERROR]" | $LOGFILE;
		exit 0;
	fi;
	# copy for file handling (gets folder prefixed with date + domain name)
	# if we have *. we strip the *. and replace it with WILDCARD
	domain=$(echo "${commonname}" | sed -e 's/\*\./WILDCARD\./');
	path=${OUTPUT}$(date +%F)'/'${domain};
	mkdir -p ${path}
	domain=${path}'/'${domain};
	# start generating
	echo "Creating base pem for ${commonname}" | $LOGFILE;
	openssl genrsa -des3 -passout pass:${password} -out ${domain}.pem 2048 -noout | $LOGFILE;
	# generate csr
	echo "Creating CSR for ${commonname} with '/C=${country}/ST=${state}/L=${locality}/O=${organization}/OU=${organizationalunit}/CN=${commonname}'" | $LOGFILE;
	openssl req -new -key ${domain}.pem -out ${domain}.csr -passin pass:${password} -subj "/C=${country}/ST=${state}/L=${locality}/O=${organization}/OU=${organizationalunit}/CN=${commonname}" | $LOGFILE;
	# convert pem to key
	echo "Converting ${commonname} pem to key" | $LOGFILE;
	openssl rsa -in ${domain}.pem -passin pass:${password} -out ${domain}.key | $LOGFILE;

	# helper/viewers
	echo "VIEW CSR: openssl req -text -noout -verify -in ${domain}.csr" | $LOGFILE;
	echo "VIEW CRT: openssl x509 -in ${domain}.crt -text -noout" | $LOGFILE;
	echo "VIEW PEM/KEY: openssl rsa -noout -text -in ${domain}.pem" | $LOGFILE;

	# print out the CSR and KEY [the ones we need]
	if [ "${verbose}" = 1 ];
	then
		echo "";
		echo "=====================";
		echo "=        CSR        =";
		echo "=====================";
		cat ${domain}.csr;
		echo "=====================";

		echo "";
		echo "=====================";
		echo "=        KEY        =";
		echo "=====================";
		cat ${domain}.key;
		echo "=====================";
		echo "";
	fi;

	echo "--------------------- [OK]" | $LOGFILE;
done;

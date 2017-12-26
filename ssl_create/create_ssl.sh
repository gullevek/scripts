#!/bin/bash 
# creates SSL key requests from a input file
# needs country|state|locality|organization|domain

country='';
state='';
locality='';
organization='';
organizationalunit='';
commonname=''; # that is the domain

# $1 is a file with all the data in | separated form
if [ ! -f "${1}" ];
then
	echo "The input file '${1}' is not set or could not be read";
	exit 0;
fi;

# loop through file and create all the data in the current folder
cat ${1} |
while read i;
do
	country=$(echo "${i}" | cut -d "|" -f 1);
	state=$(echo "${i}" | cut -d "|" -f 2);
	locality=$(echo "${i}" | cut -d "|" -f 3);
	organization=$(echo "${i}" | cut -d "|" -f 4);
	organizationalunit=$(echo "${i}" | cut -d "|" -f 5);
	commonname=$(echo "${i}" | cut -d "|" -f 6);
	password=$(echo "${i}" | cut -d "|" -f 7);
	echo "------------------- [START: ${commonname}]";
	# error flag
	error=0;
	# one is missing, we abort
	for check in country state locality organization organizationalunit commonname password;
	do
		if [ -z "${!check}" ];
		then
			echo "${check} is missing";
			error=1;
		fi;
	done;
	if [ ${error} = 1 ];
	then
		echo "------------------- [ERROR]";
		exit 0;
	fi;
	# copy for file handling (gets folder prefixed)
	mkdir ${commonname};
	domain=${commonname}'/'${commonname};
	# start generating
	echo "Creating base pem for ${commonname}";
	openssl genrsa -des3 -passout pass:${password} -out ${domain}.pem 2048 -noout;
	# generate csr
	echo "Creating CSR for ${commonname} with '/C=${country}/ST=${state}/L=${locality}/O=${organization}/OU=${organizationalunit}/CN=${commonname}'";
	openssl req -new -key ${domain}.pem -out ${domain}.csr -passin pass:${password} -subj "/C=${country}/ST=${state}/L=${locality}/O=${organization}/OU=${organizationalunit}/CN=${commonname}"
	# convert pem to key
	echo "Converting ${commonname} pem to key";
	openssl rsa -in ${domain}.pem -passin pass:${password} -out ${domain}.key

	# helper/viewers
	echo "VIEW CSR: openssl req -text -noout -verify -in ${domain}.csr";
	echo "VIEW CRT: openssl x509 -in ${domain}.crt -text -noout";
	echo "VIEW PEM/KEY: openssl rsa -noout -text -in ${domain}.pem";
	echo "------------------- [OK]";
done;

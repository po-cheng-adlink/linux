#!/bin/bash
#################################################################################
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License version 2 as
# published by the Free Software Foundation.
#################################################################################

WORK_DIR=`pwd`
BUILD_DIR="build_fw_imx8"

# Secure HABv4 Boot
#	file://0001-fix-err-msg-linking.patch
CST_MIRROR="https://gitlab.apertis.org/pkg/imx-code-signing-tool.git"
CST_SRC_COMMIT="e2c687a856e6670e753147aacef42d0a3c07891a"
CST_BRANCH="apertis/v2022pre"
CST_DIR="imx-cst"
CST_VER="3.3.1"
CST_BIN="${WORK_DIR}/${BUILD_DIR}/release/linux64/bin/cst"
CST_FUSE="${WORK_DIR}/${BUILD_DIR}/release/crts/fuse.bin"
FUSE_CMD="${WORK_DIR}/${BUILD_DIR}/fuse.bin.cmd"
CST_CSF_CERT="${WORK_DIR}/${BUILD_DIR}/release/crts/CSF1_1_sha256_2048_65537_v3_usr_crt.pem"
CST_IMG_CERT="${WORK_DIR}/${BUILD_DIR}/release/crts/IMG1_1_sha256_2048_65537_v3_usr_crt.pem"
CST_SRK_TABLE="${WORK_DIR}/${BUILD_DIR}/release/crts/table.bin"
PKI_CRTS_LOG=pki_crt_table_fuse.log

LOAD_ADDR_KERNEL="0x40400000"
KERNEL_IMAGE="${WORK_DIR}/arch/arm64/boot/Image"

build_cst()
{
	# ===== Code Singing Tool =====
	if [ ! -d ${CST_DIR} ] ; then
		git clone ${CST_MIRROR} -b ${CST_BRANCH} ${CST_DIR} || printf "Fails to fetch OPTEE source code \n"
		pushd ${CST_DIR} > /dev/null
		git checkout ${CST_SRC_COMMIT}
		popd > /dev/null
	fi

	if [ -d ${CST_DIR} ] ; then
		pushd ${CST_DIR} > /dev/null
		if [ ! -x code/cst/release/linux64/bin/cst -a ! -x code/cst/release/linux64/bin/srktool ] ; then
			pushd code/cst > /dev/null
			make clean OSTYPE=linux64 ENCRYPTION=yes || printf "Fails to clean CST utility\n"
			make build OSTYPE=linux64 ENCRYPTION=yes || printf "Fails to build CST utility\n"
			make rel_bin OSTYPE=linux64 ENCRYPTION=yes || printf "Fails to release CST utility\n"
			popd > /dev/null
		fi
		if [ ! -x code/hab_csf_parser/csf_parser ]; then
			make clean -C code/hab_csf_parser || printf "Failed to clean hab_csf_parser\n"
			make all -C code/hab_csf_parser || printf "Failed to build hab_csf_parser\n"
		fi
		# install to release
		install -m 755 code/hab_csf_parser/csf_parser code/cst/release/linux64/bin/hab_csf_parser
		cp -rf ca code/cst/release
		cp -rf keys code/cst/release
		mkdir -p code/cst/release/crts
		popd > /dev/null
	fi

	# copy release to ${BUILD_DIR}
	if [ ! -d ${WORK_DIR}/${BUILD_DIR}/release ]; then
		cp -rf ${CST_DIR}/code/cst/release ${WORK_DIR}/${BUILD_DIR}/
	fi
}

generate_crts_table_fuse()
{
	pushd ${WORK_DIR}/${BUILD_DIR}/release > /dev/null
	if [ -f crts/CA1_sha256_2048_65537_v3_ca_crt.pem -a \
		-f crts/CSF1_1_sha256_2048_65537_v3_usr_crt.pem -a \
		-f crts/CSF2_1_sha256_2048_65537_v3_usr_crt.pem -a \
		-f crts/CSF3_1_sha256_2048_65537_v3_usr_crt.pem -a \
		-f crts/CSF2_1_sha256_2048_65537_v3_usr_crt.pem -a \
		-f crts/IMG1_1_sha256_2048_65537_v3_usr_crt.pem -a \
		-f crts/IMG2_1_sha256_2048_65537_v3_usr_crt.pem -a \
		-f crts/IMG3_1_sha256_2048_65537_v3_usr_crt.pem -a \
		-f crts/IMG4_1_sha256_2048_65537_v3_usr_crt.pem -a \
		-f crts/SRK1_sha256_2048_65537_v3_ca_crt.pem -a \
		-f crts/SRK2_sha256_2048_65537_v3_ca_crt.pem -a \
		-f crts/SRK3_sha256_2048_65537_v3_ca_crt.pem -a \
		-f crts/SRK4_sha256_2048_65537_v3_ca_crt.pem ]; then
		printf "Using existing generated crts\n"
	else
		./keys/hab4_pki_tree.sh -existing-ca n -use-ecc n -kl 2048 -duration 5 -num-srk 4 -srk-ca y 2>&1 | tee ${WORK_DIR}/${PKI_CRTS_LOG}
	fi

	if [ -f crts/table.bin -a -f crts/fuse.bin ]; then
		printf "Using existing generated table.bin and fuse.bin\n"
	else
		pushd crts > /dev/null
		../linux64/bin/srktool -h 4 -d sha256 -t table.bin -e fuse.bin -c \
			SRK1_sha256_2048_65537_v3_ca_crt.pem, \
			SRK2_sha256_2048_65537_v3_ca_crt.pem, \
			SRK3_sha256_2048_65537_v3_ca_crt.pem, \
			SRK4_sha256_2048_65537_v3_ca_crt.pem 2>&1 | tee -a ${WORK_DIR}/${PKI_CRTS_LOG}
		popd > /dev/null
	fi
	popd > /dev/null
}

usage()
{
	echo -e "\nUsage: install_image_imx8.sh
	Optional parameters: [-m SOC] [-c] [-h]"
	echo "
	* This script is used to build cst tool and generate and signed kernel image
	*
	* [-m SOC]: specify NXP SOC machine, e.g., sp2imx8mp, lecimx8mm, etc
	* [-c]: clean temporary directory
	* [-h]: help

	For example:

	i.mx8MP:
	* SP2-IMX8MP:
	./install_image_imx8.sh -m sp2imx8mp
"
}

print_settings()
{
	echo "*************************************************************"
	echo "Before run this script, please build kernel first!"
	echo "Specified SOC: ${SOC}"
	echo "*************************************************************"
}

if [ $# -eq 0 ]; then
	usage
	exit 1
fi

while getopts "cm:" OPTION
do
	case $OPTION in
	m)
		SOC="$OPTARG"
		;;
	c)
		rm -rf ${BUILD_DIR}
		echo "Clean ${BUILD_DIR}..."
		exit
		;;
	?|h) usage
		exit
		;;
	esac
done

if [ "$(id -u)" = "0" ]; then
	echo "This script can not be run as root"
	exit 1
fi

source ${WORK_DIR}/create_hab_image.sh

mkdir -p ${WORK_DIR}/${BUILD_DIR}
cd ${WORK_DIR}/${BUILD_DIR}
build_cst
generate_crts_table_fuse
generate_signed_image ${SOC}


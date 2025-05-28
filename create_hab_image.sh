#!/bin/bash
#
# Copyright 2025 ADLINK
#
# SPDX-License-Identifier: BSD-3-Clause
#
# A generic function to create NXP Hab Boot software components
#
# Po Cheng <po.cheng@adlinktech.com>
#

# Verify environment variable is set and file exists
verify_env() {
	[ -z "$1" ] && echo "Please set environment variable '$2'"
	[ ! -f $1 ] && echo "Could not find '$1'"
}

################################################################################
#
# align_image.sh
#
align_image() {
	IMAGE_SIZE=$(wc -c < $1)
	ALIGNED_SIZE=$(( ($IMAGE_SIZE + 0x1000 - 1) & ~ (0x1000 - 1) ))

	printf "Extend %s from 0x%x to 0x%x...\n" $1 $IMAGE_SIZE $ALIGNED_SIZE
	objcopy -I binary -O binary --pad-to $ALIGNED_SIZE --gap-fill=0x00 $1 ${1}-pad
}



################################################################################
#
# csf for kernel image
#

# Generate HAB block for a file
# Inputs: Start Address, File Path
# Outputs: "<start address> 0x0 <file size> <relative path to file>"
create_hab_block() {
	START_ADDR=$1
	FILE_PATH=$2
	FILE_PATH_RELATIVE=$(realpath --relative-to="/" $2)
	FILE_SIZE=$(printf "0x%08x\n" $(stat -c "%s" ${FILE_PATH}))
	BLOCK=$(printf "0x%08x 0x%08x 0x%08x \"/%s\"" "${START_ADDR}" "0x0" "${FILE_SIZE}" "${FILE_PATH_RELATIVE}")
	echo ${BLOCK}
}

create_csf_habv4() {
	CSF=$1
	IMG_NAME=$(basename ${KERNEL_IMAGE})

	# Copy template file
	cat > ${CSF} << EOF
[Header]
	Version = 4.2
	Hash Algorithm = sha256
	Engine Configuration = 0
	Certificate Format = X509
	Signature Format = CMS
	Engine = CAAM

[Install SRK]
	# Index of the key location in the SRK table to be installed
	File = "@CST_SRK_TABLE@"
	Source index = 0

[Install CSFK]
	# Key used to authenticate the CSF data
	File = "@CST_CSF_CERT@"

[Authenticate CSF]

[Install Key]
	# Key slot index used to authenticate the key to be installed
	Verification index = 0
	# Target key slot in HAB key store where key will be installed
	Target Index = 2
	# Key to install
	File = "@CST_IMG_CERT@"

[Authenticate Data]
	# Key slot index used to authenticate the image data
	Verification index = 2
	# Authenticate Start Address, Offset, Length and file
EOF

	# Update keys from template
	sed -i "s|@CST_SRK_TABLE@|${CST_SRK_TABLE}|g" ${CSF}
	sed -i "s|@CST_CSF_CERT@|${CST_CSF_CERT}|g" ${CSF}
	sed -i "s|@CST_IMG_CERT@|${CST_IMG_CERT}|g" ${CSF}

	# Add Block(s)
	# --- Add kernel block:
	HAB_BLOCK_KERNEL=$(create_hab_block "${LOAD_ADDR_KERNEL}" "${IMG_NAME}_pad_ivt")

	# --- Add device tree block (Optional):
	if [ -n "${SIGN_DTB}" ]; then
		if [ ! -f "${SIGN_DTB}" ]; then
			bbfatal "${SIGN_DTB} not found"
		fi

		# Append ", \" to kernel block for proper syntax
		HAB_BLOCK_KERNEL="${HAB_BLOCK_KERNEL}, \\"

		# Pad DTB
		align_image ${SIGN_DTB}
		cp ${SIGN_DTB}-pad ${SIGN_DTB}

		# Add DTB block
		HAB_BLOCK_DTB=$(create_hab_block ${LOAD_ADDR_DTB} ${SIGN_DTB})
	fi

	# --- Write blocks to CSF file:
	echo "	Blocks = ${HAB_BLOCK_KERNEL}" >> ${CSF}
	echo "			 ${HAB_BLOCK_DTB}" >> ${CSF}
}

# Follows "Authenticating the OS container" from:
# https://github.com/varigit/uboot-imx/blob/imx_v2020.04_5.4.24_2.1.0_var02/doc/imx/ahab/guides/mx8_mx8x_secure_boot.txt
do_sign_kernel_ahab() {
	printf "Not Implemennted...\n"
}

# Follows "Authenticating additional boot images" from:
# https://github.com/varigit/uboot-imx/blob/imx_v2020.04_5.4.24_2.1.0_var02/doc/imx/habv4/guides/mx8m_secure_boot.txt
do_sign_kernel_habv4() {
	IMG_ADDR=$(( ${LOAD_ADDR_KERNEL} ))
	IMG=${KERNEL_IMAGE}
	IMG_NAME=$(basename ${KERNEL_IMAGE})

	# Read kernel image size:
	IMG_SIZE=$(od -x -j 0x10 -N 0x4 --endian=little ${IMG} | awk 'NR==1 { print "0x"$3 $2 }')

	# Pad kernel image:
	objcopy -I binary -O binary --pad-to ${IMG_SIZE} --gap-fill=0x00 ${IMG} ${IMG_NAME}_pad
	printf "Pad Kernel Image to size: %u (0x%08x)\n" "${IMG_SIZE}" "${IMG_SIZE}"

	# Generate IVT:
	${WORK_DIR}/genIVT.pl $(printf "0x%x" ${IMG_ADDR}) $(printf "0x%x" ${IMG_SIZE})

	# Append the ivt.bin at the end of the padded Image:
	cat ${IMG_NAME}_pad ivt.bin > ${IMG_NAME}_pad_ivt

	# Create csf for signing
	create_csf_habv4 ${IMG_NAME}.csf

	# Create signature
	${CST_BIN} -i ${IMG_NAME}.csf -o ${IMG_NAME}.csf.bin

	# Attach signature to Image_signed
	cat ${IMG_NAME}_pad_ivt ${IMG_NAME}.csf.bin > ${IMG_NAME}.signed

	# Create final signed Image.gz
	gzip -f -k ${IMG_NAME}.signed

	# Manually authenticate:
	# u-boot> hab_auth_img ${IMG_ADDR} $filesize ${IMG_SIZE}
	# Write file with example commands:
	echo ""
	echo "The following is an example for how to manually authenticate an image:" | tee ${IMG_NAME}.gz.uboot-cmds
	echo "u-boot> tftp \${img_addr} ${IMG_NAME}.gz; unzip \${img_addr} \${loadaddr};" | tee -a ${IMG_NAME}.gz.uboot-cmds
	echo "u-boot> hab_auth_img \${loadaddr} \${filesize} ${IMG_SIZE}" | tee -a ${IMG_NAME}.gz.uboot-cmds
}

generate_signed_image() {
	tgt="$1"

	verify_env "${CST_BIN}" "CST_BIN"
	verify_env "${KERNEL_IMAGE}" "KERNEL_IMAGE"
	verify_env "${CST_SRK_TABLE}" "CST_SRK_TABLE"

	case ${tgt} in
	*mx8m*)
		verify_env "${CST_CSF_CERT}" "CST_CSF_CERT"
		verify_env "${CST_IMG_CERT}" "CST_IMG_CERT"
		do_sign_kernel_habv4
		;;
	*mx8x|*mx8)
		verify_env "${CST_KEY}" "CST_KEY"
		do_sign_kernel_ahab
		;;
	*)
		echo "Unsupported SOC $1"
		;;
	esac
}


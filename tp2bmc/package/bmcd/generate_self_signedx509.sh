#!/bin/sh
# shellcheck shell=sh

# BMCD reads /etc/ssl/certs/bmcd_*.pem (merged). On overlay rootfs, openssl must
# write into /mnt/overlay/upper/etc/ssl/certs — not merged /etc/ssl/certs
# (lower CA bundle → copy-up "Directory not empty" on rename).
cert_merged=/etc/ssl/certs/bmcd_cert.pem
key_merged=/etc/ssl/certs/bmcd_key.pem
if [ -d /mnt/overlay/upper/etc/ssl/certs ]; then
	ssl_dir=/mnt/overlay/upper/etc/ssl/certs/
else
	ssl_dir=/etc/ssl/certs/
fi
cert_file="${ssl_dir}/bmcd_cert.pem"
key_file="${ssl_dir}/bmcd_key.pem"

# Generate new self-signed X509 certs.
#
# Generate a new self-signed X509 cert and private key for use by BMCD.
# This will overwrite any existing certs, so be careful when using.
generate_certs() {
	echo "Generating new self-signed X509 certs.."
	mkdir -p "${ssl_dir}"
	find "${ssl_dir}" -maxdepth 1 -name '.wh.*' 2>/dev/null \
		| while read -r _w; do rm -f "$_w"; done
	openssl req -x509 -newkey rsa:4096 -keyout "${key_file}" \
		-out "${cert_file}" -nodes -subj "/CN=Turing-Pi self signed"
	echo "Done"
}

# Check if certificates exists and file > 0 bytes (merged paths — what bmcd reads).
if [ ! -s "${cert_merged}" ] || [ ! -s "${key_merged}" ]; then
	echo "One of the files is empty. Regenerating certs.."
	rm -f "${cert_file}" "${key_file}" "${cert_merged}" "${key_merged}"
	generate_certs
else
	# Validate cert and key belong together as a pair
	cert_modulus=$(openssl x509 -noout -modulus -in "${cert_merged}" | openssl md5)
	key_modulus=$(openssl rsa -noout -modulus -in "${key_merged}" | openssl md5)
	if [ "${cert_modulus}" = "${key_modulus}" ]; then
		echo "Cert and key are valid and belong together."
	else
		echo "Cert and key do not match. Regenerating certs.."
		rm -f "${cert_file}" "${key_file}" "${cert_merged}" "${key_merged}"
		generate_certs
	fi
fi

exit 0

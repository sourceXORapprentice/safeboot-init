#!/bin/bash
#
# Safeboot-init - An install wizard for safeboot
#
# Wizard should walk through critical phases and track success
# to move on to each sequential step:

# 1. Check for compatibility, install safeboot & reboot
# **User instructed to place motherboard bios/uefi 
# into secure boot "setup mode"
# REBOOT -> IN BIOS, ENTER SECURE BOOT "SETUP MODE"
#
# 2. UEFI secure boot signing keys init and uefi-sign-keys
# **User instructed at end to clear TPM keys in bios/uefi menu,
# User also warned to select "Recovery" before rebooting
# and then "Ctrl-D" or exit to then login again to recovery.
# If they DO NOT see the Recovery menu then reboot and try again.
# REBOOT -> IN BIOS, do "TPM Reset"
#
# 3. update-initramfs & luks-seal - do it twice!
#
# turn off "expressions don't expand in single quotes"
# and "can't follow non-constant sources"
# shellcheck disable=SC2016 disable=SC1091

# pipefail, to return status for pipeline and not just the last one 
set -e -o pipefail

#INTERACTIVE=True
# TO DO - Add some compatibility layers for other distro's
#LINUX_PACKAGE=apt

CONFIG=/etc/safeboot/local.conf
VERSION_GITHUB=safeboot_0.8_amd64.deb

#Bash Colors:
bash_color() {
	echo "Bash foregrounds:"
	for COLOR in $(seq 30 37); do echo -e "\e[1;""$COLOR""mCOLOR""$COLOR""\e[00m";done
	for COLOR in $(seq 90 97); do echo -e "\e[1;""$COLOR""mCOLOR""$COLOR""\e[00m";done
	echo "Bash backgrounds:"
	for COLOR in $(seq 40 47); do echo -e "\e[1;""$COLOR""mCOLOR""$COLOR""\e[00m";done
	for COLOR in $(seq 100 107); do echo -e "\e[1;""$COLOR""mCOLOR""$COLOR""\e[00m";done
	echo -e "\e[1;33mThis is yellow text\e[00m"
	echo -e "\e[1;31mThis is red text\e[00m"
}

safeboot-init_config_local_update() {
		#Update config variables, there should be cleaner ways to do this:
		&>/dev/null mkdir /etc/safeboot || true
		[ -e $CONFIG ] || touch $CONFIG
		if [ "$(grep -c "$1" "$CONFIG")" == 0 ]
		then
			echo "$1=$2" >> $CONFIG
		else
			sed -i 's/^'"$1"'=.*/'"$1"'='"$2"'/g' $CONFIG
		fi
}

safeboot-init_compatibility() {
	#Some compatibility checks

	# Check bios modem legacy or UEFI secureboot
	if [ "$(ls /sys/firmware/efi/)" -ge 1 ]; then
		echo -e "\e[1;31mUEFI firmware not detected, please enable secureboot in your BIOS/UEFI motherboard firmware setup and reinstall the Operating System.\e[00m"
		return 1
	fi
	
	# Motherboard data
	# TO DO: Point users to device-specific tips on:
	# 1. Secure boot setup mode
	# 2. Clearing TPM key
	echo "Motherboard:"
	dmidecode | grep -A8 '^System Information' | grep 'Manufacturer'
	dmidecode | grep -A8 '^System Information' | grep 'Product Name'
	echo "Consult the website of the manufacturer abover for product-specific"
	echo "instructions on how to:"
	echo " 1. Place the UEFI/BIOS into secure boot setup mode"
	echo " 2. Reset and clear the TPM key"
	echo

	#TPM version checks
	echo "TPM information (safeboot requires 2.0):"
	TPM_DMESG=$(dmesg | grep tpm)
	#WANTED: Should add a handling if "Bug" returns 
	#to warn user to update firmware
	TPM_VENDOR=$(fwupdmgr get-devices --show-all-devices | grep -A10 '─TPM' | grep -m1 'Vendor')
	TPM_VER=$(fwupdmgr get-devices --show-all-devices | grep -A10 '─TPM' | grep -m1 'VER_2')
	echo -e "$TPM_DMESG""\n""$TPM_VENDOR""\n""$TPM_VER"
	echo "If there is no information above or it does not say 'VER_2' "
	echo "then either the TPM needs to be enabled in your motherboard's"
	echo "UEFI/BIOS settings, or your device doesn't have a compatible TPM."
	echo

	#Check if installed with GPT boot partition	
	echo "Boot partition type (should be GPT):"
	BOOT_PART=$(grep /boot/efi /proc/mounts | awk '{print $1}')
	#grep for the boot partition
	sudo parted -l 2>&1 | grep -A10 "${BOOT_PART//[[:digit:]]/}" | grep -m1 'Partition Table'
}

safeboot-init_prerequisites() {
	#TO DO - Platform check & agnostic installing, and lookup relevant packages in yum/dnf/etc.
	apt update
	apt upgrade -y
	#Probably only necessary for source:
	apt install -y \
	make automake git xxd \
	tpm2-tools libtss2-dev devscripts debhelper \
	build-essential binutils-dev git help2man \
	libssl-dev uuid-dev
	#Likely necessary for all installs (refused to run without yubico-piv-tool:
	apt install -y \
	efitools gnu-efi opensc yubico-piv-tool \
	libengine-pkcs11-openssl cryptsetup-bin cryptsetup \
	pcsc-tools pcscd opensll 
}

safeboot-init_source_compile() {
	warn "Installing prerequisites..."
	safeboot-init_prerequisites
	
	## THIS FAILS HERE WITHOUT REBOOT 
	## IS A REBOOT REQUIRED HERE??

	warn "Downloading latest source..."
	git clone https://github.com/osresearch/safeboot
	cd safeboot

	warn "Making and installing"
	make requirements
	make package
	cd ..
	apt install -y ./$VERSION_GITHUB

	#check if success, source install can be persnickity
	if [ $# -lt 1 ]; then
		echo "Install from source failed. Please troubleshoot errors above before continuing."
		return 1
	fi
}

safeboot-init_config() {
	
	#TO DO - create walkthrough to ask for configuration, such as sealing pin, etc.

	#Make config if doesn't exist:
	mkdir /etc/safeboot 2>&1
	[ -e $CONFIG ] || touch $CONFIG

	#Do some steps to ask for settings, 
	#Seal PIN setting:
	#bash -c 'echo $CONFIG_SEAL >> /etc/safeboot/local.conf'
	read -r -p "Do you want a PIN required to unseal/decrypt the disk? [y/n]" response
	if [ "$response" = "y" ]; then
		safeboot-init_config_local_update SEAL_PIN 1
		echo "Set sealing PIN on, you will be prompted for the pin later when it is required."
	elif [ "$response" = "n" ]; then
		safeboot-init_config_local_update SEAL_PIN 0
		echo "Set sealing PIN off, you will not be prompted for a PIN."
	else
		safeboot-init_config_local_update SEAL_PIN 1
		echo "Input misunderstood, defaulting to default of on. You will be prompted for the PIN later when it is required."
	fi

}

safeboot-init_init() {

    #TO DO - ADD HANDLER FOR COMMON NAME/etc.
    #TO DO - switch between yubikey or local cert
    safeboot key-init /CN=test/

    if [ $? -eq 1 ]; then
            echo "Unable to create key"
            #TO DO - requests starting over
            return 1
    fi

	safeboot uefi-sign-keys

	if [ $? -eq 1 ]; then 
		echo "\
WARNING: Failed at: safeboot uefi-sign-keys\
If error, reboot back to the bios/setup and ensure you have \
placed it in secureboot setup mode. Check your device's manual for\
specific process, some motherboards require 1. A reset of secureboot\
keys, and then 2. A second reboot to settings to then clear the \
secureboot keys. Do not continue until the command succeeds without error."
		read -r -p "Do you understand and want to reboot now? [y/n]"
		if [ "$response" = "y" ]; then
			reboot now
		elif [ "$response" = "n" ]; then
			echo "Exiting, unable to continue. Please resolve secureboot mode issue."
			return 1
		fi

	rm -rf /boot/efi/EFI/linux
	rm -rf /boot/efi/EFI/recovery
	# This deletion is a workaround because there's usually no room in /boot/efi
	# thanks sidhussmann for this tip
	safeboot recovery-sign

	#To Do: add error handling
	if [ $? -eq 1 ]; then
		echo "Recovery sign failed, unable to sign the image. Repeat previous steps to continue."
		return 1
	fi

	#Update phase prior to reboot into recovery
	safeboot-init_config_local_update INSTALL_PHASE 2
	safeboot recovery-reboot
	if [ $? -eq 1 ]; then
        echo "\
READ CAREFULLY: Automatic reboot into recovery failed. This is inconvenient,\
but not a problem, since some systems do not allow changes to the\
next boot option. When you are ready, we will reboot and you must:\
1. Press the boot selection key at boot to enter the boot menu.\
This varies among manufacturers and boards, but is typically the F9 key, F8, F10, or DEL keys.\
2. Select the boot option 'recovery'\
3. There should be a large red banner titled 'Recovery', if not repeat the previous steps.\
4. Login by pressing "CTRL-D" or typing "exit", login as usual\
5. Continue by relaunching this script."
		read -r -p "Did you read carefully and are ready to reboot and select 'recovery'? [y/n]"
		if [ "$response" = "y" ]; then
			reboot now
		elif [ "$response" = "n" ]; then
			echo "Exiting, unable to continue. You can reboot manually."
			return 1
		fi
}

safeboot-init() {

	# Got root?
	if [ "$(id -g)" != 0 ]; then
		echo "safeboot-init must be run as root! Please run as root or with sudo."
		return 1
	fi

	#Do a phase check to pickup after reboot:
	cat >&2 <<'EOF'
             __      _                 _        _       _ _   
  ___  __ _ / _| ___| |__   ___   ___ | |_     (_)_ __ (_) |_ 
 / __|/ _` | |_ / _ \ '_ \ / _ \ / _ \| __|____| | '_ \| | __|
 \__ \ (_| |  _|  __/ |_) | (_) | (_) | |__|__|| | | | | | |_ 
 |___/\__,_|_|  \___|_.__/ \___/ \___/ \__|    |_|_| |_|_|\__|
==============================================================

*** TEST - NOT A COMPLETE INSTALLER ***

This is an experimental install wizard for safeboot not 
currently affiliated with safeboot.dev or fully tested.

It will install various pre-requisites, download source 
software, and make changes to your device's configuration.

Please only run this on a fresh installation of Ubuntu on a 
device without any data and that you understand how to reset 
to factory defaults in the (likely) event of failure.

Reboots will be required throughout. Please pay special 
attention to instructions prior to each reboot!

Do you understand that using this will likely cause data loss
and require manually resetting your device's firmware?

EOF

	read -r -p "This may lead to data loss, are you really sure? [y/n]" really_do_it
	if [ "$really_do_it" != "y" ]; then
		echo "Not installing safeboot!"
		return 1
	fi

	#Make config if doesn't exist:
	mkdir /etc/safeboot 2>&1
	[ -e $CONFIG ] || touch $CONFIG

	# TO DO - Auto-launch script after terminal login
	# TO DO - Make script pop-up in Ubuntu Desktop after login

	#*** PHASE 0 - Install Safeboot & Configure settings ***#
	if [ "$(grep -c INSTALL_PHASE $CONFIG)" == 0 ]||\
	   [ "$(grep INSTALL_PHASE $CONFIG | cut -d "=" -f 2)" == 0 ]; then
		#TO DO - find more agnostic package check
		if [ "$(dpkg -l | grep -c safeboot)" -ge 1 ]; then
			#Check if safeboot already installed
			echo "Safeboot already installed! Proceeding to next phase."
			safeboot-init_config_local_update INSTALL_PHASE 1
			return 0
		fi
		#PHASE 0 - Install safeboot from source
		safeboot-init_source_compile
		if [ $? -eq 1 ]; then
			echo "Unable to install from source."
			#TO DO - requests starting over
			return 1
		fi

		#Set config
		safeboot-init_config
		if [ $? -eq 1 ]; then
			echo "Unable to set configuration file. Make sure Safeboot installed and you can write to /etc/safeboot/local.conf"
			#TO DO - requests starting over
			return 1
		fi
		safeboot-init_config_local_update INSTALL_PHASE 1
	fi

	#*** PHASE 1 - Init safeboot keys &  ***#
	#TO DO - Yubikey handling
	if [ "$(grep INSTALL_PHASE $CONFIG | cut -d "=" -f 2)" == 1 ]; then
		#PHASE 1

		safeboot-init_init
		if [ $? -eq 1 ]; then
			echo "Unable to do initial install phase."
			#TO DO - requests starting over
			return 1
		else
			safeboot-init_config_local_update INSTALL_PHASE 2
		fi
	fi

	#*** PHASE 2 - LUKS Seal
	if [ "$(grep INSTALL_PHASE $CONFIG | cut -d "=" -f 2)" == 2 ]; then
		safeboot luks-seal
		safeboot recovery-sign
		if [ $? -eq 1 ]; then
			echo "Unable to sign recovery."
			#TO DO - Add delete steps for out of space errors
			return 1
		else
			safeboot-init_config_local_update INSTALL_PHASE 3
		fi
		safeboot recovery-reboot
		#Handle failed reboot set
		reboot now
	fi

	#*** PHASE 3 - Sign Linux
	if [ "$(grep INSTALL_PHASE $CONFIG | cut -d "=" -f 2)" == 3 ]; then
		#PHASE 2
		safeboot linux-sign
		echo "This should be the final reboot"
		#TO DO - reboot handler
		reboot now
	fi

	#*** PHASE 4 - dmverity settup (optional) ***#
}

safeboot-init

exit

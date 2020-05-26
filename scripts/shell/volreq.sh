#!/bin/bash

function init() {
    # variables to automate in a near future
    dst_volume_type=gp2
    dst_volume_size=15
    dst_volume_fs=xfs
    dst_volume_tag_key=purpose
    dst_volume_tag_value=production
    aws_url="http://169.254.169.254/latest"

    # terminal colors
    color_bold=$'\x1b[97m'
    color_green=$'\x1b[92m'
    color_red=$'\x1b[31m'
    color_reset=$'\x1b[0m'
    color_yellow=$'\x1b[93m'
}

function checkRequirements() {
    test -z "$*" && return
    while [ -n "$1" ]; do
        echo -n "Checking for $1... "
        if command -v "$1" &> /dev/null; then
            echo -ne "$color_green"
            echo "success."
            echo -ne "$color_reset"
        else
            echo -ne "$color_red"
            echo "not found or permission denied."
            echo -ne "$color_reset"
            exit 2
        fi
        shift
    done
}

function loadingEffect() {
    test -z "$*" && return
    declare -i counter=1
    while [ $counter -lt "$1" ]
    do
        echo -ne "-"\\r
        sleep 0.1
        echo -ne "\\\\"\\r
        sleep 0.1
        echo -ne "|"\\r
        sleep 0.1
        echo -ne "/"\\r
        sleep 0.1
        counter=$counter+1
    done
}

function sanityCheck() {
    if [ ! "$UID" = "0" ]; then
		echo "Only root can do that, $USER"
		exit 2
	fi

    if [ ! "$(uname)" = "Linux"  ]; then
		echo "Operating system $(uname) not supported"
		exit 2
    fi

    echo -ne "$color_bold"
    echo -e "Welcome to $0\nSanity check..."
    echo -ne "$color_reset"

    checkRequirements dmidecode aws curl parted mkfs realpath tar lsblk tune2fs xfs_admin

    dmi_bios=$(dmidecode -s bios-version)
    case "$dmi_bios" in
        Google)
            cloud_provider=gcp
            ;;
        4.2.amazon)
            cloud_provider=aws
            if ! aws sts get-caller-identity > /dev/null 2>&1 
            then
                echo -ne "$color_red"
                echo "awscli not configured, aborting"
                echo -ne "$color_reset"
                exit 2
            fi
            ;;
        *)
            echo -ne "$color_red"
            echo "Unknown cloud provider ($dmi_bios), aborting."
            echo -ne "$color_reset"
            exit 2
            ;;
    esac
}

function selectSrcDir() {
    echo -ne "$color_bold"
    echo -e "\nListing mounted filesystems"
    echo -ne "$color_reset"
    df -l -h --output=target,size,pcent
    echo -ne "$color_yellow"
    echo -n "Please enter the filesystem to resize: "
    echo -ne "$color_reset"
    read -r src_dir
    if [ -z "$src_dir" ]; then
        echo -ne "$color_red"
        echo "Filesystem can't be empty, aborting"
        echo -ne "$color_reset"
        exit 2
    fi

    if [ "$src_dir" = "/" ]; then
        echo -ne "$color_red"
        echo "Can't resize root filesystem"
        echo -ne "$color_reset"
        exit 2
    fi

    src_device=$(df --output=source "$src_dir" 2> /dev/null | grep -v "^Filesystem")
    if [ "$src_device" = "" ]; then
        echo -ne "$color_red"
        echo "$src_dir is not a valid mounted filesystem, aborting"
        echo -ne "$color_reset"
        exit 2
    fi

    if [ "$(grep "$src_dir" /etc/fstab | awk '{ print $1 }' | grep -F "$src_device")" = "" ]; then
        echo -ne "$color_red"
        echo "$src_dir needs to be configured in /etc/fstab to resize"
        echo -ne "$color_reset"
        exit 2
    fi

    echo -e "\n"
    df -h "$src_dir"
    echo -ne "$color_yellow"
    echo -n "Are you sure? (y/N): "
    echo -ne "$color_reset"
    read -r yn

    if [ ! "$yn" == "y" ]; then
        exit 0
    fi
}

function createDstDir() {
    case "$cloud_provider" in
        aws)
            IFS=" " read -r -a srv_instance_identity <<< "$( \
                curl -s $aws_url/dynamic/instance-identity/document | \
                grep -E '"(availabilityZone|instanceId|region)"' | \
                tr -d '":,\n')"
            if [ -z "${srv_instance_identity[5]}" ]; then
                echo "Error running curl to fetch instance identity, aborting"
                exit 2
            else
                srv_availability_zone=${srv_instance_identity[1]}
                srv_instance_id=${srv_instance_identity[3]}
                srv_region=${srv_instance_identity[5]}
                echo -e "\nFound EC2 instance with the following information:"
                echo -e "instance id: $srv_instance_id"
                echo -e "region: $srv_region"
                echo -e "availability zone: $srv_availability_zone"
            fi

            echo -ne "$color_bold"
            echo -e "\nListing AWS volume information:"
            echo -ne "$color_reset"

            aws ec2 describe-instances \
                --instance-ids "$srv_instance_id" \
                --region "$srv_region" \
                --query 'Reservations[*].Instances[].[BlockDeviceMappings[*].{DeviceName:DeviceName,VolumeName:Ebs.VolumeId}]' \
                --output table

            aws ec2 describe-volumes \
                --region "$srv_region" \
                --query 'Volumes[*].[Attachments[0].InstanceId,Attachments[0].VolumeId,State,Size]' \
                --filter "Name=attachment.instance-id,Values=$srv_instance_id" \
                --output table

            echo -ne "$color_bold"
            echo -e "\nListing current local block devices:"
            echo -ne "$color_reset"
            lsblk -f -p

            echo -ne "$color_yellow"
            echo -n "Please enter a new volume name to create a filesystem (ex: sdb): "
            echo -ne "$color_reset"
            read -r dst_volume_name

            echo -e "\nYou are about to create a new EBS volume with the following information:"
            echo -e "name: $dst_volume_name"
            echo -e "size: ${dst_volume_size}Gb"
            echo -e "region: $srv_region"
            echo -e "availability zone: $srv_availability_zone"
            echo -e "volume type: $dst_volume_type"
            echo -ne "$color_yellow"
            echo -n "Are you sure? (y/N): "
            echo -ne "$color_reset"
            read -r yn
            if [ ! "$yn" == "y" ]; then
                exit 0
            fi

            dst_volume_id=$(aws ec2 create-volume \
                --region "$srv_region" \
                --availability-zone "$srv_availability_zone" \
                --size "$dst_volume_size" \
                --volume-type "$dst_volume_type" \
                --tag-specifications "ResourceType=volume,Tags=[{Key=$dst_volume_tag_key,Value=$dst_volume_tag_value}]" | \
                grep VolumeId | awk -F\" '{ print $4 }')
            if [ -z "$dst_volume_id" ]; then
                echo -ne "$color_red"
                echo "Error creating new volume, aborting."
                echo -ne "$color_reset"
                exit 2
            fi

            echo "A new volume has been created with id: $dst_volume_id"
            echo "Waiting to safely attach EBS volume into the instance... "
            loadingEffect 50
            echo

            lsblk -p | awk '/disk $/ { print $1 }' >> /tmp/lsblk-pre.$$ 2>&1

            dst_volume_state=$(aws ec2 attach-volume \
                --region "$srv_region" \
                --volume-id "$dst_volume_id" \
                --instance-id "$srv_instance_id" \
                --device "$dst_volume_name" | \
                grep State | awk -F\" '{ print $4 }')
            if [ ! "$dst_volume_state" = "attaching" ]; then
                echo -ne "$color_red"
                echo "Error attaching new volume, aborting."
                echo -ne "$color_reset"
                exit 2
            fi

            echo "Waiting to safely attach the block device into the OS... "
            loadingEffect 50

            lsblk -p | awk '/disk $/ { print $1 }' >> /tmp/lsblk-post.$$ 2>&1
            dst_block_device=$(tail -1 /tmp/lsblk-post.$$)
            if [ ! "$(grep "$dst_block_device" /tmp/lsblk-pre.$$)" = "" ]; then
                echo -ne "$color_red"
                echo "Error detecting new block device, aborting."
                echo -ne "$color_reset"
                exit 2
            fi

            rm -f /tmp/lsblk-pre.$$ /tmp/lsblk-post.$$

            echo "Sucessfully attached volume $dst_volume_id to instance $srv_instance_id with block device $dst_block_device"

            ;;

        gcp)
            echo "GCP not yet implemented"
            ;;
        *)
            echo "Unknown cloud provider ($cloud_provider), aborting"
            exit 2
            ;;
    esac

    dst_volume_partition="${dst_block_device}1"
    echo "Creating a partition $dst_volume_partition"
    parted "$dst_block_device" -s mklabel msdos > /dev/null 2>> /tmp/parted.$$
    if ! parted "$dst_block_device" -s -a optimal mkpart primary "$dst_volume_fs" 3 100% > /dev/null 2>> /tmp/parted.$$
    then
        echo -ne "$color_bold"
        echo "Error creating a primary partition in $dst_block_device"
        echo -ne "$color_red"
        if [ -s /tmp/parted.$$ ]; then
            cat /tmp/parted.$$
            rm -f /tmp/parted.$$
        fi
        echo -ne "$color_reset"
        return 2
    fi

    if [ ! -b "$dst_volume_partition" ]; then
        echo -ne "$color_red"
        echo "$dst_volume_partition not found, aborting."
        echo -ne "$color_reset"
        exit 2
    fi

    echo "Partition $dst_volume_partition created sucessfully"

    echo "Creating a $dst_volume_fs filesystem in $dst_volume_partition"
    if ! mkfs -t "$dst_volume_fs" "$dst_volume_partition" >> /tmp/mkfs.$$ 2>&1
    then
        echo -ne "$color_bold"
        echo "Error creating a filesystem in $dst_volume_partition"
        echo -ne "$color_red"
        if [ -s /tmp/mkfs.$$ ]; then
            cat /tmp/mkfs.$$
            rm -f /tmp/mkfs.$$
        fi
        echo -ne "$color_reset"        
        return 2
    fi

    echo "Filesystem created sucessfully"

    echo "Setting filesystem UUID"
    case "$dst_volume_fs" in
        ext[2-4])
            tune2fs "$dst_volume_partition" -U random > /dev/null 2>&1
            ;;
        xfs)
            xfs_admin -U generate "$dst_volume_partition" > /dev/null 2>&1
            ;;
        *)
            echo "Unkown filesystem, aborting"
            exit 2
            ;;
    esac

    dst_fs_uuid=$(blkid "$dst_volume_partition" | grep UUID | awk -F\" '{ print $2 }')
    if [ -z "$dst_fs_uuid" ]; then
        echo -ne "$color_red"
        echo "Could not find UUID from filesystem $dst_volume_partition"
        echo -ne "$color_reset"
        exit 2
    fi

    echo "Adding new mount point ${src_dir}-volreq to /etc/fstab"
    if [ ! "$(grep "$dst_fs_uuid" /etc/fstab)" = "" ]; then
        echo -ne "$color_red"
        echo "Filesystem with UUID $dst_fs_uuid already in /etc/fstab file, aborting"
        echo -ne "$color_reset"
        exit 2
    fi
    echo "UUID=$dst_fs_uuid ${src_dir}-volreq $dst_volume_fs defaults 0 0" >> /etc/fstab

    dst_dir="${src_dir}-volreq"
    mkdir -p "$dst_dir"
    if ! mount -a
    then
        echo -ne "$color_red"
        echo "Error mounting filesystems, aborting"
        echo -ne "$color_reset"
        exit 2
    fi
}

function tarCloneFs() {
    if [ ! -d "$1" ] || [ ! -d "$2" ]; then
        echo "Usage: $0 <source_directory> <destination_directory>"
        exit 2
    fi

    _src_dir="$(realpath -q "$1")"
    _dst_dir="$(realpath -q "$2")"

    echo "Copying from $src_dir to $dst_dir..."
    cd "$_src_dir" && tar cf - . 2>> /tmp/clone_fs_in.$$ | if ! tar xvf - -C "$_dst_dir" 2>> /tmp/clone_fs_out.$$
    then
        echo -ne "$color_bold"
        echo "Error cloning directories"
        echo -ne "$color_red"
        if [ -s /tmp/clone_fs_in.$$ ] || [ -s /tmp/clone_fs_out.$$ ]; then
            cat /tmp/clone_fs*.$$
            rm -f /tmp/clone_fs*.$$
        fi
        echo -ne "$color_reset"        
        return 2
    fi

    echo "Done cloning directories"
    if [ -s /tmp/clone_fs_in.$$ ]; then
            echo -ne "$color_bold"
            echo "Error messages found while reading directories:"
            echo -ne "$color_red"
            cat /tmp/clone_fs_in.$$
            echo -ne "$color_reset"
    fi

    if [ -s /tmp/clone_fs_out.$$ ]; then
            echo -ne "$color_bold"
            echo "Error messages found while writing directories:"
            echo -ne "$color_red"
            cat /tmp/clone_fs_out.$$
            echo -ne "$color_reset"
    fi

    rm -f /tmp/clone_fs*.$$
}

init
sanityCheck
selectSrcDir
createDstDir
tarCloneFs "$src_dir" "$dst_dir"

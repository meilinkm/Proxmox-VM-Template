#!/bin/bash

# This script will download and modify the desired image to prep for VM template build.
# The script is inspired by these separate authors work:
# - Austins Nerdy Things: https://austinsnerdythings.com/2021/08/30/how-to-create-a-proxmox-ubuntu-cloud-init-image/
# - What the Server: https://whattheserver.com/proxmox-cloud-init-os-template-creation/
# - https://gtgb.io/ - https://github.com/geektx/Proxmox-VM-Template
# - https://github.com/modem7/public_scripts/blob/master/Bash/Proxmox%20Scripts/create-ubuntu-cloud-template.sh
# - PVE Proxmox qm reference guide: https://pve.proxmox.com/pve-docs/qm.1.html
# This script is designed to be run inside the ProxMox VE host environment.
# It requires libguestfs-tools to be installed and it will install it, if not present.

echo "This script will create an Ubuntu VM Template for Proxmox."

source variables

# Check for a Proxmox system.
if ! pveversion &>/dev/null; then
  echo "This script is intended to run only on Proxmox. Exiting."
  exit 1
fi

# Install required packages.
# This script will use the virt-customize command from the libguestfs-tools package.
# It also uses wget to retrieve cloud images.
for pkg in "${required_packages[@]}"; do
  dpkg -l | grep -q "^ii  ${pkg} "
  if [ $? -ne 0 ]; then
    echo "Installing ${pkg}."
    sudo apt-get update && sudo apt-get -y install ${pkg}
  fi
done

# Set the VM ID.
if [ -z "${build_vm_id}" ]; then
  # The following command will get the next available ID, if you don't care what VMID is allocated:
  build_vm_id=$(pvesh get cluster/nextid)
else
  # Check if the VM ID is already in use.
  unset result
  result=$(pvesh get /cluster/resources --type vm --noborder | grep "qemu/113")
  if [ ! -z "${result}" ] ; then
    echo "VM ID ${build_vm_id} is already in use."
    exit
  fi
fi

# Enter the URL for the cloud-init image you would like to use and set the name of the template to be created.
declare -a dists
# Determine the last 3 Ubuntu LTS releases automatically.
IFS=$'\n'
for aline in $(wget -q -O - https://cloud-images.ubuntu.com/ | grep "LTS" | cut -f4-99 -d'-' | sed "s/daily builds//g" | sed "s/^[[:space:]]*//g" | sort -r | head -3 | sort | sed "s/)//g" | sed "s/(//g") ; do
  dists+=("${aline}")
done

echo "Choose an Ubuntu version:"

select version in "${dists[@]}"; do
	if [ -n "$version" ]; then
		((REPLY--))
		selected_version="${dists[$REPLY]}"
		break
	else
		echo "Invalid choice. Please select a valid option."
		exit 1
	fi
done

if [ -n "${selected_version}" ]; then
	distro_code_name=$(echo "${selected_version}"| awk '{print $5,$6}')
	distro_short_code_name=$(echo "${selected_version}"| awk '{print $5}')
	distro_version=$(echo "${selected_version}"| awk '{print $3}')
        distro_cloud_image="${distro_short_code_name,,}-server-cloudimg-amd64.img"
        cloud_image_url="https://cloud-images.ubuntu.com/${distro_short_code_name,,}/current/${distro_cloud_image}"
        template_name_default="ubuntu-${distro_version}-${distro_short_code_name,,}"
        echo "Selected Ubuntu version: ${version}"
else
        echo "Invalid choice, exiting."
	exit 1
fi

echo

# Prompt for user-defined variables
read -p "Enter a VM template name [${template_name_default}]: " template_name
template_name=${template_name:-$template_name_default}

cloud_user_default="devops" # User for cloud-init
read -p "Enter a Cloud-Init Username for ${template_name} [${cloud_user_default}]: " cloud_user
cloud_user=${cloud_user:-$cloud_user_default}

generated_password=$(date +%s | sha256sum | base64 | head -c 16 ; echo) # Random password generation
cloud_password_default=${generated_password}

read -p "Enter a Cloud-Init Password for ${template_name} [$cloud_password_default]: " cloud_password
cloud_password=${cloud_password:-$cloud_password_default}

echo

# Required packages to be installed in the VM template
template_package_list='cloud-init,cloud-utils,cloud-guest-utils,qemu-guest-agent'

# Get the name server from the Proxmox node.
# This assumes this is correctly set up on the Proxmox node.
if [ -z "${nameserver}" ] ; then
  nameserver=$(grep ^nameserver /etc/resolv.conf | tail -1 | awk '{print $2}')
fi

# Get the searchdomain from the Proxmox node.
# This assumes this is correctly set up on the Proxmox node.
if [ -z "${searchdomain}" ] ; then
  searchdomain=$(grep ^search /etc/resolv.conf | tail -1 | awk '{print $2}')
fi

# Grab latest cloud image for your selected image.
echo "Downloading ${cloud_image_url}."
rm -f ${cloud_image_url}
wget -q ${cloud_image_url}

if [ ! -s ${distro_cloud_image} ] ; then
  echo "Downloading cloud image ${cloud_image_url} failed."
  exit 1
fi

# Fix random seed warning message from virt-customize.
echo "Generate random-seed."
uuid=$(uuidgen)
mkdir -p /mnt/${uuid}
guestmount -a ${distro_cloud_image} -i --rw /mnt/${uuid}
cd /mnt/${uuid}/var/lib/systemd/
dd if=/dev/urandom of=random-seed bs=512 count=4 >/dev/null 2>&1
chmod 755 random-seed
cd - > /dev/null 2>&1
guestunmount /mnt/${uuid}
rm -rf /mnt/${uuid}

echo "Adding packages at build time: ${template_package_list}"
virt-customize --update --install ${template_package_list} -a ${distro_cloud_image}
if [ ! -z "${template_additional_package_list}" ] ; then
  echo "Adding additional packages at build time: ${template_additional_package_list}"
  virt-customize --update --install ${template_additional_package_list} -a ${distro_cloud_image}
fi

TZ="Europe/Amsterdam"
echo "Set the timezone to ${TZ}."
virt-customize -a ${distro_cloud_image} --timezone ${TZ}

# Create VM
echo "Creating VM ${build_vm_id}."
qm create ${build_vm_id} --memory ${vm_memory} --cores ${vm_cores} --net0 virtio,bridge=vmbr0 --name ${template_name} --pool Templates
echo "Importing disk image to storage location ${storage_location}."
qm importdisk ${build_vm_id} ${distro_cloud_image} ${storage_location} -format qcow2 2>&1 | grep -iv "transferred"
echo "Set storage target to ${storage_location}:${build_vm_id}/vm-${build_vm_id}-disk-0.qcow2."
qm set ${build_vm_id} --scsihw virtio-scsi-single --scsi0 ${storage_location}:${build_vm_id}/vm-${build_vm_id}-disk-0.qcow2,iothread=1
echo "Set OS type to Linux."
os_type="l26" # OS type (Linux 6x - 2.6 Kernel)
qm set ${build_vm_id} --ostype ${os_type}
echo "Define random number generator /dev/urandom."
qm set ${build_vm_id} --rng0 source=/dev/urandom
echo "Define cloudinit device."
qm set ${build_vm_id} --ide0 ${storage_location}:cloudinit
echo "Configure DNS settings to nameserver ${nameserver}, domain ${searchdomain}."
qm set ${build_vm_id} --nameserver ${nameserver} --searchdomain ${searchdomain}
echo "Create user and set password for user ${cloud_user}."
qm set ${build_vm_id} --ciuser ${cloud_user} --cipassword ${cloud_password}
if [ ! -z "${ssh_key}" ]; then
  echo "Configure SSH key."
  qm set ${build_vm_id} --sshkey <(echo "${ssh_key}")
fi
echo "Set boot disk."
qm set ${build_vm_id} --boot c --bootdisk scsi0
echo "Enable agent."
qm set ${build_vm_id} --agent enabled=1
disk_size="32G"
echo "Resize disk to ${disk_size}."
qm resize ${build_vm_id} scsi0 ${disk_size}
echo "Converting VM to template."
qm template ${build_vm_id} 2>&1 | grep -v chattr

# Deleting image
rm ${distro_cloud_image}

echo "Done. Template ${build_vm_id} ${template_name} created."

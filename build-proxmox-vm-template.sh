#!/bin/bash

# This script will download and modify the desired image and creates a VM Template in Proxmox.

# The script is inspired by these separate authors work:
# - Austins Nerdy Things: https://austinsnerdythings.com/2021/08/30/how-to-create-a-proxmox-ubuntu-cloud-init-image/
# - What the Server: https://whattheserver.com/proxmox-cloud-init-os-template-creation/
# - GeekTheGreyBeard: https://gtgb.io/ - https://github.com/geektx/Proxmox-VM-Template
# - Modem7: https://github.com/modem7/public_scripts/blob/master/Bash/Proxmox%20Scripts/create-ubuntu-cloud-template.sh
# - PVE Proxmox qm reference guide: https://pve.proxmox.com/pve-docs/qm.1.html
# - Dinodem: https://github.com/dinodem/terraform-proxmox/tree/mainhttps://github.com/dinodem/terraform-proxmox/tree/main

# This script is designed to be run inside the ProxMox VE host environment.
# It requires libguestfs-tools to be installed and it will install it, if not present.

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# Menu prompt
PS3="Enter a number: "

# Functions
print_message() {
  echo -e "${BLUE}==>${NC} $1"
}

print_step() {
  echo -e "\n${GREEN}===== $1 =====${NC}"
}

print_warning() {
  echo -e "${YELLOW}Warning:${NC} $1"
}

print_error() {
  echo -e "${RED}Error:${NC} $1"
}

check_success() {
  if [ $? -ne 0 ]; then
    print_error "$1"
    exit 1
  fi
}


# Main

clear
echo -e "${GREEN}=====================================${NC}"
echo -e "${GREEN}   Proxmox Template Creator Script   ${NC}"
echo -e "${GREEN}=====================================${NC}"
echo -e "\nThis script will help you create a VM template on your Proxmox server."
echo -e "You will be prompted for some configuration options."


# Source variables file.
source variables


print_step "Prerequisites check"


# Check for root user.
print_message "Checking for root user..."
if [ "$EUID" -ne 0 ]; then
  print_warning "This script needs to be run with sudo or as root."
  echo -e "Please run it again with: ${YELLOW}sudo $0${NC}"
  exit 1
fi


# Check for a Proxmox system.
print_message "Checking for Proxmox system..."
if ! pveversion &>/dev/null; then
  print_warning "This script is intended to run only on Proxmox. Exiting."
  exit 1
fi


# Install required packages.
# This script will use the virt-customize command from the libguestfs-tools package.
# It also uses wget to retrieve cloud images.
print_message "Checking for required packages..."
for pkg in "${required_packages[@]}"; do
  dpkg -l | grep -q "^ii  ${pkg} "
  if [ $? -ne 0 ]; then
    echo "Installing ${pkg}."
    sudo apt-get update && sudo apt-get -y install ${pkg}
    check_success "Failed to install ${pkg}."
  else
    print_message "Package ${pkg} already installed."
  fi
done


print_step "Configuration options"


declare -a storages
IFS=$'\n'
for line in $(pvesm status | grep active | grep -v ^local | awk '{print $1}') ; do
  storages+=("${line}")
done

echo "Choose one of the available storages in Proxmox:"
select storage in "${storages[@]}"; do
  if [ -n "${storage}" ]; then
    ((REPLY--))
    storage_location="${storages[$REPLY]}"
    break
  else
    echo "Invalid choice. Please select a valid option."
    exit 1
  fi
done
print_message "Using storage: ${storage_location}"


# Set the VM ID.
if [ -z "${build_vm_id}" ]; then
  # The following command will get the next available ID, if you don't care what VMID is allocated:
  build_vm_id=$(pvesh get cluster/nextid)
fi

read -p "Enter VM ID for the template [default: ${build_vm_id}]: " user_vm_id
user_vm_id=${user_vm_id:-$build_vm_id}
build_vm_id=${user_vm_id}
if ! [[ "${build_vm_id}" =~ ^[0-9]+$ ]] ; then
  print_warning "VM ID value \"${build_vm_id}\" is not a valid numerical value."
  exit 1
fi
# Check if the VM ID is between 100 to 1000000.
if (( build_vm_id < 100 || build_vm_id > 1000000 )) ; then
  print_warning "VM ID should be a number between 100 to 1000000."
  exit 1
fi
# Check if the VM ID is already in use.
unset result
result=$(pvesh get /cluster/resources --type vm --noborder | grep "qemu/${build_vm_id}")
if [ ! -z "${result}" ] ; then
  print_warning "VM ID ${build_vm_id} is already in use."
  exit 1
fi
print_message "Using VM ID: ${build_vm_id}"


# Choose OS version.
declare -a dists
# Determine the last 3 Ubuntu LTS releases automatically.
IFS=$'\n'
for line in $(wget -q -O - https://cloud-images.ubuntu.com/ | grep "LTS" | cut -f4-99 -d'-' | sed "s/daily builds//g" | sed "s/^[[:space:]]*//g" | sort -r | head -3 | sort | sed "s/)//g" | sed "s/(//g") ; do
  dists+=("${line}")
done

echo "Choose an OS version:"

select version in "${dists[@]}"; do
  if [ -n "${version}" ]; then
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
  print_message "Using OS version: ${selected_version}"
else
  print_warning "Invalid choice, exiting."
  exit 1
fi


# Get template name.
unset template_name
read -p "Enter a VM template name [${template_name_default}]: " template_name
template_name=${template_name:-$template_name_default}
if [ -z "${template_name}" ] ; then
  print_warning "VM template name can not be blank."
  exit 1
fi
unset result
result=$(pvesh get /cluster/resources --type vm --noborder --output-format=yaml | grep "  name: " | awk '{print $2}' | grep -i "${template_name}")
if [ ! -z "${result}" ] ; then
  print_warning "VM template name \"${template_name}\" already exists."
  exit 1
fi
print_message "Template name: ${template_name}"


# Memory.
if [ -z "${vm_memory}" ] ; then
	default_memory=2048
else
	default_memory=${vm_memory}
fi
read -p "Enter memory size in MB [default: ${default_memory}]: " user_memory
user_memory=${user_memory:-$default_memory}
if ! [[ "${user_memory}" =~ ^[0-9]+$ ]] ; then
  print_warning "Memory size value \"${user_memory}\" is not a valid numerical value."
  exit 1
fi
# Check if the memory size is at least 1024.
if (( user_memory < 1024 )) ; then
  print_warning "Memory size should be at least 1024 MB."
  exit 1
fi
vm_memory=${user_memory}
print_message "Using memory size: ${vm_memory}"


# Cores.
if [ -z "${vm_cores}" ] ; then
	default_cores=1
else
	default_cores=${vm_cores}
fi
read -p "Enter number of CPU cores [default: ${default_cores}]: " user_cores
user_cores=${user_cores:-$default_cores}
if ! [[ "${user_cores}" =~ ^[0-9]+$ ]] ; then
  print_warning "Cores value \"${user_cores}\" is not a valid numerical value."
  exit 1
fi
# Check if the number of cores is at least 1.
if (( user_cores < 1 )) ; then
  print_warning "The number of cores should be at least 1."
  exit 1
fi
vm_cores=${user_cores}
print_message "Using number of cores: ${vm_cores}"


# Get default user.
unset cloud_user
read -p "Enter a user account [${cloud_user_default}]: " cloud_user
cloud_user=${cloud_user:-$cloud_user_default}
if [ -z "${cloud_user}" ] ; then
  print_warning "User name can not be blank."
  exit 1
fi
print_message "Using user name: ${cloud_user}"


# Get password for Cloud-Init user.
generated_password=$(date +%s | sha256sum | base64 | head -c 16 ; echo) # Random password generation
cloud_password_default=${generated_password}

unset cloud_password
read -p "Enter a password [${cloud_password_default}]: " cloud_password
cloud_password=${cloud_password:-$cloud_password_default}
if [ -z "${cloud_password}" ] ; then
  print_warning "Password can not be blank."
  exit 1
fi
print_message "Using password: ${cloud_password}"


# Get the name server.
# This assumes this is correctly set up on the Proxmox node.
if [ -z "${nameserver_default}" ] ; then
  nameserver_default=$(grep "^nameserver" /etc/resolv.conf | tail -1 | awk '{print $2}')
fi

unset nameserver
read -p "Enter the DNS nameserver [${nameserver_default}]: " user_nameserver
nameserver=${user_nameserver:-$nameserver_default}
if [ -z "${nameserver}" ] ; then
  print_warning "DNS nameserver can not be blank."
  exit 1
fi
print_message "Using DNS nameserver: ${nameserver}"


# Get the searchdomain.
# This assumes this is correctly set up on the Proxmox node.
if [ -z "${searchdomain_default}" ] ; then
  searchdomain_default=$(grep ^search /etc/resolv.conf | tail -1 | awk '{print $2}')
fi

unset searchdomain
read -p "Enter the DNS searchdomain [${searchdomain_default}]: " user_searchdomain
searchdomain=${user_searchdomain:-$searchdomain_default}
if [ -z "${searchdomain}" ] ; then
  print_warning "DNS searchdomain can not be blank."
  exit 1
fi
print_message "Using DNS searchdomain: ${searchdomain}"


print_step "Review configuration"

echo -e "Please review your settings:"
echo -e "  Storage:          ${YELLOW}${storage_location}${NC}"
echo -e "  VM ID:            ${YELLOW}${build_vm_id}${NC}"
echo -e "  Template name:    ${YELLOW}${template_name}${NC}"
echo -e "  OS version:       ${YELLOW}${selected_version}${NC}"
echo -e "  Memory:           ${YELLOW}${vm_memory} MB${NC}"
echo -e "  CPU cores:        ${YELLOW}${vm_cores}${NC}"
echo -e "  Username:         ${YELLOW}${cloud_user}${NC}"
echo -e "  Password:         ${YELLOW}${cloud_password}${NC}"
echo -e "  DNS nameserver:   ${YELLOW}${nameserver}${NC}"
echo -e "  DNS searchdomain: ${YELLOW}${searchdomain}${NC}"
echo ""

read -p "Do you want to proceed with these settings? (y/n) [default: y]: " CONFIRM
CONFIRM=${CONFIRM:-y}

if [[ ${CONFIRM} != [Yy]* ]]; then
    print_message "Template creation cancelled."
    exit 0
fi


print_step "Configuring cloud image"

# Grab latest cloud image for your selected image.
print_message "Downloading ${cloud_image_url}..."
rm -f ${cloud_image_url}
wget -q ${cloud_image_url}
check_success "Failed to download the cloud image."
if [ ! -s ${distro_cloud_image} ] ; then
  print_warning "Downloading cloud image ${cloud_image_url} failed."
  exit 1
fi


# Fix random seed warning message from virt-customize.
print_message "Generating random-seed..."
uuid=$(uuidgen)
mkdir -p /mnt/${uuid}
guestmount -a ${distro_cloud_image} -i --rw /mnt/${uuid}
cd /mnt/${uuid}/var/lib/systemd/
dd if=/dev/urandom of=random-seed bs=512 count=4 >/dev/null 2>&1
chmod 755 random-seed
cd - > /dev/null 2>&1
guestunmount /mnt/${uuid}
rm -rf /mnt/${uuid}

print_message "Adding packages at build time: ${template_package_list}..."
virt-customize --update --install ${template_package_list} -a ${distro_cloud_image}
check_success "Failed to install ${template_package_list}."
if [ ! -z "${template_additional_package_list}" ] ; then
  print_message "Adding additional packages at build time: ${template_additional_package_list}"
  virt-customize --update --install ${template_additional_package_list} -a ${distro_cloud_image}
  check_success "Failed to install ${template_additional_package_list}."
fi


# Timezone.
TZ=$(cat /etc/timezone)
print_message "Setting timezone to ${TZ}..."
virt-customize -a ${distro_cloud_image} --timezone ${TZ}
check_success "Failed to set timezone to ${TZ}."


# Machine ID
print_message "Clearing machine ID..."
virt-customize -a ${distro_cloud_image} --truncate /etc/machine-id  
check_success "Failed clearing machine ID."


print_step "Creating VM template ${build_vm_id}"


# Create VM.
print_message "Creating VM..."
qm create ${build_vm_id} --memory ${vm_memory} --cores ${vm_cores} --net0 virtio,bridge=vmbr0 --name ${template_name} --pool ${default_pool} --ipconfig0 ip=dhcp
check_success "Failed to create VM."

print_message "Importing disk image to storage location ${storage_location}..."
qm importdisk ${build_vm_id} ${distro_cloud_image} ${storage_location} -format qcow2 2>&1 | grep -iv "transferred"
check_success "Failed to import disk image."

print_message "Setting storage target to ${storage_location}:${build_vm_id}/vm-${build_vm_id}-disk-0.qcow2..."
qm set ${build_vm_id} --scsihw virtio-scsi-single --scsi0 ${storage_location}:${build_vm_id}/vm-${build_vm_id}-disk-0.qcow2,iothread=1
check_success "Failed to configure disk."

print_message "Setting OS type to Linux..."
os_type="l26" # OS type (Linux 6x - 2.6 Kernel)
qm set ${build_vm_id} --ostype ${os_type}
check_success "Failed to configure OS type."

print_message "Defining random number generator /dev/urandom..."
qm set ${build_vm_id} --rng0 source=/dev/urandom
check_success "Failed to define random number generator."

print_message "Configuring serial console..."
qm set ${build_vm_id} --serial0 socket --vga serial0
check_success "Failed to configure serial console."

print_message "Defining cloudinit device..."
qm set ${build_vm_id} --ide0 ${storage_location}:cloudinit
check_success "Failed to add cloudinit device."

print_message "Configuring DNS settings to nameserver ${nameserver}, domain ${searchdomain}..."
qm set ${build_vm_id} --nameserver ${nameserver} --searchdomain ${searchdomain}
check_success "Failed to configure DNS settings."

print_message "Creating user and setting password for user ${cloud_user}..."
qm set ${build_vm_id} --ciuser ${cloud_user} --cipassword ${cloud_password}
check_success "Failed to configur user ${cloud_user}."

print_message "Configuring SSH keys..."
qm set ${build_vm_id} --ciuser ${cloud_user} --sshkeys keyfile
check_success "Failed to configure SSH keys."

print_message "Setting boot disk..."
qm set ${build_vm_id} --boot c --bootdisk scsi0
check_success "Failed to configure boot disk."

print_message "Enabling agent..."
qm set ${build_vm_id} --agent enabled=1
check_success "Failed to enable qemu-guest-agent."

disk_size="32G"
print_message "Resizing disk to ${disk_size}..."
qm resize ${build_vm_id} scsi0 ${disk_size}
check_success "Failed to resize disk."

print_message "Converting VM to template..."
qm template ${build_vm_id} 2>&1 | grep -v chattr
echo "VM converted to template."
# not checking the success status; qm template may always generate an error if it is unable to set the immutable flag.

# Deleting image.
print_message "Cleaning up..."
rm ${distro_cloud_image}
check_success "Failed to clean up files."

print_step "VM template created"
echo -e "VM template has been created successfully!"
echo -e "Template ID:   ${YELLOW}${build_vm_id}${NC}"
echo -e "Template name: ${YELLOW}${template_name}${NC}"
echo -e "OS version:    ${YELLOW}${selected_version}${NC}"

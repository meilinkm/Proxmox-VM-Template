#!/bin/sh

# This script will download and modify the desired image to prep for VM template build.
# The script is inspired by these separate authors work:
# - Austins Nerdy Things: https://austinsnerdythings.com/2021/08/30/how-to-create-a-proxmox-ubuntu-cloud-init-image/
# - What the Server: https://whattheserver.com/proxmox-cloud-init-os-template-creation/
# - https://gtgb.io/ - https://github.com/geektx/Proxmox-VM-Template
# - https://github.com/modem7/public_scripts/blob/master/Bash/Proxmox%20Scripts/create-ubuntu-cloud-template.sh
# - PVE Proxmox qm reference guide: https://pve.proxmox.com/pve-docs/qm.1.html
# This script is designed to be run inside the ProxMox VE host environment.
# It requires libguestfs-tools to be installed and it will install it, if not present.

echo "Script $0 started."
echo "This script will create an Ubuntu VM Template for Proxmox."

# Check for a Proxmox system.
if ! pveversion &>/dev/null; then
	echo "This script is intended to run only on Proxmox. Exiting."
	exit 1
fi

# Install required packages.
REQUIRED_PKG=("libguestfs-tools" "wget")
for pkg in "${REQUIRED_PKG[@]}"; do
	dpkg -l | grep -q "^ii  ${pkg} "
        if [ $? -ne 0 ]; then
		echo "Installing ${pkg}."
		sudo apt-get update && sudo apt-get -y install ${pgk}
        fi
done

# Change this line to reflect the VMID you would like to use for the template.
# Select an ID such as 9999 that will be unique to the node.
#build_vm_id='ENTER-VMID-FOR-TEMPLATE'
# The following command will get the next available ID, if you don't care what VMID is allocated:
build_vm_id=$(pvesh get cluster/nextid)

# Determine the install_dir automatically:
install_dir="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"

# SSH key to be used.
# Comment it out, if you don't want to use it.
SSH_KEY="ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQCm4/5GC+w/BPIU5fbwT/wAc69PN0/n2SApUQmu5dUBC6PMoFqpgczPhcMNTgj+Z1fcXWdo6Bfu0Sm3q3CVT7la0r4fc/j550kZ7ay7Y4dwxOCw77NSBmTpuessk2+U48oxObxoKdVsLxnle3tgYjbSBIaLcB/LUXzUzQnxMS2ZgEtbJjG0fjvSTG3u+LaVr4ORXIGJWB3vvyxfYOARGA9W8JEviknHbVCOxurEmAQDvVTlcEEpCLDNNexWD7PNW/QEs9aQR59f1NORfPkrf/vXoikPkNh8Pr3jt1JUDY8wgms45SxClO0K62CigSHe5Mw2zoaGijpR6JlFi/Y3dDt6ZCicqechoiEhlCQAr9sIbGLP2nRoKv0y2c6G9Ade0RjRhB+FMp220fcDMdREb5Pzbju1kxZkz76eYwIN/Rs4TTKS1kEDp86tCZbEiqQuBv/EL5vDVtIYVqKApVwfoHOckDAUkTfoo+Wv4rG6iY15ys2LDWMR05XPFUO0NWHuLWk= meilinkm@enemigo"

# Enter the URL for the cloud-init image you would like to use and set the name of the template to be created.
declare -a dists
dists+=("Ubuntu 18.04 Bionic Beaver")
dists+=("Ubuntu 20.04 Focal Fossa")
dists+=("Ubuntu 22.04 Jammy Jellyfish")
dists+=("Ubuntu 24.04 Noble Numbat")

echo "Choose an Ubuntu version:"

select version in "${dists[@]}"; do
        if [ -n "$version" ]; then
            selected_version="${dists[$REPLY]}"
            break
        else
            echo "Invalid choice. Please select a valid option."
        fi
    done

if [ -n "${selected_version}" ]; then
	DISTRO_CODE_NAME=$(echo "${selected_version}"| awk '{print $3,$4}')
	DISTRO_SHORT_CODE_NAME=$(echo "${selected_version}"| awk '{print $3}')
	DISTRO_VERSION=$(echo "${selected_version}"| awk '{print $2}')
        DISTRO_CLOUD_IMAGE="${DISTRO_SHORT_CODE_NAME,,}-server-cloudimg-amd64.img"
        CLOUD_IMAGE_URL="https://cloud-images.ubuntu.com/${DISTRO_SHORT_CODE_NAME,,}/current/${DISTRO_CLOUD_IMAGE}"
        TEMPLATE_NAME_DEFAULT="ubuntu-${DISTRO_VERSION}-${DISTRO_CODE_NAME,,}"
        echo "Selected Ubuntu version: ${version}"
else
        echo "Invalid choice, exiting."
fi

# Enter the additional packages you would like in your template.
package_list='cloud-init,qemu-guest-agent,curl,wget,vim,iputils-ping,netcat-openbsd'

# What storage location on your PVE node do you want to use for the template? (zfs-mirror, local-lvm, local, etc.)
storage_location='nfs'

# Get the name server from the Proxmox node.
# This assumes this is correctly set up on the Proxmox node.
nameserver=$(grep ^nameserver /etc/resolv.conf | tail -1 | awk '{print $2}')

# Your domain (ie, domain.com, domain.local, domain).
# This assumes this is correctly set up on the Proxmox node.
searchdomain=$(grep ^search /etc/resolv.conf | tail -1 | awk '{print $2}')

# Username for accessing the image.
cloud_init_user='devops'

# Set the SCSI Controller Model.
scsihw='virtio-scsi-single'

# Memory and CPU cores. These are overridden with VM deployments or through the PVE interface.
vm_mem='2048'
vm_cores='1'

# Grab latest cloud image for your selected image.
echo "Downloading ${CLOUD_IAMGE_URL}."
wget ${CLOUD_IMAGE_URL}

if [ ! -s ${DISTRO_CLOUD_IMAGE} ] ; then
	echo "Downloading cloud image ${CLOUD_IMAGE_URL} failed."
	exit 1
fi


#UPDATE make sure the template is created in the Templates pool  - eigenlijk nog beter - maak de Templates pool als die niet bestaat
echo "Packages added at build time: ${package_list}"
virt-customize --update -a ${DISTRO_CLOUD_IMAGE}
exit
virt-customize --install ${package_list} -a ${DISTRO_CLOUD_IMAGE}
qm create ${build_vm_id} --memory ${vm_mem} --cores ${vm_cores} --net0 virtio,bridge=vmbr0 --name ${template_name}
qm importdisk ${build_vm_id} ${image_name} ${storage_location}
qm set ${build_vm_id} --scsihw ${scsihw} --scsi0 ${storage_location}:vm-${build_vm_id}-disk-0
qm set ${build_vm_id} --ide0 ${storage_location}:cloudinit
qm set ${build_vm_id} --nameserver ${nameserver} --ostype l26 --searchdomain ${searchdomain} --ciuser ${cloud_init_user}
if [ ! -z "${SSH_KEY}" ]; then
    qm set ${build_vm_id} --sshkey <(echo "${SSH_KEY}")
fi
qm set ${build_vm_id} --boot c --bootdisk scsi0
qm set ${build_vm_id} --agent enabled=1
qm template ${build_vm_id}

# Deleting image
rm ${DISTRO_CLOUD_IMAGE}

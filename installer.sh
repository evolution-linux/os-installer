#!/bin/bash

if [[ $(id -u) -eq 0 ]]; then
  :
else
  dialog --title "Run as root" --msgbox "Please run the installer as root!" 0 0
  exit 1
fi

if [[ -x /sys/firmware/efi ]]; then
  uefi=true
else
  uefi=false
fi

dialog --clear --title "Launguage" --menu "Select a language:" 15 50 10 "en_GB" "English UK" "en_US" "English US"

if [[ $? = 1 ]]; then
     exit 1
fi

dialog --title "Welcome" --msgbox "Welcome to the EvolutionOS installer! \n\nThis installer is meant to be straightforward, no need for technical skill. \n\nPress enter to select buttons, tab to move between text boxes, and left / right to move between buttons." 0 0

get_disk_type() {
  local disk_name="$1"
  
  if [[ "$disk_name" =~ ^sd.$ ]]; then
    echo "Hard Disk $(echo "${disk_name: -1}" | tr '[:lower:]' '[:upper:]')"
  elif [[ "$disk_name" =~ ^emmc.+$ ]]; then
    echo "Internal Memory $(echo "${disk_name: -1}" | tr '[:lower:]' '[:upper:]')"
  elif [[ "$disk_name" =~ ^nvme.+$ ]]; then
    echo "SSD $(echo "${disk_name: -1}" | tr '[:lower:]' '[:upper:]')"
  elif [[ "$disk_name" =~ ^fd.+$ ]]; then
    echo "Floppy Disk $(echo "${disk_name: -1}" | tr '[:lower:]' '[:upper:]')"
  elif [[ "$disk_name" =~ ^sr.$ ]]; then
    echo "Disk Drive $(echo "${disk_name: -1}" | tr '[:lower:]' '[:upper:]')"
  else
    echo "Unknown"
  fi
}

# Getting the disk names using lsblk and awk

disk_names=$(lsblk --list --nodeps -o NAME | awk 'NR>1')

# Function to check if the disk is writable
is_disk_writable() {
  local disk_name="$1"
  touch "/mnt/$disk_name" &>/dev/null
  local writable=$?
  rm "/mnt/$disk_name" &>/dev/null
  return $writable
}

# Loop through each disk name and determine its type
while true; do
  # Creating the list for dialog
  list=()
  for disk_name in $disk_names; do
    disk_type=$(get_disk_type "$disk_name")
    list+=( "$disk_name" "$disk_type" )
  done

  # Using dialog to display the list
  dialog --clear --title "Disk List" --menu "Select a disk:" 15 50 10 "${list[@]}" 2>/tmp/disk_choice

   if [[ $? = 1 ]]; then
     exit 1
   fi

  # Reading the choice made by the user
  choice=$(cat /tmp/disk_choice)
  rm /tmp/disk_choice

  # Check if the disk is writable
  if ! is_disk_writable "$choice"; then
    dialog --title "Disk Not Writable" --msgbox "The selected disk is not writable. Please choose another disk." 8 50
    continue
  fi

  # Check if the disk has partitions
  partitions=$(lsblk "/dev/$choice" | grep -c "part")
  if [ "$partitions" -gt 0 ]; then
    dialog --title "Disk with Partitions" --yesno "The selected disk contains data. Do you want to wipe the disk?" 8 50
    response=$?
    if [ "$response" -eq 0 ]; then
      # User chose Yes, proceed to wipe the disk
      # Add your wipe disk command here
      echo "Ok, continuing with: $choice"
      break
    else
      # User chose No, return to the selection menu
      continue
    fi
  else
    # Disk has no partitions, continue with further actions
    echo "Ok, continuing with: $choice"
    # Add your additional actions here
    # ...
  fi

  # Break out of the loop if the user didn't choose to wipe the disk and there are no partitions
  break
done

for i in $(lsblk --list -o NAME /dev/$choice | awk 'NR>2'); do
  umount /dev/$i
done

sfdisk --delete /dev/$choice
wipefs -a /dev/$choice
sgdisk -Z /dev/$choice

dialog --yesno "Would you like to use the recommended disk partitioning?" 0 0
if [[ $? = 0 ]]; then
  dialog --msgbox "Starting partitioning..." 0 0
  if [[ $uefi = true ]]; then
    sfdisk -X gpt -W always /dev/$choice <<EOF
, 200M
, ,
EOF
    fdisk /dev/$choice <<EOF
t
1
EOF
    part1=$(lsblk -n -o NAME --list /dev/$choice | sed -n '2p')
    part2=$(lsblk -n -o NAME --list /dev/$choice | sed -n '3p')
    mkfs.fat -F 32 /dev/$part1
    dialog --clear --title "Filesystem Type" --menu "Select a filesystem:" 0 0 0  "ext4" "Basic file system (recommended)" "btrfs" "Great for data recovery" "xfs" "High performence, but may need extra RAM" 2>/tmp/fileselect
    if [[ $? = 1 ]]; then
      dialog --msgbox "Operation cancled"
      exit 1
    fi
    filesystem=$(cat /tmp/fileselect)
    mkfs.$filesystem /dev/$part2 | dialog --title "Creating file system..." --programbox 24 80
    mount /dev/$part2 /mnt
    mkdir -p /mnt/boot/efi
    mount /dev/$part1 /mnt/boot/efi
  else
    echo -e "o\nw" | fdisk /dev/$choice
    sfdisk -X mbr -W always /dev/$choice <<EOF
, ,
EOF
    dialog --clear --title "Filesystem Type" --menu "Select a filesystem:" 0 0 0 "ext4" "Basic file system (recommended)" "btrfs" "Great for data recovery" "xfs" "High performence, but may need extra RAM" 2>/tmp/fileselect
    if [[ $? = 1 ]]; then
      dialog --msgbox "Operation cancled"
      exit 1
    fi
    filesystem=$(cat /tmp/fileselect)
    partmpt1=$(lsblk -n -o NAME --list /dev/$choice | sed -n '2p')
    mkfs.$filesystem /dev/$part1 | dialog --title "Creating file system..." --programbox 24 80
  fi
else
  dialog --msgbox "Ok, you will be dropped into a CLI. Please mount the filesystem, when done, at \"/mnt/\". Note that anything except the default partition disk (ESP, Optional Swap, RootFS) is not offically supported and may not work. Enter exit when you are done." 0 0
  bash
  dialog --msgbox "Welcome back! Continuing installation..." 0 0
fi

for f in sys proc dev; do
  [ ! -d /mnt/$f ] && mkdir /mnt/$f
  echo "Mounting /mnt/$f..."
  mount --rbind /$f /mnt/$f
done

dialog --clear --title "Select install type" --menu "Which installation type would you like to you:" 0 0 0 "local" "Install without internet" "network" "Download from internet" 2>/tmp/installtype
installtype=$(cat /tmp/installtype)

if [ $uefi = true ]; then
    if [ $(uname -m) = "i686" ]; then
        _grub="grub-i386-efi"
    else
        _grub="grub-x86_64-efi"
    fi
else
    _grub="grub"
fi
  
mkdir -p /mnt/var/db/xbps/keys /mnt/usr/share
cp -a /usr/share/xbps.d /mnt/usr/share/
cp /var/db/xbps/keys/*.plist /mnt/var/db/xbps/keys
mkdir -p /mnt/boot/grub

if [[ $installtype = "local" ]]; then
  xbps-install -S -y -r /mnt -i -R /var/cache/xbps/ base-system $_grub | dialog --title "Installing base system..." --programbox 24 80
else
  xbps-install -S -y -r /mnt -R https://evolution-linux.github.io/pkg base-system $_grub | dialog --title "Installing base system..." --programbox 24 80
fi

xbps-reconfigure -r /mnt -f base-system
chroot /mnt xbps-reconfigure -fa | dialog --title "Reconfiguring packages..." --programbox 24 80

while true; do
  dialog --title "Password" --clear --insecure --passwordbox "Enter Admin (root) password. For security reasons, you cannot log in as admin. Press enter to submit." 0 0 2>/tmp/rootpasswd
  rootpasswd="$(cat /tmp/rootpasswd)"
  passwd -R /mnt <<EOF
$rootpasswd
$rootpasswd
EOF
  if [[ $? = 1 ]]; then
    dialog --title "Illegal characters" --msgbox "You cannot have those characters in a password. Please enter a new one."
    continue
  else
    break
  fi
done

while true; do
  dialog --title "Username" --clear --inputbox "Enter shorthand username. This will be created as an super user (able to run as root)." 0 0 2>/tmp/usershort
  shusername="$(cat /tmp/usershort)"
  useradd -R /mnt -m $shusername
  if [[ $? = 1 ]]; then
    dialog --title "Illegal characters" --msgbox "You cannot have those characters in a shorthand username. Please enter a new one."
    continue
  else
    break
  fi
done

dialog --title "Username" --clear --inputbox "Enter display username." 0 0 2>/tmp/dpusername
dpusername=$(cat /tmp/dpusername)
while true; do
  dialog --title "Password" --clear --insecure --passwordbox "Enter user password" 0 0 2>/tmp/userpasswd
  userpasswd="$(cat /tmp/userpasswd)"
  passwd -R /mnt <<EOF
$userpasswd
$userpasswd
EOF
  if [[ $? = 1 ]]; then
    dialog --title "Illegal characters" --msgbox "You cannot have those characters in a password. Please enter a new one."
    continue
  else
    break
  fi
done

chroot /mnt chfn -f $dpusername $shusername
chroot /mnt usermod -a -G video $shusername

dialog --title "Done!" --msgbox "Hello, and welcome to my minceraft tutorial"

#!/usr/bin/env bash
# shellcheck disable=SC1083,SC2054,SC2121
#--------------------------------------------------------------------------------------------------
# Github: https://github.com/007revad/Synology_HDD_db
# Script verified at https://www.shellcheck.net/
# Tested on DSM 7.1.1 and DSM 6.2.4
#
# Easiest solution:
# Edit /etc.defaults/synoinfo.conf and change support_disk_compatibility="yes" to "no" and reboot.
# Then all drives can be used without error messages.
#
# But lets do this the proper way by adding our drive models to the appropriate .db file.
#
# To run in task manager as root (manually or scheduled):
# /volume1/scripts/syno_hdd_db.sh  # replace /volume1/scripts/ with path to script
#
# To run in a shell (replace /volume1/scripts/ with path to script):
# sudo /volume1/scripts/syno_hdd_db.sh
#  or
# sudo /volume1/scripts/syno_hdd_db.sh -showedits
#  or
# sudo /volume1/scripts/syno_hdd_db.sh -force -showedits
#--------------------------------------------------------------------------------------------------

# TODO
# Bypass M.2 volume lock for unsupported M.2 drives.
#
# Detect if expansion unit(s) connected and get model(s) and edit expansion unit db files.
#   Or add support for specifying user's expansion unit model(s) as arguments.
#   Or maybe use the shotgun approach and update all expansion unit db files.
#
# Maybe also edit the other disk compatibility db in synoboot, used during boot time.
# It's also parsed and checked and probably in some cases it could be more critical to patch that one instead.

# DONE
# Added support for M.2 drives on a PCI card (M2Dxx and E10G18-T1 and future models).
#
# Improved flags/options checking and added usage help.
#
# Can now download the latest script version for you (if you have user home service enabled in DSM).
#
# Now adds 'support_m2_pool="yes"' line for models that don't have support_m2_pool in synoinfo.conf
#   to (hopefully) prevent losing your SSH created M2 volume when running this script on models 
#   that DSM 7.2 Beta does not list as supported for creating M2 volumes.
#
# Changed Synology model detection to be more reliable (for models that came in different variations).
#
# Changed checking drive_db_test_url setting to be more durable.
#
#
# Added check that M.2 volume support is enabled (on supported models).
#
# Added support for M.2 SATA drives.
#
# Can now skip processing M.2 drives by running script with the -m2 flag.
#
# Changed method of getting drive and firmware version so script is faster and easier to maintain.
# - No longer using smartctl or hdparm.
#
# Changed SAS drive firmware version detection to support SAS drives that hdparm doesn't work with.
#
# Removed error message and aborting if *.db.new not found (clean DSM installs don't have a *.db.new).
#
# Force DSM to check disk compatibility so reboot not needed (DSM 6 may still need a reboot).
#
# Fixed DSM 6 issue when DSM 6 has the old db file format.
#
# Add support for SAS drives.
#
# Get HDD/SSD/SAS drive model number with smartctl instead of hdparm.
#
# Check if there is a newer script version available.
#
# Add support for NVMe drives.
#
# Prevent DSM auto updating the drive database.
#
# Optionally disable "support_disk_compatibility".


scriptver="v1.1.15"
script=Synology_HDD_db
repo="007revad/Synology_HDD_db"


# Shell Colors
#Black='\e[0;30m'
Red='\e[0;31m'
#Green='\e[0;32m'
Yellow='\e[0;33m'
#Blue='\e[0;34m'
#Purple='\e[0;35m'
Cyan='\e[0;36m'
#White='\e[0;37m'
Error='\e[41m'
Off='\e[0m'


usage(){
    cat <<EOF
$script $scriptver - by 007revad

Usage: $(basename "$0") [options]

Options:
  -s, --showedits  Show the edits made to host db file(s)
  -n, --noupdate   Prevent DSM updating the compatible drive databases
  -m, --m2         Don't process M.2 drives
  -f, --force      Force DSM to not check drive compatibility
  -r, --ram        Disable memory compatibility checking
  -h, --help       Show this help message
  -v, --version    Show the version
  
EOF
exit 0
}


scriptversion(){
    cat <<EOF
$script $scriptver
by 007revad
https://github.com/$repo
EOF
exit 0
}


# Check for flags with getopt
options="$(getopt -o abcdefghijklmnopqrstuvwxyz0123456789 -a \
    -l showedits,noupdate,m2,force,ram,help,version -- "$@")"
if [[ $? -eq "0" ]]; then
    eval set -- "$options"
    while true; do
        case "${1,,}" in
            -s|--showedits)     # Show edits done to host db file
                showedits=yes
                ;;
            -n|--nodbupdate)    # Disable disk compatibility db updates
                nodbupdate=yes
                ;;
            -m|--m2)            # Don't add M.2 drives to db files
                m2=no
                ;;
            -f|--force)         # Disable "support_disk_compatibility"
                force=yes
                ;;
            -r|--ram)           # Include memory compatibility
                ram=yes         # for future use
                ;;
            -h|--help)          # Show usage options
                usage
                ;;
            -v|--version)       # Show script version
                scriptversion
                ;;
            --)
                shift
                break
                ;;
            *)                  # Show usage options
                echo "Invalid option '$1'"
                usage "$1"
                ;;
        esac
        shift
    done
fi


# Check script is running as root
if [[ $( whoami ) != "root" ]]; then
    echo -e "${Error}ERROR${Off} This script must be run as root or sudo!"
    exit 1
fi

# Get DSM major version
dsm=$(get_key_value /etc.defaults/VERSION majorversion)
if [[ $dsm -gt "6" ]]; then
    version="_v$dsm"
fi

# Get Synology model
model=$(cat /proc/sys/kernel/syno_hw_version)  # not always the actual model number

modeltype=$(printf "%s" "$model" | sed 's/[0-9].*//')  # DS, RS etc

unique=$(get_key_value /etc/synoinfo.conf unique | cut -d'_' -f3)  # 920+ etc

# Remove extra text from end, like DS213pv10-j and DS1817+-j
#[[ $model =~ ([0-9]{3,}) ]] && modelnum=${BASH_REMATCH[1]}
[[ $model =~ ([0-9]{3,}(RP\+|RPxs|RP|\+II|xsII|xs\+|xs|\+|j|slim|play|se|air|D)?) ]] &&\
    modelnum=${BASH_REMATCH[1]}

if [[ $modelnum != "$unique" ]]; then
    model="$modeltype$unique"
fi

model=${model,,}  # convert to lower case


#------------------------------------------------------------------------------
# Check latest release with GitHub API

get_latest_release() {
    curl --silent "https://api.github.com/repos/$1/releases/latest" |
    grep '"tag_name":' |          # Get tag line
    sed -E 's/.*"([^"]+)".*/\1/'  # Pluck JSON value
}

tag=$(get_latest_release "007revad/Synology_HDD_db")
shorttag="${tag:1}"

if [[ $HOME =~ /var/services/* ]]; then
    shorthome=${HOME:14}
else
    shorthome="$HOME"
fi

if ! printf "%s\n%s\n" "$tag" "$scriptver" |
        sort --check --version-sort &> /dev/null ; then
    echo -e "${Cyan}There is a newer version of this script available.${Off}"
    echo -e "Current version: ${scriptver}\nLatest version:  $tag"
    if [[ ! -d $HOME ]]; then
        # Can't download to home
        echo "https://github.com/$repo/releases/latest"
        sleep 10
    elif [[ -f $HOME/$script-$shorttag.tar.gz ]]; then
        # Latest version tar.gz in home but they're using older version
        echo "https://github.com/$repo/releases/latest"
        sleep 10
    else
        echo -e "${Cyan}Do you want to download $tag now?${Off} {y/n]"
        read -r -t 30 reply
        if [[ ${reply,,} == "y" ]]; then
            if ! curl -LJO "https://github.com/$repo/archive/refs/tags/$tag.tar.gz"; then
                echo -e "${Error}ERROR ${Off} Failed to download $script-$shorttag.tar.gz!"
            else
                if [[ -f $HOME/$script-$shorttag.tar.gz ]]; then
                    if ! tar -xf "$HOME/$script-$shorttag.tar.gz"; then
                        echo -e "${Error}ERROR ${Off} Failed to extract $script-$shorttag.tar.gz!"
                    else
                        if ! rm "$HOME/$script-$shorttag.tar.gz"; then
                            echo -e "${Error}ERROR ${Off} Failed to delete downloaded $script-$shorttag.tar.gz!"
                        else
                            echo -e "\n$tag and changes.txt are in ${Cyan}$shorthome/$script-$shorttag${Off}"
                            echo -e "${Cyan}Do you want to stop this script so you can run the new one?${Off} {y/n]"
                            read -r -t 30 reply
                            if [[ ${reply,,} == "y" ]]; then exit; fi
                        fi
                    fi
                else
                    echo -e "${Error}ERROR ${Off} $shorthome/$script-$shorttag.tar.gz not found!"
                    #ls $HOME/ | grep "$script"  # debug
                fi
            fi
        fi
    fi
fi


#------------------------------------------------------------------------------
# Get list of installed SATA, SAS and M.2 NVMe/SATA drives

getdriveinfo() {
    # Get drive model and firmware version
    hdmodel=$(cat "$1/device/model")
    hdmodel=$(printf "%s" "$hdmodel" | xargs)  # trim leading and trailing white space

    fwrev=$(cat "$1/device/rev")
    fwrev=$(printf "%s" "$fwrev" | xargs)  # trim leading and trailing white space

    if [[ $hdmodel ]] && [[ $fwrev ]]; then
        hdlist+=("${hdmodel},${fwrev}")
    fi
}

getm2info() {
    nvmemodel=$(cat "$1/device/model")
    nvmemodel=$(printf "%s" "$nvmemodel" | xargs)  # trim leading and trailing white space
    if [[ $2 == "nvme" ]]; then
        nvmefw=$(cat "$1/device/firmware_rev")
    elif [[ $2 == "nvc" ]]; then
        nvmefw=$(cat "$1/device/rev")
    fi
    nvmefw=$(printf "%s" "$nvmefw" | xargs)  # trim leading and trailing white space

    if [[ $nvmemodel ]] && [[ $nvmefw ]]; then
        nvmelist+=("${nvmemodel},${nvmefw}")
    fi
}

getcardmodel() {
    # Get M.2 card model
    cardmodel=$(synodisk --m2-card-model-get "$1")
    if [[ $cardmodel =~ M2D[0-9][0-9] ]]; then
        # M2 adaptor card
        m2carddblist+=("${model}_${cardmodel,,}${version}.db")  # M.2 card's db file
        m2cardlist+=("$cardmodel")                              # M.2 card
    elif [[ $cardmodel =~ E[0-9][0-9]+M.+ ]]; then
        # Ethernet + M2 adaptor card
        m2carddblist+=("${model}_${cardmodel,,}${version}.db")  # M.2 card's db file
        m2cardlist+=("$cardmodel")                              # M.2 card
    fi
}


for d in /sys/block/*; do
    case "$(basename -- "${d}")" in
        sd*|hd*)
            if [[ $d =~ [hs]d[a-z][a-z]?$ ]]; then
                # Get drive model and firmware version
                getdriveinfo "$d"
            fi
        ;;
        sata*|sas*)
            if [[ $d =~ (sas|sata)[0-9][0-9]?[0-9]?$ ]]; then
                # Get drive model and firmware version
                getdriveinfo "$d"
            fi
        ;;
        nvme*)
            if [[ $d =~ nvme[0-9][0-9]?n[0-9][0-9]?$ ]]; then
                if [[ $m2 != "no" ]]; then
                    getm2info "$d" "nvme"
                    # Get M.2 card model if in M.2 card
                    getcardmodel "/dev/$d"
                fi
            fi
        ;;
        nvc*)  # M.2 SATA drives (in PCIe card only?)
            #if [[ $d =~ nvc[0-9][0-9]?p[0-9][0-9]?$ ]]; then
            if [[ $d =~ nvc[0-9][0-9]?$ ]]; then
                if [[ $m2 != "no" ]]; then
                    getm2info "$d" "nvc"
                    # Get M.2 card model if in M.2 card
                    getcardmodel "/dev/$d"
                fi
            fi
        ;;
    esac
done


sortarray(){
    # Sort $1 array into new $2 array to remove duplicates
    local -n inarray=$1
    outarray=()
    if [[ ${#inarray[@]} -gt "0" ]]; then
        while IFS= read -r -d '' x; do
            outarray+=("$x")
        done < <(printf "%s\0" "${inarray[@]}" | sort -uz)        
    fi
}


# Sort hdlist array into new hdds array to remove duplicates
sortarray "hdlist"
hdds=${outarray[*]}

# Check hdds array isn't empty
if [[ ${#hdds[@]} -eq "0" ]]; then
    echo -e "${Error}ERROR${Off} No drives found!" && exit 2
else
    echo "HDD/SSD models found: ${#hdds[@]}"
    num="0"
    while [[ $num -lt "${#hdds[@]}" ]]; do
        echo "${hdds[num]}"
        num=$((num +1))
    done
    echo
fi


# Sort nvmelist array into new nvmes array to remove duplicates
sortarray "nvmelist"
nvmes=${outarray[*]}

# Check nvmes array isn't empty
if [[ ${#nvmes[@]} -eq "0" ]]; then
    if [[ $m2 != "no" ]]; then
        echo -e "No M.2 drives found\n"
    fi
else    
    echo "M.2 drive models found: ${#nvmes[@]}"
    num="0"
    while [[ $num -lt "${#nvmes[@]}" ]]; do
        echo "${nvmes[num]}"
        num=$((num +1))
    done
    echo
fi


# M.2 card db files
# Sort m2carddblist array into new m2carddbs array to remove duplicates
sortarray "m2carddblist"
m2carddbs=${outarray[*]}

# M.2 cards
# Sort m2cardlist array into new m2cards array to remove duplicates
sortarray "m2cardlist"
m2cards=${outarray[*]}

# Check m2cards array isn't empty
if [[ ${#m2cards[@]} -gt "0" ]]; then
    echo "M.2 card models found: ${#m2cards[@]}"
    num="0"
    while [[ $num -lt "${#m2cards[@]}" ]]; do
        echo "${m2cards[num]}"
        num=$((num +1))
    done
    echo
fi


#------------------------------------------------------------------------------
# Check databases and add our drives if needed

db1="/var/lib/disk-compatibility/${model}_host${version}.db"
db2="/var/lib/disk-compatibility/${model}_host${version}.db.new"
dbpath="/var/lib/disk-compatibility/"

synoinfo="/etc.defaults/synoinfo.conf"


if [[ ! -f "$db1" ]]; then echo -e "${Error}ERROR 3${Off} $db1 not found!" && exit 3; fi
#if [[ ! -f "$db2" ]]; then echo -e "${Error}ERROR 4${Off} $db2 not found!" && exit 4; fi
# new installs don't have a .db.new file


# Detect drive db type
if grep -F '{"disk_compatbility_info":' "$db1" >/dev/null; then
    # DSM 7 drive db files start with {"disk_compatbility_info":
    dbtype=7
elif grep -F '{"success":1,"list":[' "$db1" >/dev/null; then
    # DSM 6 drive db files start with {"success":1,"list":[
    dbtype=6
else
    echo -e "${Error}ERROR${Off} Unknown database type $(basename -- "${db1}")!"
    exit 7
fi
#echo "dbtype: $dbtype"  # debug


backupdb() {
    # Backup database file if needed
    if [[ ! -f "$1.bak" ]]; then
        if cp "$1" "$1.bak"; then
            echo -e "\nBacked up $(basename -- "${1}") database.\n"
        else
            echo -e "${Error}ERROR 5${Off} Failed to backup $(basename -- "${1}")!"
            return 1
        fi
    fi
}


# Backup host database file if needed
backupdb "$db1" || exit 5

# Backup synoinfo.conf if needed
backupdb "$synoinfo" || exit 9


#------------------------------------------------------------------------------
# Edit db files

updatedb() {
    hdmodel=$(printf "%s" "$1" | cut -d"," -f 1)
    fwrev=$(printf "%s" "$1" | cut -d"," -f 2)

    #echo arg1 "$1"           # debug
    #echo arg2 "$2"           # debug
    #echo hdmodel "$hdmodel"  # debug
    #echo fwrev "$fwrev"      # debug

    if grep "$hdmodel" "$2" >/dev/null; then
        echo -e "${Yellow}$hdmodel${Off} already exists in ${Cyan}$(basename -- "$2")${Off}"
    else
        if [[ $dbtype -gt "6" ]];then
            # Don't need to add firmware version?
            fwstrng=\"$fwrev\"
            fwstrng="$fwstrng":{\"compatibility_interval\":[{\"compatibility\":\"support\",\"not_yet_rolling_status\"
            fwstrng="$fwstrng":\"support\",\"fw_dsm_update_status_notify\":false,\"barebone_installable\":true}]},

            default=\"default\"
            default="$default":{\"compatibility_interval\":[{\"compatibility\":\"support\",\"not_yet_rolling_status\"
            default="$default":\"support\",\"fw_dsm_update_status_notify\":false,\"barebone_installable\":true}]}}}

            #if sed -i "s/}}}/}},\"$hdmodel\":{$fwstrng$default/" "$2"; then  # Don't need to add firmware version?
            if sed -i "s/}}}/}},\"$hdmodel\":{$default/" "$2"; then
                echo -e "Added ${Yellow}$hdmodel${Off} to ${Cyan}$(basename -- "$2")${Off}"

                # Count drives added to host db files
                if [[ $2 == "$db1" ]]; then
                    db1Edits=$((db1Edits +1))
                elif [[ $2 == "$db2" ]]; then
                    db2Edits=$((db2Edits +1))
                fi

            else
                echo -e "\n${Error}ERROR 6${Off} Failed to update v7 $(basename -- "$2")${Off}"
                exit 6
            fi
        else
            # example:
            # {"model":"WD60EFRX-68MYMN1","firmware":"82.00A82","rec_intvl":[1]},
            # Don't need to add firmware version?
            #string="{\"model\":\"${hdmodel}\",\"firmware\":\"${fwrev}\",\"rec_intvl\":\[1\]},"
            string="{\"model\":\"${hdmodel}\",\"firmware\":\"\",\"rec_intvl\":\[1\]},"
            # {"success":1,"list":[
            startstring="{\"success\":1,\"list\":\["

            #echo "$startstring"  # debug
            #echo "$string"       # debug
            #echo                 # debug

            # example:
            # {"success":1,"list":[{"model":"WD60EFRX-68MYMN1","firmware":"82.00A82","rec_intvl":[1]},
            if sed -ir "s/$startstring/$startstring$string/" "$2"; then
                echo -e "Added ${Yellow}$hdmodel${Off} to ${Cyan}$(basename -- "$2")${Off}"

                # Count drives added to host db files
                if [[ $2 == "$db1" ]]; then
                    db1Edits=$((db1Edits +1))
                elif [[ $2 == "$db2" ]]; then
                    db2Edits=$((db2Edits +1))
                fi

            else
                echo -e "\n${Error}ERROR 8${Off} Failed to update $(basename -- "$2")${Off}"
                exit 8
            fi
        fi
    fi
}

# HDDs and SATA SSDs
num="0"
while [[ $num -lt "${#hdds[@]}" ]]; do
    updatedb "${hdds[$num]}" "$db1"
    if [[ -f "$db2" ]]; then
        updatedb "${hdds[$num]}" "$db2"
    fi
    num=$((num +1))
done

# M.2 NVMe/SATA drives
num="0"
while [[ $num -lt "${#nvmes[@]}" ]]; do
    updatedb "${nvmes[$num]}" "$db1"
    if [[ -f "$db2" ]]; then
        updatedb "${nvmes[$num]}" "$db2"
    fi

    #------------------------------------------------
    # M.2 adaptor cards
    num2="0"
    while [[ $num2 -lt "${#m2carddbs[@]}" ]]; do
        if [[ -f "${dbpath}${m2carddbs[$num2]}" ]];then
            backupdb "${dbpath}${m2carddbs[$num2]}" &&\
                updatedb "${nvmes[$num]}" "${dbpath}${m2carddbs[$num2]}"
        else
            echo -e "${Error}ERROR 10${Off} ${m2carddbs[$num2]} not found!"
        fi
        num2=$((num2 +1))
    done
    #------------------------------------------------

    num=$((num +1))
done


#------------------------------------------------------------------------------
# Edit /etc.defaults/synoinfo.conf

# Optionally disable "support_disk_compatibility"
sdc=support_disk_compatibility
setting="$(get_key_value $synoinfo $sdc)"
if [[ $force == "yes" ]]; then
    if [[ $setting == "yes" ]]; then
        # Disable support_disk_compatibility
        sed -i "s/${sdc}=\"yes\"/${sdc}=\"no\"/" "$synoinfo"
        setting="$(get_key_value "$synoinfo" $sdc)"
        if [[ $setting == "no" ]]; then
            echo -e "\nDisabled support disk compatibility."
        fi
    fi
else
    if [[ $setting == "no" ]]; then
        # Enable support_disk_compatibility
        sed -i "s/${sdc}=\"no\"/${sdc}=\"yes\"/" "$synoinfo"
        setting="$(get_key_value "$synoinfo" $sdc)"
        if [[ $setting == "yes" ]]; then
            echo -e "\nRe-enabled support disk compatibility."
        fi
    fi
fi


# Check m2 volume support enabled
smp=support_m2_pool
setting="$(get_key_value $synoinfo ${smp})"
enabled=""
if [[ ! $setting ]]; then
    # Add support_m2_pool"yes"
    echo 'support_m2_pool="yes"' >> "$synoinfo"
    enabled="yes"
elif [[ $setting == "no" ]]; then
    # Change support_m2_pool"no" to "yes"
    sed -i "s/${smp}=\"no\"/${smp}=\"yes\"/" "$synoinfo"
    enabled="yes"
elif [[ $setting == "yes" ]]; then
    echo -e "\nM.2 volume support already enabled."
fi

# Check if we enabled m2 volume support
setting="$(get_key_value $synoinfo ${smp})"
if [[ $enabled == "yes" ]]; then
    if [[ $setting == "yes" ]]; then
        echo -e "\nEnabled M.2 volume support."
    else
        echo -e "${Error}ERROR${Off} Failed to enable m2 volume support!"
    fi
fi


# Edit synoinfo.conf to prevent drive db updates
dtu=drive_db_test_url
url="$(get_key_value $synoinfo ${dtu})"
disabled=""
if [[ $nodbupdate == "yes" ]]; then
    if [[ ! $url ]]; then
        # Add drive_db_test_url="127.0.0.1"
        echo 'drive_db_test_url="127.0.0.1"' >> "$synoinfo"
        disabled="yes"
    elif [[ $url != "127.0.0.1" ]]; then
        # Edit drive_db_test_url=
        sed -i "s/drive_db_test_url=.*/drive_db_test_url=\"127.0.0.1\"/" "$synoinfo" >/dev/null
        disabled="yes"
    fi

    # Check if we disabled drive db auto updates
    url="$(get_key_value $synoinfo drive_db_test_url)"
    if [[ $disabled == "yes" ]]; then
        if [[ $url == "127.0.0.1" ]]; then
            echo -e "\nDisabled drive db auto updates."
        else
            echo -e "${Error}ERROR${Off} Failed to disable drive db auto updates!"
        fi
    fi
else
    # Re-enable drive db updates
    if [[ $url == "127.0.0.1" ]]; then
        # Edit drive_db_test_url=
        sed -z "s/drive_db_test_url=\"127\.0\.0\.1\"\n//" "$synoinfo" >/dev/null
        #sed -i "s/drive_db_test_url=\"127\.0\.0\.1\"//" "$synoinfo"  # works but leaves line feed

        # Check if we re-enabled drive db auto updates
        url="$(get_key_value $synoinfo drive_db_test_url)"
        if [[ $url != "127.0.0.1" ]]; then
            echo -e "\nRe-enabled drive db auto updates."
        fi
    else
        echo -e "\nDrive db auto updates already enabled."
    fi
fi


#------------------------------------------------------------------------------
# Finished

# Show the changes
if [[ ${showedits,,} == "yes" ]]; then
    if [[ $dbtype -gt "6" ]];then
        # Show last 12 lines per drive + 4
        lines=$(((db1Edits *12) +4))
        if [[ $db1Edits -gt "0" ]]; then
            echo -e "\nChanges to ${Cyan}$(basename -- "$db1")${Off}"
            jq . "$db1" | tail -n "$lines"
        elif [[ $db2Edits -gt "0" ]]; then
            echo -e "\nChanges to ${Cyan}$(basename -- "$db2")${Off}"
            jq . "$db2" | tail -n "$lines"
        fi
    else
        # Show first 8 lines per drive + 2
        lines=$(((db1Edits *8) +2))
        if [[ $db1Edits -gt "0" ]]; then
            echo -e "\nChanges to ${Cyan}$(basename -- "$db1")${Off}"
            jq . "$db1" | head -n "$lines"
        elif [[ $db2Edits -gt "0" ]]; then
            echo -e "\nChanges to ${Cyan}$(basename -- "$db2")${Off}"
            jq . "$db2" | head -n "$lines"
        fi
    fi
fi


# Make Synology check disk compatibility
/usr/syno/sbin/synostgdisk --check-all-disks-compatibility
status=$?
if [[ $status -eq "0" ]]; then
    echo -e "\nDSM successfully checked disk compatibility."
else
    # Ignore DSM 6 as it returns 255 for "synostgdisk --check-all-disks-compatibility"
    if [[ $dsm -gt "6" ]]; then
        echo -e "\nDSM ${Red}failed${Off} to check disk compatibility with exit code $status"
        echo -e "\nYou may need to ${Cyan}reboot the Synology${Off} to see the changes."
    fi
fi

if [[ $dsm -eq "6" ]]; then
    echo -e "\nYou may need to ${Cyan}reboot the Synology${Off} to see the changes."
fi


exit


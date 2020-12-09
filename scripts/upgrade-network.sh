#!/usr/bin/env bash

ME=$(basename "$0")

# NOTE: the ansible groups are defined in /etc/ansible/hosts inventory file
# It has to be changed accordingly
declare -A MAIN
MAIN[all]="all mainnet nodes"
MAIN[s0]="all nodes in mainnet shard 0"
MAIN[s1]="all nodes in mainnet shard 1"
MAIN[s2]="all nodes in mainnet shard 2"
MAIN[s3]="all nodes in mainnet shard 3"
MAIN[s0_canary]="canary nodes in mainnet shard 0"
MAIN[s1_canary]="canary nodes in mainnet shard 1"
MAIN[s2_canary]="canary nodes in mainnet shard 2"
MAIN[s3_canary]="canary nodes in mainnet shard 3"
MAIN[canary]="all canary nodes in mainnet"
MAIN[s0exp]="explorer nodes in mainnet shard 0"
MAIN[s1exp]="explorer nodes in mainnet shard 1"
MAIN[s2exp]="explorer nodes in mainnet shard 2"
MAIN[s3exp]="explorer nodes in mainnet shard 3"
MAIN[expnode]="explorer nodes in mainnet"
MAIN[snapshot]="all snapshot nodes"

declare -A LRTN
LRTN[lrtn]="all LRTN nodes"
LRTN[lrtns0]="all nodes in LRTN shard 0"
LRTN[lrtns1]="all nodes in LRTN shard 1"
LRTN[lrtns2]="all nodes in LRTN shard 2"
LRTN[lrtns3]="all nodes in LRTN shard 3"

######################## Functions ##########################
function usage() {
   cat<<-EOT
Usage: $ME [options] [actions]

Options:
   -s stride         stride for rolling upgrade (default: $STRIDE)
   -b batch          batch of nodes for restart (default: $BATCH)
   -S shard          select shard for action
   -i list_of_ip     list of IP (delimiter is ,)
   -r release        release version for release (default: $release)
   -t seconds        sleep seconds between each force update (default: $SLEEP)
   -G                not in dryrun mode (default is dryrun mode)

Actions:
   rolling           do rolling upgrade
   restart           do restart shard/network
   update            do force update
   menu              bring up menu to do operation (default)

Examples:
   $ME -s 3 -S canary rolling
   $ME -i 1.2.3.4,2.3.4.5 update

EOT
   exit 0
}

function network_menu() {
   local network=$(whiptail --title "Network Operation" --menu \
      "Choose a network" 25 78 16 \
      "MAIN" "Harmony Mainnet" \
      "LRTN" "Long Running Test Net" 3>&1 1>&2 2>&3)

   if [ -n "$network" ]; then
      echo "$network"
   else
      echo "Exit"
   fi
}

function action_menu() {
   local network=$1

   local action=$(whiptail --title "Network: $network" --menu \
      "Choose an operation" 25 78 16 \
      "Back" "Return to previous Menu" \
      "rolling" "Rolling Upgrade" \
      "restart" "Restart The Shard" \
      "update" "Force Update" \
      "Exit" "Exit the Menu" 3>&1 1>&2 2>&3)

   if [ -n "$action" ]; then
      echo "$action"
   else
      echo "Exit"
   fi
}

function input_ip_box() {
   local title=$1
   local init=$2

   ip=$(whiptail --title "$title" --inputbox \
      "A list of IP addresses, delimited by ','" 8 78 \
      "$init" 3>&1 1>&2 2>&3)

   exitstatus=$?
   if [ $exitstatus = 1 ]; then
      echo Exit
   else
      echo "$ip"
   fi

}

# https://www.linuxjournal.com/content/validating-ip-address-bash-script
function valid_ip()
{
    local ip=$1
    local stat=1

    if [[ $ip =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        OIFS=$IFS
        IFS='.'
        ip=($ip)
        IFS=$OIFS
        [[ ${ip[0]} -le 255 && ${ip[1]} -le 255 \
            && ${ip[2]} -le 255 && ${ip[3]} -le 255 ]]
        stat=$?
    fi
    return $stat
}

function validate_ip_addresses() {
   if [ -z "$1" ]; then
      return 1
   fi

   OIFS=$IFS
   IFS=','
   read -a IPARR <<< "$1"
   IFS=$OIFS

   for (( n=0; n < ${#IPARR[*]}; n++ )); do
      if ! valid_ip "${IPARR[$n]}"; then
         return 1
      fi
   done

   return 0
}

function shard_menu() {
   local net=$1
   local menu=""
   OIFS="$IFS"
   IFS='/'

   case ${net} in
      MAIN)
         sorted=()
         while IFS= read -rd '' key; do
            sorted+=( "$key" )
         done < <(printf '%s\0' "${!MAIN[@]}" | sort -z)
         for i in "${sorted[@]}"; do
            menu+="$i/${MAIN[$i]}/OFF/"
         done ;;
      LRTN)
         for i in ${!LRTN[@]}; do
            menu+="$i/${LRTN[$i]}/OFF/"
         done ;;
   esac

   local shard=$(whiptail --title "Network: $net" --radiolist \
      "Choose one or all shards" 20 78 12 \
      ${menu} \
      "ip" "manual input IP addresses " ON 3>&1 1>&2 2>&3)

   IFS="$OIFS"

   if [ -n "$shard" ]; then
      echo "$shard"
   else
      echo "Exit"
   fi
}

function input_release_box() {
   local network=$1

   local rel=$(whiptail --title "Network: $network" --inputbox \
      "Input the release bucket" 8 78 \
      3>&1 1>&2 2>&3)

   echo "$rel"
}

function release_menu() {
   local title=$1
   local menu_tmp=$(mktemp menu.XXXX)

   # assume the host has permission to list s3 bucket
   aws s3 ls s3://pub.harmony.one/release/linux-x86_64/ | grep PRE | grep -v 'PRE v' | awk ' { print $2 } ' | sed 's,\(.*\)/,\1 \1,' | tr '\n' ' ' > "$menu_tmp"

   readarray -t menus < "$menu_tmp"

   local release
   while [ -z "$release" ]; do
      release=$(whiptail --title "$title" --menu \
         "Choose release bucket on s3://pub.harmony.one/release/linux-x86_64/" 30 78 20 \
         ${menus[@]} \
         "input" "manual input release bucket" 3>&1 1>&2 2>&3)

      case $release in
         input) release=$(input_release_box "$network") ;;
      esac
   done

   rm -f "$menu_tmp"
   echo "$release"
}

function do_rolling_upgrade() {
   local inv=$1
   local release=$2

   if $DRYRUN; then
      echo ansible-playbook playbooks/upgrade-node.yml -f "$STRIDE" -e "inventory=${inv} stride=${STRIDE} upgrade=${release}"
   else
      ansible-playbook playbooks/upgrade-node.yml -f "$STRIDE" -e "inventory=${inv} stride=${STRIDE} upgrade=${release}"
      whiptail --title "Notice" --msgbox "The leader won't be upgraded automatically.\nPlease upgrade leader with force update." 8 78
   fi
}

function do_restart_shard() {
   local inv=$1
   if $DRYRUN; then
      echo ansible-playbook playbooks/restart-node.yml -f "$BATCH" -e "inventory=${inv} stride=${BATCH} skip_consensus_check=true"
   else
      ansible-playbook playbooks/restart-node.yml -f "$BATCH" -e "inventory=${inv} stride=${BATCH} skip_consensus_check=true"
   fi
}

function do_force_update() {
   local inv=$1
   local release=$2

   if $DRYRUN; then
      echo ansible-playbook playbooks/upgrade-node.yml -f "$BATCH" -e \"inventory=${inv} stride=${BATCH} upgrade=${release} force_update=true skip_consensus_check=true\"
   else
      ansible-playbook playbooks/upgrade-node.yml -f "$BATCH" -e "inventory=${inv} stride=${BATCH} upgrade=${release} force_update=true skip_consensus_check=true"
   fi
}

function do_menu() {
   whiptail --title "Network Operation" --msgbox "Welcome to operation on Harmony Network!\nUse '-G' to do the real work!" 8 78

   while true; do
      net=$(network_menu)
      case $net in
         Exit) exit 0 ;;
      esac
      action=$(action_menu "$net")
      case $action in
         Exit) exit 0 ;;
         Back) continue ;;
         *) break ;;
      esac
   done

   shard=$(shard_menu "$net")

   case ${shard} in
      Exit) exit 0 ;;
      ip) 
         ip=$(input_ip_box "Please Input IP addresses.")
         while true; do
            case $ip in
               Exit) exit 0 ;;
            esac
            ip=$(echo "$ip" | tr -d ' ')
            if validate_ip_addresses "$ip"; then
               break
            else
               ip=$(input_ip_box "Invalid IP address(es)." "$ip")
            fi
         done
         ;;
      *) ip="" ;;
   esac

# for rolling update or force update, get the release bucket info
   case $action in
      rolling|update) 
         release=$(release_menu "Network: $net") ;;
   esac
}

####### default value ######
STRIDE=2
BATCH=60
release=upgrade
DRYRUN=true
SLEEP=5

declare IPARR
unset action ip

while getopts ":s:S:i:r:b:Gt:" opt; do
   case ${opt} in
      s) STRIDE=${OPTARG} ;;
      S) shard=${OPTARG} ;;
      i) ip=${OPTARG} ;;
      r) release=${OPTARG} ;;
      b) BATCH=${OPTARG} ;;
      G) DRYRUN=false ;;
      t) SLEEP=${OPTARG} ;;
      *) usage ;;
   esac
done

shift $((OPTIND-1))

action=${1:-menu}
shift

case $action in
   rolling|restart|update) ;;
   menu) do_menu ;;
   *) usage ;;
esac

if [ -z "$ip" ]; then
   IPARR=( $shard )
else
   if ! validate_ip_addresses "$ip"; then
      echo "Invalid IP addresses: $ip"
      exit 1
   fi
fi
 
# do action per ip or per group
for (( n=0; n < ${#IPARR[*]}; n++ )); do
   case $action in
      rolling)
         do_rolling_upgrade "${IPARR[$n]}" "$release" ;;
      restart)
         do_restart_shard "${IPARR[$n]}" ;;
      update)
         do_force_update "${IPARR[$n]}" "$release" ;;
      *)
         exit 0 ;;
   esac
done

# ToDo:
# - verify environment cleanup
# - add snapshot option for non container systems

updates() {
   local SSH="ssh -q -o ConnectTimeout=10 -o BatchMode=yes"
   local SNAPBASE="upgrade-"

        updates_ctzfsds() {
           local ctid="$1" storage store ds dspath
           storage=$( $SSH "$host" "pct config $ctid" | sed '/^rootfs/!d; s/rootfs: \([^,]\+\),.*/\1/')
           test "$storage" = "" && { updates_output+=( "Unable to create zfs snapshot." ); return 1; }
           store="${storage/:*/}"
           ds="${storage/*:/}"
           $SSH "$host" "grep -q \"^zfspool: $store\"" /etc/pve/storage.cfg || return 1
           dspath=$( $SSH "$host" "sed -n \"/: $store$/,/^$/ { /^[[:space:]]\+pool/ s/.*pool //gp }\" /etc/pve/storage.cfg" )
           echo "${dspath}/${ds}"
           return 0
        }

        updates_snapshotaction() {
           local filter=""
           local action="$1"; shift
           local host="$1"; shift
           local ctid="$1"; shift
           test "$1" = "-f" && { filter="$2"; shift 2; }
           local snapinfo snapshot
      snapinfo="$($SSH "$host" "pct listsnapshot $ctid" 2> /dev/null)"
           test "$?" -ne 0 && return 1
      mapfile -t snapshots < <( echo "$snapinfo" | grep -v -- '-> current' | awk '{print $2}' | grep "^${SNAPBASE}${filter}")
           if test "$action" = "rm"; then
              for snapshot in ${snapshots[@]}; do
            echo $SSH "$host" "pct delsnapshot $ctid $snapshot" 2> /dev/null || return 1
              done
           fi
           dspath=$(updates_ctzfsds "$ctid")
           test "$action" = "rm" && unset snapshots
           mapfile -t snapshots < <($SSH "$host" "zfs list -t snapshot -H -o name $dspath" | grep "^${dspath}@${SNAPBASE}${filter}" | cut -d '@' -f 2)
           if test "$action" = "rm"; then
              for snapshot in ${snapshots[@]}; do
            echo $SSH "$host" "zfs destroy ${dspath}@${snapshot}" 2> /dev/null || return 1
              done
           fi
           return 0
    }

        updates_snapshot() {
      local snapname="${SNAPBASE}$(date "+%Y%m%d-%H%M")"
           local ctid="$1"
      $SSH "$host" "pct snapshot $ctid $snapname" > /dev/null 2>&1
      ret="$?"
      if test "$ret" -ne 0; then
              dspath=$(updates_ctzfsds "$ctid")
              test "$dspath" = "" && { updates_output+=( "Unable to create snapshot, pve and zfs failed." ); return 1; }
              $SSH "$host" "zfs snapshot $dspath/$ds@$snapname" > /dev/null 2>&1
              ret="$?"
         if test "$ret" -ne 0; then
            updates_output+=( "Unable to create zfs snapshot." )
            return $ret
              else
            updates_output+=( "ZFS snapshot $snapname created." )
              fi
      else
         updates_output+=( "PVE snapshot $snapname created." )
      fi
        }

   updates_upgrade_rpm() {
        local opts
        declare -a opts
        test "$1" = "-s" && { opts+=( "--setopt" "tsflags=test" ); snapshot=no; shift; }
        test "$1" = "-d" && { opts+=( "--downloadonly" ); snapshot=no; shift; }
      local host="$1"
      local CT=""
      local ret
      unset updates_output
      declare -ga updates_output
      
      test "$2" != "" && CT="pct exec $2 -- "
      
      if test "$CT" != "" -a "$snapshot" != "no"; then
                   updates_snapshot "$2" || return 1
      fi
      
      while read -u 11 -r line; do
         updates_output+=("$line")
      done 11< <($SSH "$host" "$CT"' bash -c "https_proxy=\"\" http_proxy=\"\" yum update -y '"${opts[@]}"' 2>&1"' | sed 's/^M//g'; echo ${PIPESTATUS[0]};)
      local ret="${updates_output[-1]}"
      unset updates_output[-1]
      return $ret
   }

   updates_upgrade_deb() {
        local opts
        declare -a opts
        test "$1" = "-s" && { opts+=( "--dry-run" ); snapshot=no; shift; }
        test "$1" = "-d" && { opts+=( "--download-only" ); snapshot=no; shift; }
      local host="$1"
      local CT=""
      local ret
      unset updates_output
      declare -ga updates_output

      test "$2" != "" && CT="pct exec $2 -- "
      
      if test "$CT" != "" -a "$snapshot" != "no"; then
                   updates_snapshot "$2" || return 1
      fi
      
      while read -u 11 -r line; do
         updates_output+=("$line")
      done 11< <($SSH "$host" "$CT"' bash -c "https_proxy=\"\" http_proxy=\"\" DEBIAN_FRONTEND=noninteractive apt-get '"${opts[@]}"' --yes -o Dpkg::Options::=--force-confold full-upgrade 2>&1"' | sed 's/^M//g'; echo ${PIPESTATUS[0]};)
      local ret="${updates_output[-1]}"
      unset updates_output[-1]
      return $ret
   }

   updates_ck_rpm() {
        local UPDATE=0
        test "$1" = "-u" && { UPDATE=1; shift; }
      local host="$1"

      if test "$2" != ""; then
         local CT="pct exec $2 -- "
      else
         local CT=""
      fi

      unset updates_avail updates_hold updates_curver updates_newver updates_curversrc updates_newversrc
      declare -ga updates_avail updates_hold
      declare -gA updates_curver updates_newver updates_curversrc updates_newversrc

      if test "$UPDATE" = "1"; then
         $SSH "$host" "$CT"'yum makecache' > /dev/null 2>&1
      fi
      while read pkg newver src; do
         updates_avail+=("$pkg")
         updates_newver["$pkg"]="$newver"
         updates_newversrc["$pkg"]="$src"
      done < <($SSH "$host" "$CT"' yum -q check-update' 2> /dev/null | grep -v -e "^$" -e "^Security:" )

      test "${#updates_avail[*]}" -eq 0 && return
      while read pkg curver; do
         updates_curver[$pkg]="$curver"
         updates_curversrc[$pkg]=""
      done < <($SSH "$host" "$CT"' rpm -q --queryformat "%{name}.%{arch} %|epoch?{%{epoch}:}|%{version}.%{release}\n" '"${updates_avail[*]}" 2> /dev/null)
   }

   updates_ck_deb() {
        local UPDATE=0
        test "$1" = "-u" && { UPDATE=1; shift; }
      local host="$1"

      if test "$2" != ""; then
         local CT="pct exec $2 -- "
      else
         local CT=""
      fi

      unset updates_avail updates_hold updates_curver updates_newver updates_curversrc updates_newversrc
      declare -ga updates_avail updates_hold
      unset pkgs pkgupdate pkgcurver pkgnewver pkgstate
      declare -a pkgs
      declare -A pkgstatetemp
      declare -ga updates_avail updates_hold
      declare -gA updates_curver updates_newver updates_curversrc updates_newversrc

      local arch=$($SSH "$host" "$CT"'dpkg --print-architecture')
      if test "$UPDATE" = "1"; then
         $SSH "$host" "$CT"'apt-get update' > /dev/null 2>&1
      fi
      local pkg curver state
      while read pkg state; do
         if test "$state" = "ii" -o "$state" = "hi"; then
            pkgs+=("$pkg")
            pkgstatetemp["$pkg"]="$state"
         fi
      done < <($SSH "$host" "$CT"' dpkg-query -W -f="\${binary:Package} \${db:Status-Abbrev}\n"')
      local pkg curver newver cursrc newsrc pkgtmp
      while read pkg curver newver cursrc newsrc; do
         if test "$curver" != "$newver"; then
                test "${pkgstatetemp[$pkg]}" = "" && pkgtmp="$pkg:$arch" || pkgtmp="$pkg"
            if test "${pkgstatetemp[$pkgtmp]}" = "hi"; then
               updates_hold+=( "$pkg" )
            else
               updates_avail+=( "$pkg" )
            fi
            updates_curver["$pkg"]="$curver"
            updates_curversrc["$pkg"]="$cursrc"
            updates_newver["$pkg"]="$newver"
            updates_newversrc["$pkg"]="$newsrc"
         fi
      done < <(
      $SSH "$host" "$CT apt policy ${pkgs[*]}" 2> /dev/null | awk '
         BEGIN {curver="0:0.0.0+r0-0"; newver="0:0.0.0+r0-0"; curverfound=0; newverfound=0; v=0;}
         {if (v == 1) {
              if (curverfound == 1) {
                 curversrc = $2
                 curverfound=0;
              }
              if (newverfound == 1) {
                 newversrc = $2
                 newverfound=0;
              }
           }
         if (index($0, curver) != 0)
            curverfound = 1
         if (index($0, newver) != 0)
            newverfound = 1
         }
         !/^ / { if (pkg != "")
                    printf("%s %s %s %s %s\n", pkg, curver, newver, curversrc, newversrc);
             curversrc = "unknown"
             newversrc = "unknown"
             v = 0
                 pkg = substr($1,1,length($1)-1);
               }
         /^  Installed:/ { curver=$2 }
         /^  Candidate:/ { newver=$2 }
         /^  Version table:$/ { v=1 }
         END { printf("%s %s %s %s %s\n", pkg, curver, newver, curversrc, newversrc) }
      ')
      unset pkgs
   }

   updates_checkos() {
                local -n result="$1"
      local host="$2"
      test "$3" != "" && local CT="pct exec $3 --"
      
      result=$( $SSH "$host" "$CT" 'lsb_release -s -i' 2> /dev/null )
      test "$result" = "" && result=$( $SSH "$host" "$CT" 'cut -d \  -f 1-2 /etc/redhat-release' 2> /dev/null )
      case "$result" in
         "Debian"|"Ubuntu"|"Raspbian") result="deb" ;;
         "RedHatEnterprise"|"RedHatEnterpriseServer"|"Red Hat"|"RedHatEnterpriseWorkstation"|"Scientific") result="rpm" ;;
         "") _LIBUPDATES_ERROR="updates: Unable to determine OS"; return 1 ;;
         *) _LIBUPDATES_ERROR="updates: Unsupported OS $result"; return 1 ;;
      esac
      return 0
   }

   action="$1"
   shift

    local opts
    unset opts
    declare -a opts
   case "$action" in
      "error")
            test "${_LIBUPDATES_ERROR}" != "" && echo "${_LIBUPDATES_ERROR}"
            return 0
         ;;
      "check")
              unset _LIBUPDATES_ERROR
            test "$1" = "-u" && { opts+=( "-u" ); shift; }
         local os
                        updates_checkos os "$1" "$2" || return 1
         updates_ck_${os} "${opts[@]}" "$1" "$2"
      ;;
      "upgrade")
              unset _LIBUPDATES_ERROR
            test "$1" = "-d" && { opts+=( "-d" ); shift; }
            test "$1" = "-s" && { opts+=( "-s" ); shift; }
         local os
         updates_checkos os "$1" "$2"
         test "$?" -ne 0 && { _LIBUPDATES_ERROR="updates: Unable to determine OS ($os)"; return 1; }
         updates_upgrade_${os} "${opts[@]}" "$1" "$2"
      ;;
      "is-container")
              unset _LIBUPDATES_ERROR
         $SSH "$1" "grep -q 'xcfs /proc/meminfo' /proc/1/mounts" 2> /dev/null
            return $?
        ;;
      "container-list")
              unset _LIBUPDATES_ERROR
         unset containers
         $SSH "$1" which pct > /dev/null 2>&1
         test "$?" -ne 0 && return 1
         declare -Ag containers
         while read -u 6 id state name; do
            test "$state" = "running" && containers["$id"]="$name"
         done 6< <( $SSH "$1" "pct list" | tail -n +2 )
         return 0
      ;;
      "snapshot-list")
         unset snapshots
         $SSH "$1" which pct > /dev/null 2>&1
         test "$?" -ne 0 && return 1
         updates_snapshotaction list "$1" "$2" "$3" "$4" || return 1
         return 0
      ;;
      "snapshot-rm")
         $SSH "$1" which pct > /dev/null 2>&1
         test "$?" -ne 0 && return 1
         updates_snapshotaction rm "$1" "$2" "$3" "$4" || return 1
         return 0
      ;;

      *) _LIBUPDATES_ERROR="updates: unknown action $action"; return 1 ;;
   esac
}

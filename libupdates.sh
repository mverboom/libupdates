# ToDo:
# v check: add force local cache update
# - verify environment cleanup
# - upgrade: add snapshot switch
# - add snapshot option for non container systems
# v error unsupported os also crops up when system is unreachable through ssh
# v download updates but don't install (yum update -y --setopt tsflags=test, apt-get --dry-run)
# v error messages in variable and non zero return status

updates() {
	local SSH="ssh -q -o ConnectTimeout=10"

	updates_upgrade_rpm() {
        local opts
        declare -a opts
        test "$1" = "-s" && { opts+=( "--setopt" "tsflags=test" ); shift; }
        test "$1" = "-d" && { opts+=( "--download-only" ); shift; }
		local host="$1"
		local CT=""
		local ret
		unset updates_output
		declare -ga updates_output
		
		test "$2" != "" && CT="pct exec $2 -- "
		
		if test "$CT" != "" -a "$snapshot" != "no"; then
		   snapname="upgrade-$(date "+%Y%m%d-%H%M")"
		   $SSH "$host" "pct snapshot $2 $snapname" > /dev/null 2>&1
		   ret="$?"
		   if test "$ret" -ne 0; then
		      updates_output+=( "Unable to create snapshot." )
		      return $ret
		   else
		      updates_output+=( "Snapshot $snapname created." )
		   fi
		fi
		
		while read -u 11 -r line; do
		   updates_output+=("$line")
		done 11< <($SSH "$host" "$CT"' bash -c "https_proxy=\"\" http_proxy=\"\" yum update -y '"${opts[@]}"' 2>&1"' | sed 's/^M//g'; echo $?;)
		local ret="${updates_output[-1]}"
		unset updates_output[-1]
		return $ret
	}

	updates_upgrade_deb() {
        local opts
        declare -a opts
        test "$1" = "-s" && { opts+=( "--dry-run" ); shift; }
        test "$1" = "-d" && { opts+=( "--download-only" ); shift; }
		local host="$1"
		local CT=""
		local ret
		unset updates_output
		declare -ga updates_output

		test "$2" != "" && CT="pct exec $2 -- "
		
		if test "$CT" != "" -a "$snapshot" != "no"; then
		   snapname="upgrade-$(date "+%Y%m%d-%H%M")"
		   $SSH "$host" "pct snapshot $2 $snapname" > /dev/null 2>&1
		   ret="$?"
		   if test "$ret" -ne 0; then
		      updates_output+=( "Unable to create snapshot." )
		      return $ret
		   else
		      updates_output+=( "Snapshot $snapname created." )
		   fi
		fi
		
		while read -u 11 -r line; do
		   updates_output+=("$line")
		done 11< <($SSH "$host" "$CT"' bash -c "https_proxy=\"\" http_proxy=\"\" DEBIAN_FRONTEND=noninteractive apt-get '"${opts[@]}"' --yes -o Dpkg::Options::=--force-confold full-upgrade 2>&1"' | sed 's/^M//g'; echo $?;)
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
		"list-containers")
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
		*) _LIBUPDATES_ERROR="updates: unknown action $action"; return 1 ;;
	esac
}

#!/bin/sh
REVISION='install-ariba.sh v1.10'

function usage() {
    local msg="$1" exit_code="$2"
    [ -n "$1" ] && dbg "$1"
    cat <<EOF
Version: $REVISION
Usage:   install-ariba.sh <phases> version [<sp_jarfile>]
Options:
    phases:       comma separated list of phase prefixes. Known phases:
                  os, wl.inst, wl.fixreg, aes.inst, aes.sp.inst, aes.sp.udt.cs, aes.sp.udt.cs, aes.cfg
    version:      must specify the ariba version ie 9r1, 9r2 ..
    sp_jarfile:   jar file for service pack - e.g. sourcing_9.0_sp30.16.jar
  
Examples:
    install-ariba.sh aes. sourcing_9.0_sp30.16.jar 
    # run all phases starting with aes. - ie. installs AES + applies whole sp30 + configures it
EOF
    return $exit_code
}

# Changelog:
# 1.0 - initial implementation
# 1.1 - save cumulative install log, default to ariba/install_sources, make output more readable
# 1.2 - put phases arg into install log name
# 1.3 - fix /dev/tty error, put phases after timestamp in install log name, return correct error code
# 1.4 - kill installshield leftovers
# 1.5 - copy logfile to REM_LOGDIR
# 1.6 - make kill more friendly (do not run kill if nothing to kill, put nice msg)
# 1.7 - fix "command not found" in aes.kill
# 1.8 - return error if setprop fails in any of the steps, rewrite check_phase to run phase function
# 1.9 - add phase aes.cfg.fixcore to apply core code fixes to AdminUtil.pm to increase WL startup wait time   
# 1.10 - adding ariba version so script can install 9r1 or 9r2
# 1.11 - fix weblogic multiple nodes, missing p.table and make a conf/ folder with all script / conf files

default_phases=wl,aes
PHASES="${1:-$default_phases}"
ARIBA_VERSION="$2"
ARG="$3"

#--- config --------------------------------------------------------------------
PHASE_INDENT="  "
CMD_INDENT="    "
DATE_FMT=%Y-%m-%d_%H-%M-%S
alias date_format="date +$DATE_FMT"

LOGDIR="${LOGDIR:-/home/ariba/logs}"
[ -d "$LOGDIR" ] || mkdir -p "$LOGDIR"
INST_LOGFILE=$LOGDIR/install-$(date_format)-$PHASES.log
SCP_OPTS="${SCP_OTPS:--oPasswordAuthentication=no}"

INSTALL_DIR=${INSTALL_DIR:-/home/ariba/install_sources}
WL_INSTALL_DIR=${WL_INSTALL_DIR:-$INSTALL_DIR/Weblogic}
AES_INSTALL_DIR=${AES_INSTALL_DIR:-$INSTALL_DIR/Upstream-$ARIBA_VERSION}
AES_CDIMAGE_DIR=${AES_CDIMAGE_DIR:-$AES_INSTALL_DIR/Disk1/InstData}
AES_CONF=${AES_CONF:-$INSTALL_DIR/conf}

AES_INST_PROPS=${AES_INST_PROPS:-$AES_CONF/upstream-installer.properties}
AES_SP_INST_PROPS=${AES_SP_INST_PROPS:-$AES_CONF/sp-upstream-installer.properties}

ARIBA_ROOT=${ARIBA_ROOT:-/home/ariba}
BEA_HOME=$ARIBA_ROOT/bea
DEPOT_ROOT=${DEPOT_ROOT:-$ARIBA_ROOT/Depot}
AES_SERVER_HOME=${AES_SERVER_HOME:-$ARIBA_ROOT/Sourcing/Server}
AES_WC_HOME=${AES_WC_HOME:-$ARIBA_ROOT/Sourcing/WebComponents}

export LAX_DEBUG=0                                                              # enable installshield debug
set -o pipefail                                                                 # return first pipe failure

(echo -n > /dev/tty) 2>/dev/null || NO_TTY=1
#--- helpers -------------------------------------------------------------------
function dbg() {
    echo -e $(date_format) "$@" 1>&2
}

function error() {
    dbg "$1"
    exit "${2:-1}"
}

set_title() {
    title="$1" err="$?"
    [ -z "$NO_TTY" ] && echo -ne "\e]0;$title\a" >/dev/tty
    return $err                                                                 # preserve $?
}

function check_phase() {
    local phase="$1" desc="$2" log="${3:-$1}" check="$4"
    local func="phase_${phase//./_}" err action
    : PID=$$
    IFS=,
    for PH in $PHASES; do
        unset IFS
        [[ "$phase" = $PH* ]] && {
            PHASE="$phase"
            LOGFILE=$LOGDIR/$log-$(date_format).log        
            PHASE_DESC="$desc"
            [ -d $LOGDIR ] || mkdir -p $LOGDIR
            [ -z "$check" ] && dbg "${PHASE_INDENT}Starting phase $phase (matches $PH): $desc, logfile: $LOGFILE"
            PHASE_TITLE="$(date_format) $PHASE"
            set_title "$PHASE_TITLE" 
            $func
            err=$?
            [ $err -ne 0 ] && action=" ... aborting"
            dbg "${PHASE_INDENT}Finished phase $phase with error $err$action"
            return $err
        }
    done
    unset IFS
    return 0
}

function run_cmd() {
    local cmd="$1" alias=$(hostname); shift
    if [ -n "$DRY_RUN" ]; then
        dbg "${CMD_INDENT}NOT Running $cmd $@ 2>&1 | tee -a $LOGFILE"
    else
        dbg "${CMD_INDENT}Running $cmd $@ 2>&1 | tee -a $LOGFILE"
        dbg "${CMD_INDENT}Running $cmd $@" 2>> $LOGFILE  
        set_title "$alias $PHASE_TITLE ${LOGFILE##*/}: ${cmd##*/} $@" 
        "$cmd" "$@" 2>&1 | tee -a $LOGFILE
        local err=$?
        set_title "$alias $PHASE_TITLE" 
        dbg "${CMD_INDENT}Finished $cmd $@, status $err, wrote $LOGFILE\n"
        return $err
    fi
}

function run_cmd_err() {
    run_cmd "$@" || error "  $PHASE_DESC failed - exit code $!\n" $!
}

function get_prop() {
    local file="$1" prop="$2"
    local value=$(perl -ne "s@^($prop=)@@ && print" "$file")
    dbg "${CMD_INDENT}Getting $prop=$value in $file"
    echo "$value"
} 

function set_prop() {
    local file="$1" prop="$2" value="$3"
    local val0=$(get_prop "$file" "$prop")
    if [ "$val0" != "$value" ]; then
        dbg "${CMD_INDENT}Setting $prop=$value in $file"
        backup_file "$file" || return $?
        if [ -z "$val0" ]; then
            echo "$prop=$value" >> "$file" || return $?
        else
            perl -pe "s@^$prop=.*@$prop=$value@" "$file.orig" > "$file" || return $?
        fi
    else
        dbg "${CMD_INDENT}Not setting $prop=$value in $file"
    fi 
} 

function backup_file() {
    local file="$1" once="$2" orig="${3:-$1.orig}"
    
    if [ -n "$once" ]; then
        [ -f "$orig" ] || cp -a "$file" "$orig"  
    else
        cp -a "$file" "$orig"
    fi
}

#--- phase definitions----------------------------------------------------------
function phase_aes_sp() {
    [ -n "$jarfile" ]                  || usage "<sp_jarfile> missing" 1
    [ -f "$AES_INSTALL_DIR/$jarfile" ] || usage "<sp_jarfile> not found: $AES_INSTALL_DIR/$jarfile" 2
} 

function phase_test() {
    run_cmd sh -c "sleep 10; false"
} 

function phase_wl_inst() {    
    run_cmd_err java -jar "$WL_INSTALL_DIR/wls1036_generic.jar" -mode=silent -silent_xml="$AES_CONF/wl-1036-silent.xml"  -log="$LOGDIR/wl-1036-silent-$(date_format).log"
}

function phase_wl_fixreg() {
    JAVA_VERSION=`java -version 2>&1 | awk -F '"' '/version/ {print $2}'`
    backup_file $BEA_HOME/registry.xml once || return $?
    # FIXME: get values from xml
    perl -pe 'm@(<release level="10.3".*?)>@ && s@@$1 JavaHome="/usr/lib/jvm/java" JavaVersion="'$JAVA_VERSION'" JavaVendor="Sun">@;' \
         -e 'm@(<release level="10.3".*?)>@ && s@( InstallDir)="[^"]*"@$1="'$BEA_HOME/wlserver'"@;' \
         -e 'm@.*</host>@ && s@@    <java-installation Name="jre" JavaHome="/usr/lib/jvm/java" JavaVersion="'$JAVA_VERSION'" JavaVendor="Sun" Architecture="64" Platform="Linux">\n        <dependent-product Name="WebLogic Platform" Version="10.3.6.0"/>\n    </java-installation>\n$&@;' \
        < $BEA_HOME/registry.xml.orig > $BEA_HOME/registry.xml         
}

function phase_aes_inst() {
    set_prop $AES_INST_PROPS Install_Only true || return $? 
    run_cmd_err $AES_CDIMAGE_DIR/setup.bin -i silent -f $AES_INST_PROPS 2>&1 | tee $logfile
}

function phase_aes_sp_inst() {
    run_cmd_err java -jar $AES_INSTALL_DIR/$jarfile -i silent -f $AES_SP_INST_PROPS
} 

function phase_aes_sp_udt_cs() {
    run_cmd_err $DEPOT_ROOT/sourcing/updates/$spname/bin/udt.sh -updateName "$spname" -cs "$AES_SERVER_HOME" -silent -reset
} 

function phase_aes_sp_udt_wc() {
    run_cmd_err $DEPOT_ROOT/sourcing/updates/$spname/bin/udt.sh -updateName "$spname" -wc "$AES_WC_HOME" -silent -reset
}

function phase_aes_cfg_fixsp() {
    cd $AES_SERVER_HOME 
    # there seems to be a core defect InitAppServerSilentConfigurator.readInstallerPropertiesFile(File) - does not store props into Global.sysProps
    set_prop $AES_INST_PROPS Install_Only false || return $?
    backup_file $AES_SERVER_HOME/etc/install/install.sp once || return $?  
    dbg "${CMD_INDENT}Fixing $AES_SERVER_HOME/etc/install/install.sp by appending $AES_INST_PROPS"
    cat $AES_SERVER_HOME/etc/install/install.sp.orig $AES_INST_PROPS > $AES_SERVER_HOME/etc/install/install.sp  
}

function phase_aes_cfg_fixxml() {
    if [ -s "$AES_CONF/weblogic-defaultconfig.xml" ]; then
        cd $AES_SERVER_HOME 
        # there seems to be a core defect InitAppServerSilentConfigurator.readInstallerPropertiesFile(File) - does not store props into Global.sysProps
        backup_file $AES_SERVER_HOME/etc/j2ee/sourcing/weblogic-defaultconfig.xml once || return $?  
        dbg "${CMD_INDENT}Fixing $AES_SERVER_HOME/etc/j2ee/sourcing/weblogic-defaultconfig.xml by replacing with $AES_CONF/weblogic-defaultconfig.xml"
        cp $AES_CONF/weblogic-defaultconfig.xml $AES_SERVER_HOME/etc/j2ee/sourcing/weblogic-defaultconfig.xml
    fi
}

function phase_aes_cfg_fixcore() {
    cd $AES_SERVER_HOME
    file=$AES_SERVER_HOME/lib/perl/Ariba/WebLogic/AdminUtil.pm                  # increase wait time for server startup
    backup_file "$file" once 
    dbg "${CMD_INDENT}Fixing core $file"
    perl -pe '$ourSub=1 if /^sub waitUntilServerIsStarted/; 
              $ourSub=0 if /^\}/; 
              s/sleep\(\d+\)/sleep(90)/ if $ourSub;' \
        "$file.orig" > "$file" || return $?    
}

function phase_aes_cfg_recfg() {
    cd $AES_SERVER_HOME 
    > ia_debug
    run_cmd_err bin/reconfigure -i silent -f $AES_INST_PROPS 
}

function phase_aes_kill() {
    pids=$(ps alx | awk -vORS=' ' '/bin\/sh \/tmp\/ismp/ && $4 == 1 {print $3}')
    if [ -n "$pids" ]; then
        run_cmd kill $pids
    else
        dbg "No leftover processes found -> nothing to kill"
    fi
}

function phase_aes_ptable() {
    cp $AES_CONF/ParametersFix.table.merge $AES_SERVER_HOME/config/ParametersFix.table.merge
    cd $AES_SERVER_HOME 
    run_cmd_err bin/tableedit -script $AES_CONF/script.table
    rm $AES_SERVER_HOME/config/ParametersFix.table.merge
}

#--- main function -------------------------------------------------------------
jarfile="$ARG"
spname="${jarfile%.jar}"

function main() {
    dbg "Started $0 $* > $INST_LOGFILE ($REVISION)\n"

    check_phase aes.sp "Checking Ariba Sourcing SP $spname" "" 1 || return $?
    check_phase test "test" || return $?     
    check_phase wl.inst "Installing Weblogic" || return $? 
    check_phase wl.fixreg "Fixing Weblogic $BEA_HOME/registry.xml" || return $? 
    check_phase aes.inst "Installing Ariba Sourcing" sourcing-install || return $?
    check_phase aes.sp.inst "Installing Ariba Sourcing SP $spname" "$spname-install" || return $?
    check_phase aes.sp.udt.cs "Applying Ariba Sourcing SP $spname Core Server UDT" "$spname-udt-cs" || return $? 
    check_phase aes.sp.udt.wc "Applying Ariba Sourcing SP $spname WebComponents UDT" "$spname-udt-wc" || return $? 
    check_phase aes.cfg.fixsp "Fixing install.sp for Ariba Sourcing" || return $? 
    check_phase aes.cfg.fixxml "Fixing weblogic-defaultconfig.xml for Ariba Sourcing" || return $? 
    check_phase aes.cfg.fixcore "Applying core code fixes for Ariba Sourcing" || return $? 
    check_phase aes.cfg.recfg "Configuring Ariba Sourcing" "sourcing-reconfig" || return $?
    check_phase aes.ptable "Applying custom params" || return $?
    check_phase aes.kill "Killing leftover processes" || return $? 
}

umask 003                                                                       # allow g+w,o+r

main "$@" 2>&1 | tee $INST_LOGFILE
err=$?
exit $err

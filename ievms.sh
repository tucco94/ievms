#!/usr/bin/env bash

export PATH=$PATH:/usr/local/bin/

# Caution is a virtue.
set -o nounset
set -o errtrace
#set -o errexit
#set -o pipefail
set -x
# ## Gobal Variables

# The ievms version.
ievms_version="0.3.1"

WINDOWS_KEY="qqrg9-dmgcd-8v7jg-8d2kk-b6vyj"

# Options passed to each `curl` command.
curl_opts=${CURL_OPTS:-""}

# Reuse XP virtual machines for IE versions that are supported.
reuse_xp=${REUSE_XP:-"no"}

# Reuse Win7 virtual machines for IE versions that are supported.
reuse_win7=${REUSE_WIN7:-"yes"}

# Reuse Win2k8 virtual machines for IE versions that are supported.
reuse_win2k8=${REUSE_WIN2K8:-"no"}

# Timeout interval to wait between checks for various states.
sleep_wait="5"

# Store the original `cwd`.
orig_cwd=`pwd`

# The VM user to use for guest control.
guest_user="IEUser"

# The VM user password to use for guest control.
guest_pass="Passw0rd!"

# ## Utilities

# Print a message to the console.
log()  { printf '%s\n' "$*" ; return $? ; }

# Print an error message to the console and bail out of the script.
fail() { log "\nERROR: $*\n" ; exit 1 ; }

check_md5() {
    local md5

    case $kernel in
        Darwin) md5=`md5 "${1}" | rev | cut -c-32 | rev` ;;
        Linux) md5=`md5sum "${1}" | cut -c-32` ;;
    esac

    if [ "${md5}" != "${2}" ]
    then
        log "MD5 check failed for ${1} (wanted ${2}, got ${md5})"
        return 1
    fi

    log "MD5 check succeeded for ${1}"
}

# Download a URL to a local file. Accepts a name, URL and file.
download() { # name url path md5
local def_ievms_home="${HOME}/.ievms"
ievms_home=${INSTALL_PATH:-$def_ievms_home}


    local attempt=${5:-"0"}
    local max=${6:-"3"}

    let attempt+=1

    if [[ -f "${3}" ]]
    then
        log "Found ${1} at ${3} - skipping download"
        check_md5 "${3}" "${4}" && return 0
        log "Check failed - redownloading ${1}"
        rm -f "${3}"
    fi

    log "Downloading ${1} from ${2} to ${3} (attempt ${attempt} of ${max})"
    curl ${curl_opts} -L "${2}" -o "${3}" || fail "Failed to download ${2} to ${ievms_home}/${3} using 'curl', error code ($?)"
    check_md5 "${3}" "${4}" && return 0

    if [ "${attempt}" == "${max}" ]
    then
        echo "Failed to download ${2} to ${ievms_home}/${3} (attempt ${attempt} of ${max})"
        return 1
    fi

    log "Redownloading ${1}"
    download "${1}" "${2}" "${3}" "${4}" "${attempt}" "${max}"
}

# ## General Setup

# Create the ievms home folder and `cd` into it. The `INSTALL_PATH` env variable
# is used to determine the full path. The home folder is then added to `PATH`.
create_home() {
    local def_ievms_home="${HOME}/.ievms"
    ievms_home=${INSTALL_PATH:-$def_ievms_home}

    mkdir -p "${ievms_home}"
    cd "${ievms_home}"

    PATH="${PATH}:${ievms_home}"

    # Move ovas and zips from a very old installation into place.
    mv -f ./ova/IE*/IE*.{ova,zip} "${ievms_home}/" 2>/dev/null || true
}

# Check for a supported host system (Linux/OS X).
check_system() {
    kernel=`uname -s`
    case $kernel in
        Darwin|Linux) ;;
        *) fail "Sorry, $kernel is not supported." ;;
    esac
}

# Ensure VirtualBox is installed and `VBoxManage` is on the `PATH`.
check_virtualbox() {
    log "Checking for VirtualBox"
    hash VBoxManage 2>&- || fail "VirtualBox command line utilities are not installed, please (re)install! (http://virtualbox.org)"
}

# Determine the VirtualBox version details, querying the download page to ensure
# validity.
check_version() {
    local version=`VBoxManage -v`
    major_minor_release="${version%%[-_r]*}"
    local major_minor="${version%.*}"
    local dl_page=`curl ${curl_opts} -L "http://download.virtualbox.org/virtualbox/" 2>/dev/null`

    if [[ "$version" == *"kernel module is not loaded"* ]]; then
        fail "$version"
    fi

    for (( release="${major_minor_release#*.*.}"; release >= 0; release-- ))
    do
        major_minor_release="${major_minor}.${release}"
        if echo $dl_page | grep "${major_minor_release}/" &>/dev/null
        then
            log "Virtualbox version ${major_minor_release} found."
            break
        else
            log "Virtualbox version ${major_minor_release} not found, skipping."
        fi
    done
}

# Check for the VirtualBox Extension Pack and install if not found.
check_ext_pack() {
    log "Checking for Oracle VM VirtualBox Extension Pack"
    if ! VBoxManage list extpacks | grep "Oracle VM VirtualBox Extension Pack"
    then
        check_version
        local archive="Oracle_VM_VirtualBox_Extension_Pack-${major_minor_release}.vbox-extpack"
        local url="http://download.virtualbox.org/virtualbox/${major_minor_release}/${archive}"
        local md5s="https://www.virtualbox.org/download/hashes/${major_minor_release}/MD5SUMS"
        local md5=`curl ${curl_opts} -L "${md5s}" | grep "${archive}" | cut -c-32`

        download "Oracle VM VirtualBox Extension Pack" "${url}" "${archive}" "${md5}"

        log "Installing Oracle VM VirtualBox Extension Pack from ${ievms_home}/${archive}"
        VBoxManage extpack install "${archive}" || fail "Failed to install Oracle VM VirtualBox Extension Pack from ${ievms_home}/${archive}, error code ($?)"
    fi
}

# Download and install `unar` from Google Code.
install_unar() {
    local url="http://theunarchiver.googlecode.com/files/unar1.5.zip"
    local archive=`basename "${url}"`

    download "unar" "${url}" "${archive}" "fbf544d1332c481d7d0f4e3433fbe53b"

    unzip "${archive}" || fail "Failed to extract ${ievms_home}/${archive} to ${ievms_home}/, unzip command returned error code $?"

    hash unar 2>&- || fail "Could not find unar in ${ievms_home}"
}

# Check for the `unar` command, downloading and installing it if not found.
check_unar() {
    if [ "${kernel}" == "Darwin" ]
    then
        hash unar 2>&- || install_unar
    else
        hash unar 2>&- || fail "Linux support requires unar (sudo apt-get install for Ubuntu/Debian)"
    fi
}

# Pause execution until the virtual machine with a given name shuts down.
wait_for_shutdown() {
    while true ; do
        log "Waiting for ${1} to shutdown..."
        sleep "${sleep_wait}"
        VBoxManage showvminfo "${1}" | grep "State:" | grep -q "powered off" && return 0 || true
    done
}

# Pause execution until guest control is available for a virtual machine.
wait_for_guestcontrol() {
    while true ; do
        log "Waiting for ${1} to be available for guestcontrol..."
        sleep "${sleep_wait}"
        VBoxManage showvminfo "${1}" | grep 'Additions run level:' | grep -q "3" && return 0 || true
    done
}

# Find or download the ievms control ISO.
find_iso() {
    local url="https://dl.dropboxusercontent.com/u/463624/ievms-control-${ievms_version}.iso"
    local dev_iso="${orig_cwd}/ievms-control.iso" # Use local iso if in ievms dev root
    if [[ -f "${dev_iso}" ]]
    then
        iso=$dev_iso
    else
        iso="${ievms_home}/ievms-control-${ievms_version}.iso"
        download "ievms control ISO" "${url}" "${iso}" "6699cb421fc2f56e854fd3f5e143e84c"
    fi
}

# Attach a dvd image to the virtual machine.
attach() {
    log "Attaching ${3}"
    VBoxManage storageattach "${1}" --storagectl "IDE Controller" --port 1 \
        --device 0 --type dvddrive --medium "${2}"
}

# Eject the dvd image from the virtual machine.
eject() {
    log "Ejecting ${2}"
    VBoxManage modifyvm "${1}" --dvd none
}

# Boot the virtual machine with the control ISO in the dvd drive then wait for
# it to do its magic and shut down. For XP images, the "magic" is simply
# enabling guest control without a password. For other images, it installs
# a batch file that runs on first boot to install guest additions and activate
# the OS if possible.
boot_ievms() {
    find_iso
    attach "${1}" "${iso}" "ievms control ISO"
    start_vm "${1}"
    wait_for_shutdown "${1}"
    eject "${1}" "ievms control ISO"
}

# Boot the virtual machine with guest additions in the dvd drive. After running
# `boot_ievms`, the next boot will attempt automatically install guest additions
# if present in the drive. It will shut itself down after installation.
boot_auto_ga() {
    boot_ievms "${1}"
    attach "${1}" "additions" "Guest Additions"
    start_vm "${1}"
    wait_for_shutdown "${1}"
    eject "${1}" "Guest Additions"
}

# Start a virtual machine in headless mode.
start_vm() {
    log "Starting VM ${1}"
    VBoxManage startvm "${1}" --type headless
}

# Copy a file to the virtual machine from the ievms home folder.
copy_to_vm() {
    log "Copying ${2} to ${3}"
    guest_control_exec "${1}" cmd.exe /c copy "E:\\${2}" "${3}"
}

# Execute a command with arguments on a virtual machine.
guest_control_exec() {
    local vm="${1}"
    local image="${2}"
    shift
    VBoxManage guestcontrol "${vm}" run \
        --username "${guest_user}" --password "${guest_pass}" \
        --exe "${image}" -- "$@"
}

# Start an XP virtual machine and set the password for the guest user.
set_xp_password() {
    start_vm "${1}"
    wait_for_guestcontrol "${1}"

    log "Setting ${guest_user} password"
    VBoxManage guestcontrol "${1}" run --username Administrator \
        --password "${guest_pass}" --exe "net.exe" -- \
        net.exe user "${guest_user}" "${guest_pass}"

    log "Setting auto logon password"
    VBoxManage guestcontrol "${1}" run --username Administrator \
        --password "${guest_pass}" --exe "reg.exe" -- reg.exe add \
        "HKLM\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\Winlogon" \
        /f /v DefaultPassword /t REG_SZ /d "${guest_pass}"

    log "Enabling auto admin logon"
    VBoxManage guestcontrol "${1}" run --username Administrator \
        --password "${guest_pass}" --exe "reg.exe" -- reg.exe add \
        "HKLM\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\Winlogon" \
        /f /v AutoAdminLogon /t REG_SZ /d 1
}

# Shutdown an XP virtual machine and wait for it to power off.
shutdown_xp() {
    log "Shutting down ${1}"
    guest_control_exec "${1}" "shutdown.exe" /s /f /t 0
    wait_for_shutdown "${1}"
}

# Install wptdriver and urlblast 
init_wpt_agent(){ # $1 IEVM(_IE8)|Location $2 2.14|"" $3 dda3a3a92924a99a752dea12dd5db470|"" $4 WPT_SERVER_URL
 
	if [ "$1" == "" ]
		then
			WPT_SERVER_LOCATION="IEVM"
		else
			WPT_SERVER_LOCATION="$1"
	fi
	if [ "$4" == "" ]
		then
			WPT_SERVER_URL="localhost"
		else
			WPT_SERVER_URL="$4"
	fi
	log "Location : ${WPT_SERVER_LOCATION}"

	if [ "${2}" == "" ] && [ "${3}" == "" ]
		then
			WPT_LATEST_VERSION=$(curl -v -s -o /dev/null https://github.com/WPO-Foundation/webpagetest/releases/latest 2>&1 |grep  Location |awk -F "/" '{print $NF}'|awk -F'-' '{print $2}'|tr -d '\r')
			WPT_LATEST_MD5=$(curl -L -v -s https://github.com/WPO-Foundation/webpagetest/releases/download/WebPageTest-${WPT_LATEST_VERSION}/webpagetest_${WPT_LATEST_VERSION}.zip 2>/dev/null| md5)
			WPT_VERSION="${WPT_LATEST_VERSION}"
			WPT_MD5="${WPT_LATEST_MD5}"
		else
			WPT_VERSION="$2"
			WPT_MD5="$3"
	fi
	log "WPT version : ${WPT_VERSION}"
	log "WPT md5 : ${WPT_MD5}"

	WPT_ZIP_URL="$(echo https://github.com/WPO-Foundation/webpagetest/releases/download/WebPageTest-${WPT_VERSION}/webpagetest_${WPT_VERSION}.zip)"
	WPT_FILENAME="webpagetest_${WPT_VERSION}.zip"
	log "WPT zip filename ${WPT_ZIP_URL} found in url ${WPT_ZIP_URL}"
}

install_wpt_agent() { # $1 "${vm}|IE6 - WinXP" $2 "${WPT_FILENAME}|webpagetest_${WPT_VERSION}.zip" $3 "${os}|WinXP" 
	start_vm "${1}"
	wait_for_guestcontrol "${1}"
	cd $ievms_home
	local src=`basename "${2}"`
	local dest="\webpagetest"
	log "`pwd`"
	log "${3}"
	os=${3}
	#download "${src}" "${WPT_ZIP_URL}" "${src}" "${WPT_MD5}"
	log "downloading materials"
	if [[ ! -f "webpagetest_${WPT_VERSION}.zip" ]] ; then
		curl -s -L https://github.com/WPO-Foundation/webpagetest/releases/download/WebPageTest-${WPT_VERSION}/webpagetest_${WPT_VERSION}.zip -o webpagetest_${WPT_VERSION}.zip
	fi
	if [[ ! -f "7z.msi" ]] ; then
		curl -s -L http://downloads.sourceforge.net/sevenzip/7z920.msi -o 7z.msi
	fi
	if [[ ! -f "SafariSetup.exe" ]] ; then
		curl -s -L http://appldnld.apple.com/Safari5/041-5487.20120509.INU8B/SafariSetup.exe -o SafariSetup.exe
	fi
	if [[ ! -f "autoit.exe" ]] ; then
		curl -s -L http://www.autoitscript.com/cgi-bin/getfile.pl?autoit3/autoit-v3-setup.exe -o autoit.exe
	fi
	if [[ ! -f "sdelete.exe" ]]; then
		curl -s -L http://download.sysinternals.com/files/SDelete.zip -o sdelete.exe
	fi
	if [[ ! -f "CloudInit.msi" ]]; then
		curl -s -L https://www.cloudbase.it/downloads/CloudbaseInitSetup_Stable_x86.msi -o CloudInit.msi
	fi
	if [[ ! -f "mindinst.exe" ]]; then
		curl -s -L  https://github.com/kalw/webpagetest/raw/master/webpagetest/powershell/mindinst.exe -o mindinst.exe
	fi
	if [[ ! -f "WPOFoundation.cer" ]]; then
		curl -s -L https://github.com/kalw/webpagetest/raw/master/webpagetest/powershell/WPOFoundation.cer -o WPOFoundation.cer
	fi
	if [[ ! -f "certutil.exe" ]]; then
		curl -s -L https://github.com/kalw/webpagetest/raw/master/webpagetest/powershell/certutil.exe -o certutil.exe
	fi
	if [[ ! -f "certcli.dll" ]]; then
		curl -s -L https://github.com/kalw/webpagetest/raw/master/webpagetest/powershell/certcli.dll -o certcli.dll
	fi
	if [[ ! -f "certadm.dll" ]]; then
		curl -s -L https://github.com/kalw/webpagetest/raw/master/webpagetest/powershell/certadm.dll -o certadm.dll
	fi
	#if [[ ! -f "ahk.exe" ]]; then
	#	curl -s -L http://ahkscript.org/download/ahk-install.exe -o ahk.exe
	#fi

if [ "${os}" == "WinXP" ]
then
cat > startup.bat <<'EOF'
echo Set oWS = WScript.CreateObject("WScript.Shell") > startup.vbs
echo sLinkFile = "C:\Documents and Settings\IEUser\Start Menu\Programs\Startup\wptdriver.lnk" >> startup.vbs
echo Set oLink = oWS.CreateShortcut(sLinkFile) >> startup.vbs
echo oLink.TargetPath = "C:\webpagetest\agent\wptdriver.exe" >> startup.vbs
echo oLink.Save >> startup.vbs
echo sLinkFile = "C:\Documents and Settings\IEUser\Start Menu\Programs\Startup\ipfw.lnk" >> startup.vbs
echo Set oLink = oWS.CreateShortcut(sLinkFile) >> startup.vbs
echo oLink.TargetPath = "C:\webpagetest\agent\dummynet\ipfw.cmd" >> startup.vbs
echo oLink.Save >> startup.vbs
cscript startup.vbs
EOF

else
cat > startup.bat <<'EOF'
echo Set oWS = WScript.CreateObject("WScript.Shell") > startup.vbs
echo sLinkFile = "C:\Users\IEUser\AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup\wptdriver.lnk" >> startup.vbs
echo Set oLink = oWS.CreateShortcut(sLinkFile) >> startup.vbs
echo oLink.TargetPath = "C:\webpagetest\agent\wptdriver.exe" >> startup.vbs
echo oLink.Save >> startup.vbs
echo sLinkFile = "c:\Users\IEUser\AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup\ipfw.lnk" >> startup.vbs
echo Set oLink = oWS.CreateShortcut(sLinkFile) >> startup.vbs
echo oLink.TargetPath = "C:\webpagetest\agent\dummynet\ipfw.cmd" >> startup.vbs
echo oLink.Save >> startup.vbs
cscript startup.vbs
EOF
fi

	
	log "extracting sample configuration"
	unzip -joe webpagetest_${WPT_VERSION}.zip agent/urlBlast.ini.sample
	unzip -joe webpagetest_${WPT_VERSION}.zip agent/wptdriver.ini.sample
	
	log "create wpt directory"
	#create_dir_to_vm "${1}" "webpagetest" "C:\\"
	guest_control_exec "${1}" "cmd.exe" /c \
		"mkdir c:\\webpagetest"
	log "copying material to guest"
	copy_to_vm "${1}" "7z.msi" "${dest}\7z.msi"
	copy_to_vm "${1}" "SafariSetup.exe" "${dest}\SafariSetup.exe"
	copy_to_vm "${1}" "webpagetest_${WPT_VERSION}.zip" "${dest}\webpagetest_${WPT_VERSION}.zip"
	copy_to_vm "${1}" "autoit.exe" "${dest}\autoit.exe"
	copy_to_vm "${1}" "sdelete.exe" "${dest}\sdelete.exe"
	copy_to_vm "${1}" "CloudInit.msi" "${dest}\CloudInit.msi"
	copy_to_vm "${1}" "mindinst.exe" "${dest}\mindinst.exe"
	copy_to_vm "${1}" "WPOFoundation.cer" "${dest}\WPOFoundation.cer"
	copy_to_vm "${1}" "certutil.exe" "${dest}\certutil.exe"
	copy_to_vm "${1}" "certcli.dll" "${dest}\certcli.dll"
	copy_to_vm "${1}" "certadm.dll" "${dest}\certadm.dll"
	copy_to_vm "${1}" "startup.bat" "${dest}\startup.bat"
	#copy_to_vm "${1}" "ahk.exe" "${dest}\ahk.exe"
	log "copying configuration"
	sed -e "s/url=.*/url=http:\/\/${WPT_SERVER_URL}\//" -e "s/location=.*/location=${WPT_SERVER_LOCATION}_WPT/" -e "s/IE/IE_${ver}/" wptdriver.ini.sample > wptdriver.ini
	copy_to_vm "${1}" "wptdriver.ini" "${dest}\wptdriver.ini"
	sed -e "s/Url=.*/Url=http:\/\/${WPT_SERVER_URL}\/work/" -e "s/Location=.*/location=${WPT_SERVER_LOCATION}_IE/" -e "s/IE/IE_${ver}/" urlBlast.ini.sample > urlBlast.ini
	copy_to_vm "${1}" "urlBlast.ini" "${dest}\urlBlast.ini"
	

	
	log "will echo"
	guest_control_exec "${1}" "cmd.exe" /c \
		"echo @ECHO ON >>c:\\webpagetest\\wpt.bat"
	

	log "Installing 7z"
	guest_control_exec "${1}" "cmd.exe" /c \
		"echo start /wait msiexec /i C:\webpagetest\7z.msi /quiet /q INSTALLDIR=C:\7zip >>c:\\webpagetest\\wpt.bat"
	log "Unzip wpt agent"
	guest_control_exec "${1}" "cmd.exe" /c \
		"echo c:\7zip\7z.exe x c:\webpagetest\webpagetest_${WPT_VERSION}.zip -y -oc:\webpagetest agent/* >>c:\\webpagetest\\wpt.bat"
	log "Installing winpcap"
	guest_control_exec "${1}" "cmd.exe" /c \
		"echo start /wait c:\webpagetest\agent\winpcap-nmap-4.12.exe /S >> c:\\webpagetest\\wpt.bat"
	log "Intalling AviSynth"
	#guest_control_exec "${1}" "cmd.exe" /c \
	#	"echo start /wait c:\webpagetest\agent\Avisynth_258.exe /S >>c:\\webpagetest\\wpt.bat"

	log "Intalling Safari"
	guest_control_exec "${1}" "cmd.exe" /c \
		"echo start /wait c:\webpagetest\SafariSetup.exe /quiet >>c:\\webpagetest\\wpt.bat"
	log "Intalling AutoIT"
	guest_control_exec "${1}" "cmd.exe" /c \
		"echo start /wait c:\webpagetest\autoit.exe /S /D=C:\AutoIT >>c:\\webpagetest\\wpt.bat"
	log "Installing Cloudbase-init"
	guest_control_exec "${1}" "cmd.exe" /c \
		"echo start /wait msiexec /i c:\webpagetest\CloudbaseInitSetup.msi /qn /l*v log.cloudbase.txt >>c:\\webpagetest\\wpt.bat"
	#log "Installing AHK"
	#guest_control_exec "${1}" "cmd.exe" /c \
	#	"echo start /wait c:\webpagetest\ahk.exe /S /D=C:\AutoHotKey >>c:\\webpagetest\\wpt.bat"
    #log "Disable Screensaver"
	#guest_control_exec "${1}" "cmd.exe" /c \
	#	"echo REG ADD \\HKCU\\Control Panel\\Desktop\\ /v ScreenSaveActive /t REG_SZ /d 0 /f >>c:\webpagetest\wpt.bat" # TODO escapeing does not work properly
	log "Using stable clock"
	guest_control_exec "${1}" "cmd.exe" /c \
		"echo bcdedit /set {default} useplatformclock true >>c:\\webpagetest\\wpt.bat"
		
	log "pre-install dummynet driver"
	guest_control_exec "${1}" "cmd.exe" /c \
		"echo copy c:\webpagetest\agent\dummynet\64bit\*.*  c:\webpagetest\agent\dummynet >>c:\\webpagetest\\wpt.bat"
	
	log "clean disk content"
	guest_control_exec "${1}" "cmd.exe" /c \
		"echo cleanmgr.exe /d C /sagerun:11 >>c:\\webpagetest\\wpt.bat"
	
	log "optimize disk space"
	guest_control_exec "${1}" "cmd.exe" /c \
		"echo c:\webpagetest\sdelete.exe -z c: >>c:\\webpagetest\\wpt.bat"
	
	log "copy configuration"
	guest_control_exec "${1}" "cmd.exe" /c \
	"echo copy c:\webpagetest\wptdriver.ini  c:\webpagetest\agent\ >>c:\\webpagetest\\wpt.bat"
	guest_control_exec "${1}" "cmd.exe" /c \
	"echo copy c:\webpagetest\urlBlast.ini  c:\webpagetest\agent\ >>c:\\webpagetest\\wpt.bat"
	#guest_control_exec "${1}" "cmd.exe" /c \
	#"echo slmgr -ipk ${WINDOWS_KEY} >>c:\\webpagetest\\wpt.bat"
	#guest_control_exec "${1}" "cmd.exe" /c \
	#"echo slmgr -ato >>c:\\webpagetest\\wpt.bat"
	guest_control_exec "${1}" "cmd.exe" /c \
		"echo start c:\webpagetest\startup.bat >>c:\\webpagetest\\wpt.bat"
	guest_control_exec "${1}" "cmd.exe" /c \
		"echo start /wait schtasks /create /tn wptdriver /tr c:\webpagetest\agent\wptdriver.exe /sc onlogon  >>c:\\webpagetest\\wpt.bat"

	if [ "${3}" == "WinXP" ]
	then
		echo "XP"
	else
	#	log "Disable UAC"
	#	guest_control_exec "${1}" "cmd.exe" /c \
	#	"echo REG ADD \\HKLM\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\Winlogon\\ /f /v AutoAdminLogon /t REG_SZ /d 1 >>c:\webpagetest\wpt.bat" # todo: escapeing does not work properly
		echo "NOT XP"
	fi
	

	if [ "${3}" == "WinXP" ]
	then
		guest_control_exec "${1}" "cmd.exe" /c \
			"c:\\webpagetest\\wpt.bat"
		log 'netipfw.install.xp'
		guest_control_exec "${1}" "cmd.exe" /c \
			"c:\\webpagetest\\certutil –addstore –f TrustedPublisher c:\\webpagetest\\WPOFoundation.cer "
		guest_control_exec "${1}" "cmd.exe" /c \
			"c:\\webpagetest\\mindinst.exe c:\\webpagetest\\agent\\dummynet\\32bit\\netipfw.inf -i -s "

	else
		log "on correct directory"
		guest_control_exec "${1}" "cmd.exe" /c \
			"cd /windows/system32/"
		log "Disable LUA"
		guest_control_exec "${1}" "cmd.exe" /c \
                "echo start /wait %windir%\System32\reg.exe ADD HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System /v EnableLUA /t REG_DWORD /d 0 /f >>c:\webpagetest\wpt.bat"
                log "Disable driver installation integrity checks"
                guest_control_exec "${1}" "cmd.exe" /c \
                        "bcdedit.exe -set nointegritychecks ON >>c:\\webpagetest\\wpt.bat"
                guest_control_exec "${1}" "cmd.exe" /c \
                        "bcdedit.exe -set TESTSIGNING ON >>c:\\webpagetest\\wpt.bat"
                guest_control_exec "${1}" "cmd.exe" /c \
                        "bcdedit /set {default} bootstatuspolicy ignoreallfailures >>c:\\webpagetest\\wpt.bat"
                guest_control_exec "${1}" "cmd.exe" /c \
			             "copy c:\webpagetest\wpt.bat C:\Users\\${guest_user}\\ievms.bat"
                guest_control_exec "${1}" "schtasks.exe" /run /tn ievms

		guest_control_exec "${1}" "cmd.exe" /c \
			"echo start Certutil –addstore –f TrustedPublisher c:\\webpagetest\\WPOFoundation.cer >>c:\\webpagetest\\wpt.bat"
		guest_control_exec "${1}" "cmd.exe" /c \
			"echo start  c:\\webpagetest\\mindinst.exe c:\\webpagetest\\agent\\dummynet\\netipfw.inf -i -s >>c:\\webpagetest\\wpt.bat"
		guest_control_exec "${1}" "cmd.exe" /c \
			"copy c:\webpagetest\wpt.bat C:\Users\\${guest_user}\\ievms.bat"
		guest_control_exec "${1}" "schtasks.exe" /run /tn ievms
	fi
	
	# powersavings autoit script tbd
	# firewall autoit script tbd
	
	
	if [ "${3}" == "Win2k8" ]
	then
		log "Disable IE ESC"
		VBoxManage guestcontrol "${1}" run  "reg.exe" --username \
			Administrator --password "${guest_pass}"  -- add \
			"HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Active Setup\Installed Components\{A509B1A7-37EF-4b3f-8CFC-4F3A74704073}" \
			/v “IsInstalled” /t REG_DWORD /d 0 /f
		VBoxManage guestcontrol "${1}" run  "reg.exe" --username \
			Administrator --password "${guest_pass}"  -- add \
			"HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Active Setup\Installed Components\{A509B1A8-37EF-4b3f-8CFC-4F3A74704073}" \
			/v “IsInstalled” /t REG_DWORD /d 0 /f
		guest_control_exec "${1}" "cmd.exe" /c \
			"Rundll32 iesetup.dll,IEHardenUser"
		guest_control_exec "${1}" "cmd.exe" /c \
			"Rundll32 iesetup.dll,IEHardenAdmin"
		guest_control_exec "${1}" "cmd.exe" /c \
			"Rundll32 iesetup.dll,IEHardenMachineNow"
		VBoxManage guestcontrol "${1}" run  "reg.exe" --username \
			Administrator --password "${guest_pass}"  -- add \
			"HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Setup\OC Manager\Subcomponents" \
			/v “iehardenadmin” /t REG_DWORD /d 0 /f
		VBoxManage guestcontrol "${1}" run  "reg.exe" --username \
			Administrator --password "${guest_pass}"  -- add \
			"HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Setup\OC Manager\Subcomponents" \
			/v “iehardenuser” /t REG_DWORD /d 0 /f
		VBoxManage guestcontrol "${1}" run "reg.exe" --username \
			Administrator --password "${guest_pass}"  -- delete \
			"HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Active Setup\Installed Components\{A509B1A7-37EF-4b3f-8CFC-4F3A74704073}" \
			/f /va
		VBoxManage guestcontrol "${1}" run  "reg.exe" --username \
			Administrator --password "${guest_pass}"  -- delete \
			"HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Active Setup\Installed Components\{A509B1A8-37EF-4b3f-8CFC-4F3A74704073}" \
			/f /va
	fi
}

# Install an alternative version of IE in an XP virtual machine. Downloads the
# installer, copies it to the vm, then runs it before shutting down.
install_ie_xp() { # vm url md5
    local src=`basename "${2}"`
    local dest="C:\\Documents and Settings\\${guest_user}\\Desktop\\${src}"

    download "${src}" "${2}" "${src}" "${3}"
    copy_to_vm "${1}" "${src}" "${dest}"

    log "Installing IE" # Always "fails"
    guest_control_exec "${1}" "${dest}" /passive /norestart || true

    shutdown_xp "${1}"
}

# Install an alternative version of IE in a Win7 virtual machine. Downloads the
# installer, copies it to the vm, then runs it before shutting down.
install_ie_win7() { # vm url md5
    local src=`basename "${2}"`
    local dest="C:\\Users\\${guest_user}\\Desktop\\${src}"

    download "${src}" "${2}" "${src}" "${3}"
    start_vm "${1}"
    wait_for_guestcontrol "${1}"
    copy_to_vm "${1}" "${src}" "${dest}"

    log "Installing IE"
    guest_control_exec "${1}" "cmd.exe" /c \
        "echo ${dest} /passive /norestart >C:\\Users\\${guest_user}\\ievms.bat"
    guest_control_exec "${1}" "cmd.exe" /c \
        "echo shutdown.exe /s /f /t 0 >>C:\\Users\\${guest_user}\\ievms.bat"
    guest_control_exec "${1}" "schtasks.exe" /run /tn ievms

    wait_for_guestcontrol "${1}"
}


# Install an alternative version of IE in a Win2k8 virtual machine. Downloads the
# installer, copies it to the vm, then runs it before shutting down.
install_ie_win2k8() { # vm url md5
    local src=`basename "${2}"`
    local dest="C:\\Users\\${guest_user}\\Desktop\\${src}"

    download "${src}" "${2}" "${src}" "${3}"
    start_vm "${1}"
    wait_for_guestcontrol "${1}"
    copy_to_vm "${1}" "${src}" "${dest}"

    log "Installing IE"
    guest_control_exec "${1}" "cmd.exe" /c \
        "echo ${dest} /passive /norestart >C:\\Users\\${guest_user}\\ievms.bat"
    guest_control_exec "${1}" "cmd.exe" /c \
        "echo shutdown.exe /s /f /t 0 >>C:\\Users\\${guest_user}\\ievms.bat"
    guest_control_exec "${1}" "schtasks.exe" /run /tn ievms

    wait_for_guestcontrol "${1}"

    guest_control_exec "${1}" "shutdown.exe" /s /f /t 0
    wait_for_shutdown "${1}"
}

# Build an ievms virtual machine given the IE version desired.
build_ievm() {
    unset archive
    unset unit
    local prefix="IE"
    local version="${1}"
    case $1 in
        6|7|8)
            os="WinXP"
            if [ "${reuse_xp}" != "yes" ]
            then
                if [ "$1" == "6" ]; then unit="10"; fi
                if [ "$1" == "7" ]; then os="Vista"; fi
                if [ "$1" == "8" ]; then os="Win7"; fi
            else
                archive="IE6_WinXP.zip"
                unit="10"
            fi
            ;;
        9) os="Win7" ;;
        10|11)
            if [ "${reuse_win7}" != "yes" ]
            then if [ "$1" == "11" ]; then fail "IE11 is only available if REUSE_WIN7 is set"; fi
                os="Win2k8"
 	else
                os="Win7"
                archive="IE9_Win7.zip"
            fi
	    ;;
	    
	9) os="Win2k8" ;;
	10|11)
	     if [ "${reuse_win2k8}" != "yes" ]
		then if [ "$1" == "11" ]; then fail "IE11 is only avaiblable if REUSE_WIN2K8 is set"; fi
                   os="Win8"
	else
		  os="Win2k8"
		  archive="IE9_Win2k8.zip"
	     fi
	     ;;
	EDGE)
            prefix="MS"
            version="Edge"
            os="Win10"
            unit="8"
            ;;
        *) fail "Invalid IE version: ${1}" ;;
    esac

    local vm="${prefix}${version} - ${os}"
    local def_archive="${vm/ - /_}.zip"
    archive=${archive:-$def_archive}
    unit=${unit:-"11"}
    local ova=`basename "${archive/_/ - }" .zip`.ova

    local url
    if [ "${os}" == "Win10" ]
    then
        url="https://az792536.vo.msecnd.net/vms/VMBuild_20150801/VirtualBox/MSEdge/Mac/Microsoft%20Edge.Win10.For.Mac.VirtualBox.zip"
    else
        url="http://virtualization.modern.ie/vhd/IEKitV1_Final/VirtualBox/OSX/${archive}"
    fi

    local md5
    case $archive in
        IE6_WinXP.zip) md5="3d5b7d980296d048de008d28305ca224" ;;
        IE7_Vista.zip) md5="d5269b2220f5c7fb9786dad513f2c05a" ;;
        #IE8_Win2k8.zip) md5="9e491948286ed3015f695cb49c939776" ;;
	IE8_Win7.zip) md5="21b0aad3d66dac7f88635aa2318a3a55" ;;
        IE9_Win7.zip) md5="58d201fe7dc7e890ad645412264f2a2c" ;;
        IE9_Win2k8.zip) md5="a69086febf216cb8452495f1aeb64d5e" ;;
	IE10_Win2k8.zip) md5="8c8620cb1ee4c4ce17f6f2d95d5fff56" ;;
	IE10_Win8.zip) md5="cc4e2f4b195e1b1e24e2ce6c7a6f149c" ;;
        MSEdge_Win10.zip) md5="c1011b491d49539975fb4c3eeff16dae" ;;
    esac
    
    log "Checking for existing OVA at ${ievms_home}/${ova}"
    if [[ ! -f "${ova}" ]]
    then
        download "OVA ZIP" "${url}" "${archive}" "${md5}"

        log "Extracting OVA from ${ievms_home}/${archive}"
        unar "${archive}" || fail "Failed to extract ${archive} to ${ievms_home}/${ova}, unar command returned error code $?"
    fi

    log "Checking for existing ${vm} VM"
    if ! VBoxManage showvminfo "${vm}" >/dev/null 2>/dev/null
    then
        local disk_path="${ievms_home}/${vm}-disk1.vmdk"
        log "Creating ${vm} VM (disk: ${disk_path})"
        VBoxManage import "${ova}" --vsys 0 --vmname "${vm}" --unit "${unit}" --disk "${disk_path}"

        log "Adding shared folder"
        VBoxManage sharedfolder add "${vm}" --automount --name ievms \
            --hostpath "${ievms_home}"

        log "Building ${vm} VM"
        declare -F "build_ievm_ie${1}" && "build_ievm_ie${1}"

        log "Tagging VM with ievms version"
        VBoxManage setextradata "${vm}" "ievms" "{\"version\":\"${ievms_version}\"}"

        log "Creating clean snapshot"
        VBoxManage snapshot "${vm}" take clean --description "The initial VM state"
	sleep 200

# Shutdown the Vm to finish installation

        log "Shutting down vm"
        guest_control_exec "${vm}" "shutdown.exe" /s /f /t 0
        wait_for_shutdown "${vm}"

        log "restart the vm "
        start_vm "${vm}"
fi
}

# Build the IE6 virtual machine.
build_ievm_ie6() {
    set_xp_password "IE6 - WinXP"
	install_wpt_agent "IE6 - WinXP" "${WPT_FILENAME}" "${os}" # IE6 is unsupported by WPT
    shutdown_xp "IE6 - WinXP"
}

# Build the IE7 virtual machine, reusing the XP VM if requested (the default).
build_ievm_ie7() {
    if [ "${reuse_xp}" != "yes" ]
    then
        boot_auto_ga "IE7 - Vista"
    else
        set_xp_password "IE7 - WinXP"
		install_wpt_agent "IE7 - WinXP" "${WPT_FILENAME}" "${os}"
        install_ie_xp "IE7 - WinXP" "http://download.microsoft.com/download/3/8/8/38889dc1-848c-4bf2-8335-86c573ad86d9/IE7-WindowsXP-x86-enu.exe" "ea16789f6fc1d2523f704e8f9afbe906"
    fi
}

# Build the IE8 virtual machine, reusing the XP VM if requested (the default).
build_ievm_ie8() {
    if [ "${reuse_xp}" != "yes" ]
    then
        boot_auto_ga "IE8 - Win7"
                install_wpt_agent "IE8 - Win7" "${WPT_FILENAME}" "${os}"
else
        set_xp_password "IE8 - WinXP"
		install_wpt_agent "IE8 - WinXP" "${WPT_FILENAME}" "${os}"
        install_ie_xp "IE8 - WinXP" "http://download.microsoft.com/download/C/C/0/CC0BD555-33DD-411E-936B-73AC6F95AE11/IE8-WindowsXP-x86-ENU.exe" "616c2e8b12aaa349cd3acb38bf581700"
    fi
}

# Build the IE9 virtual machine 
build_ievm_ie9() {
	if [ "${reuse_win7}" != "yes" ]
   then
	boot_auto_ga "IE9 - Win2k8"
	install_wpt_agent "IE9 - Win2k8" "${WPT_FILENAME}" "${os}"

   else
	boot_auto_ga "IE9 - Win7"
	install_wpt_agent "IE9 - Win7" "${WPT_FILENAME}" "${os}"
   fi
}

# Build the IE10 virtual machine, reusing the Win2k8 VM or Win7 image
build_ievm_ie10() {
    if [ "${reuse_win7}" != "yes" ]
    then
        boot_auto_ga "IE10 - Win2k8"
	install_wpt_agent "IE10 - Win2k8" "${WPT_FILENAME}" "${os}"
	install_ie_win2k8  "IE10 - Win2k8" "http://download.microsoft.com/download/C/E/0/CE0AB8AE-E6B7-43F7-9290-F8EB0EA54FB5/IE10-Windows6.1-x64-en-us.exe" "7ca1f1f4ab4e9599e2fa79d2684562da"
    else 
        boot_auto_ga "IE10 - Win7"
		install_wpt_agent "IE10 - Win7" "${WPT_FILENAME}" "${os}"
        install_ie_win7 "IE10 - Win7" "http://download.microsoft.com/download/8/A/C/8AC7C482-BC74-492E-B978-7ED04900CEDE/IE10-Windows6.1-x86-en-us.exe" "0f14b2de0b3cef611b9c1424049e996b"
    fi
}

# Build the IE11 virtual machine, reusing Win2k8 or Win7 image 
build_ievm_ie11() {
    if [ "${reuse_win7}" != "yes" ]
    then
	boot_auto_ga "IE11 - Win2k8"
	install_wpt_agent "IE11 -Win2k8" "${WPT_FILENAME}" "${os}"
	install_ie_win2k8 "IE11 - Win2k8" "https://download.microsoft.com/download/7/1/7/7179A150-F2D2-4502-9D70-4B59EA148EAA/IE11-Windows6.1-x64-en-us.exe" "839a1a4d5043d694cd324c33937e00ae"
    else
    	boot_auto_ga "IE11 - Win7"
	install_wpt_agent "IE11 - Win7" "${WPT_FILENAME}" "${os}"
        install_ie_win7 "IE11 - Win7" "http://download.microsoft.com/download/9/2/F/92FC119C-3BCD-476C-B425-038A39625558/IE11-Windows6.1-x86-en-us.exe" "7d3479b9007f3c0670940c1b10a3615f"
    fi
}

## ## Main Entry Point
#


## tests
ver=8
#install_wpt_agent "IE8 - WinXP" "${WPT_FILENAME}" "WinXP"
#exit
## </tests>
## Run through all checks to get the host ready for installation.
check_system
create_home
check_virtualbox
check_ext_pack
check_unar
#
## Install each requested virtual machine sequentially.
#all_versions="6 7 8 9 10 11 EDGE" IE6 et 7 will not work w/wptdriver ; urlblast only
all_versions="8 9 10 11"
IEVMS_VERSIONS="9"
for ver in ${IEVMS_VERSIONS:-$all_versions}
do
	### wpt
	init_wpt_agent "IEVM_IE${ver}" "2.18" "c92c2257a9a3efe265b52876bd0417bb" "perfs.digitas.fr" # "" $1 IEVM(_IE8)|"" $2 2.14|"" $3 dda3a3a92924a99a752dea12dd5db470|"" $4 WPT_SERVER_URL
    log "Building IE ${ver} VM"
    build_ievm $ver

	
done
    

# We made it!
log "Done!"

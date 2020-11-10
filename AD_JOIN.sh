#--/bin/bash
#
#
#Script by me@rhsameera.com | https://sam.rhsameera.com

#--variables-------------
Centos_FILE=/etc/centos-release
Oracle_FILE=/etc/oracle-release
sudoers_backup_path=/root/sudoers_bak
sudoers_backup_file=$sudoers_backup_path/$(date +"%m-%d-%Y_%H").bak
Ssh_Allow=SSH_ALLOW_ALL_SECURITY_GROUP
Sudoers_group=SUDORES_SECURITY_GROUP
Computer_OU="ou=lastOU,ou=LINUX_SERVERS,ou=1stou,dc=test,dc=local"
domain=test.local

#--Sub Scripts---------------
if [ -f "$Centos_FILE" ]; then
        os_release=$(cat $Centos_FILE)
        os_version=$(cat $Centos_FILE | sed -e 's#.*release \(\)#\1#')
elif [ -f "$Oracle_FILE" ]; then
        os_release=$(cat $Oracle_FILE)
        os_version=$(cat $Oracle_FILE | sed -e 's#.*release\(\)#\1#')
fi

#--Get User Account------
echo "Enter Domain Administrator Account"
read useraccount

#--Main Script-----------
#--Install realm sssd and dependencies
yum install sssd realmd oddjob oddjob-mkhomedir adcli samba-common samba-common-tools krb5-workstation openldap-clients policycoreutils-python -y


echo "Joining Domain..."
realm join --computer-ou=$Computer_OU --os-name="$os_release" --os-version="$os_version" --user=$useraccount $domain
#--Configuring SSH access and Sudoers
realm permit -g $Ssh_Allow -R $domain
sed -i 's|use_fully_qualified_names = True|use_fully_qualified_names = False|g' /etc/sssd/sssd.conf
sed -i 's\/home/%u@%d\home/%u\g' /etc/sssd/sssd.conf
echo "override_homedir = /home/%u">> /etc/sssd/sssd.conf
mkdir $sudoers_backup_path
mv /etc/sudoers.d/sudoers $sudoers_backup_file
echo "%$Sudoers_group ALL=(ALL:ALL) ALL">> /etc/sudoers.d/sudoers
systemctl restart sssd
systemctl daemon-reload
domain_list=$(realm list)
echo "  Joined $domain Successfully..."
sleep 3
echo "  OU 			= $Computer_OU                  	"
echo "  OS Release 	= $os_release                       "
echo "  OS Version 	= $os_version                       "
echo "                                                  "
echo "  ############################################### "
echo "  $Sudoers_group added to the sudoers group    "
echo "                                                  "
echo "  old sudoers file moved to $sudoers_backup_file  "
echo "  ############################################### "
echo "                                                  "
echo "##########---realm list output----------##########"
echo "                                                  "
echo "  			$domain_list                        "


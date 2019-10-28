Package {
  allow_virtual => true,
}

# those are necessary to run the install of oracle-rdbms-server-11gR2-preinstall
#"sudo wget https://public-yum.oracle.com/public-yum-ol6.repo -P /etc/yum.repos.d --no-check-certificate"
#"sudo wget https://public-yum.oracle.com/RPM-GPG-KEY-oracle-ol6 -O /etc/pki/rpm-gpg/RPM-GPG-KEY-oracle --no-check-certificate"

class yum {

  $oracle_repo = "public-yum.oracle.com"
  #yumrepo {
  #  "public-yum.oracle.com":
  #    descr    => "Oracle Linux 6",
  #    baseurl  => "https://$oracle_repo/public-yum-ol6.repo",
  #    gpgkey   => "https://$oracle_repo/RPM-GPG-KEY-oracle-ol6",
  #    sslverify=> "false",
  #    gpgcheck => "1",
  #    enabled  => "1";
  #}

  exec {'yum oracle':
    command => "/usr/bin/wget https://$oracle_repo/public-yum-ol6.repo -P /etc/yum.repos.d --no-check-certificate",
    creates => "/etc/yum.repos.d/public-yum-ol6.repo",
  }

  exec {'GPG Key':
    command => "/usr/bin/wget https://$oracle_repo/RPM-GPG-KEY-oracle-ol6 -O /etc/pki/rpm-gpg/RPM-GPG-KEY-oracle --no-check-certificate",
    creates => "/etc/pki/rpm-gpg/RPM-GPG-KEY-oracle",
  }
}

class { 'java' : 
  distribution  => 'jdk',
  #version      => 'latest',
  package       => 'java-1.6.0-openjdk-devel'
}

class oracledb {
  require java
  require yum
  require oracle::swap

  class { "oracle::server" :
    oracle_user  => "oracle",
    dba_group    => "dba",
    sid          => "aribadb",
    oracle_root  => "/oracle",
    password     => "oracle",
    host_name    => hiera('db_hostname'),
  }

    file {
    ["/home/oracle", "/home/oracle/db"]:
      ensure  => "directory",
      mode    => 0701,
      owner   => oracle,
      require => Class["oracle::server"];

    "/home/oracle/aribadb.sql":
      ensure  => "file",
      mode    => 0744,
      owner   => oracle,
      source  => "/vagrant/puppet/install_ariba/database/aribadb.sql",
      require => Class["oracle::server"];
  } 

  exec {
    'run-script':
      command   => "bash -c 'source /etc/profile.d/ora.sh && sqlplus system/oracle@aribadb @aribadb.sql'",
      cwd       => '/home/oracle',
      path      => '/usr/bin:/bin:/oracle/app/oracle/product/11.2.0/dbhome_1/bin',
      user      => oracle,
      logoutput => on_failure,
      require   => File["/home/oracle/aribadb.sql"];
  }
}

include java
include oracledb

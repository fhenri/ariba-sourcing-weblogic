#!/bin/bash

mkdir -p /etc/puppet/modules;

if [ ! -d /etc/puppet/modules/puppetlabs-java ]; then
  puppet module install puppetlabs-java --version 1.4.1
fi

#!/usr/bin/perl
#
# CiscoDevice example: "Reverse Telnet"
#
#	This example shows how to connect to a remote cisco device via a 
#	reverse telnet connection. In the networking world its common to
#	have an OOB router that is connected to several other devices
#	via a serial cable. You can connect to these devices by telneting
#	to the OOB on the specific port for each serial cable connected.
#	This is called a "Reverse Telnet" connection.
#

use strict;
use warnings;
use FindBin;
use FileHandle;
use IPC::Open2;

use lib ($FindBin::Bin . '/../lib');
use CiscoDevice;

my $host = '192.168.0.1';
my $port = 2033;
my $dev = new CiscoDevice(command => 'telnet', host => $host, port => $port, wakeup => 1);
#$dev->wakeup(1); # not needed if "wakeup => 1" is passed to the object above.
die "Not connected...\n" unless $dev and $dev->connected;
print $dev->send("show version");

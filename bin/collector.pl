#!/usr/bin/perl

# The MIT License (MIT)
#
# Copyright (c) 2014 John Jensen
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.

use strict;
use warnings;
use SNMP;
use SNMP::Multi;
use YAML qw/LoadFile/;
use Log::Log4perl qw/get_logger/;
use Parallel::ForkManager;
use IO::Socket::INET;
use Python::Serialise::Pickle qw();

# technically you only need:
# &SNMP::loadModules('IF-MIB');
# for this poller to function properly, but I'm going to go out on a limb and
# assume people have other custom MIBs they want to load. :P
&SNMP::loadModules('ALL');
&SNMP::initMib();

#this could be done better with something like GetOpt::Long
Log::Log4perl::init("/path/to/logging.conf");
my $logger = get_logger("collector");

# set to number of cores etc
my $pm = Parallel::ForkManager->new(16);
my $polled = LoadFile('/path/to/polling.yaml');

# we assume that the carbon instance is on the same host as this poller is running from.
# obviously does not have to be as such. Can also be factored into cmdline options?
my $carbon_server = 'localhost';
my $carbon_port = 2004;


# I thought keeping track of the SNMP datatypes might be useful for some reason
# maybe later on down the road.
my %metric_types = (
    'ifHCInOctets'          => 'Counter64',
    'ifHCInUcastPkts'       => 'Counter64',
    'ifHCInMulticastPkts'   => 'Counter64',
    'ifHCInBroadcastPkts'   => 'Counter64',
    'ifInErrors'            => 'Counter32',
    'ifInDiscards'          => 'Counter32',
    'ifHCOutOctets'         => 'Counter64',
    'ifHCOutUcastPkts'      => 'Counter64',
    'ifHCOutMulticastPkts'  => 'Counter64',
    'ifHCOutBroadcastPkts'  => 'Counter64',
    'ifOutErrors'           => 'Counter32',
    'ifOutDiscards'         => 'Counter32',
);

my $vars = [];
foreach my $oid (sort keys %metric_types) {
    push @$vars, [ $oid ];
}

# bulkwalks don't quite work right unless you kick them off with some arbitrary query.
# this is probably something i'm not setting properly in the SNMP::Multi session constructor,
# but this worked well enough so i never bothered looking into it.
unshift @$vars, [ 'sysUpTime' ];

my $start_time = time();

foreach my $comm (keys %{$polled}) {
    $pm->start and next;
    # this basically forks a separate process per each SNMP community string
    # you have defined in the device YAML spec.

    my $sock = IO::Socket::INET->new(
        PeerAddr => $carbon_server,
        PeerPort => $carbon_port,
        Proto    => 'tcp'
    );
    $logger->logdie("Unable to connect: $!") unless ($sock->connected);

    my $req = SNMP::Multi::VarReq->new (
        nonrepeaters => 1,
        hosts => [ keys %{$polled->{$comm}} ],
        vars => $vars,
    );

    $logger->logdie("VarReq: $SNMP::Multi::VarReq::error") unless $req;

    my $sm = SNMP::Multi->new (
        Method      => 'bulkwalk',
        # MaxSessions can be tuned - I've been running fine at 16
        # however the maintainer of SNMP::Multi has also been fine
        # with tweaking it to 512 (!)
        MaxSessions => 16,
        Community   => $comm,
        Version     => '2c',
        Timeout     => 5,
        Retries     => 3,
        UseNumeric  => 1,
    )
    or logger->logdie("$SNMP::Multi::error");

    $sm->request($req) or $logger->logdie($sm->error);
    my $resp = $sm->execute() or $logger->logdie("Execute: $SNMP::Multi::error");

    foreach my $host ($resp->hosts()) {

        my $int_data = [];

        foreach my $result ($host->results()) {
            if ($result->error()) {
                $logger->error("Error with $host: ", $result->error());
                next;
            }

            foreach my $varlist ($result->varlists()) {
                foreach my $v (@$varlist) {
                    next if @$v[0] eq 'sysUpTimeInstance';
                    # we skip interfaces that aren't interesting to us (determined by getpolled.pl)
                    next unless exists $polled->{$comm}->{$host}->{'interfaces'}->{@$v[1]};
                    my $ifname = $polled->{$comm}->{$host}->{'interfaces'}->{@$v[1]}->{'ifName'};
                    # no slashes allowed in graphite metric names/paths
                    $ifname =~ s/\//-/g;
                    my $hostname = $polled->{$comm}->{$host}->{'hostname'};
                    # more sanitization if your device hostnames have dots in them
                    $hostname =~ s/\./-/g;
                    # if you wanted to customize your graphite metric paths based on your
                    # device hostnames or whatever else, you can do it here
                    # consider the next 8 lines to be a working example. :-)
                    my @hostparts = split(/-/, $hostname);
                    my $dc = $hostparts[0];
                    if ($hostname =~ m/-COR-/) {
                        push @{$int_data}, ["snmp.$dc.core.$hostname.$ifname.@$v[0].count", [$start_time, @$v[2]]];
                    }
                    if ($hostname =~ m/-EDG-/) {
                        push @{$int_data}, ["snmp.$dc.edge.$hostname.$ifname.@$v[0].count", [$start_time, @$v[2]]];
                    }
                }
            }
        }

        my $int_msg = pack("N/a*", pickle_dumps($int_data));

        $sock->send($int_msg);
    }

    $sock->shutdown(2);
    $pm->finish;
}
$pm->wait_all_children;

my $end_time = time();

my $total_time = $end_time - $start_time;

$logger->info("completed run in $total_time seconds.");

# P::S::P was only written for an intended purpose of working on pickled files. See
# http://stackoverflow.com/questions/9829539/perl-equivlent-to-this-python-code
sub pickle_dumps {
    open(my $fh, '>', \my $s) or die $!;
    my $pickle = bless({ _fh => $fh }, 'Python::Serialise::Pickle');
    $pickle->dump($_[0]);
    $pickle->close();
    return $s;
}

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
use YAML qw/LoadFile DumpFile/;

&SNMP::loadModules('ALL');
&SNMP::initMib();

my $devices = LoadFile('/path/to/devices/spec.yaml');
my $polled_fn = "polling.yaml";

my %polled = ();

foreach my $device (sort(keys %{$devices})) {
    $polled{$devices->{$device}->{'snmp'}}->{$devices->{$device}->{'mgmt'}}->{'hostname'} = $device;
    my $v = get_vendor($devices->{$device}->{'mgmt'}, $devices->{$device}->{'snmp'});
    my $types = get_types($devices->{$device}->{'mgmt'}, $devices->{$device}->{'snmp'});
    $polled{$devices->{$device}->{'snmp'}}->{$devices->{$device}->{'mgmt'}}->{'interfaces'} = get_names($types, $devices->{$device}->{'snmp'});
    # figured it might be useful to get vendor info
    if ($v =~ m/ironware/i) {
        $polled{$devices->{$device}->{'snmp'}}->{$devices->{$device}->{'mgmt'}}->{'vendor'} = 'Brocade'
    }
    if ($v =~ m/cisco/i) {
        $polled{$devices->{$device}->{'snmp'}}->{$devices->{$device}->{'mgmt'}}->{'vendor'} = 'Cisco'
    }
}

DumpFile($polled_fn, \%polled);

sub get_types {
    # build a request to get list of interface types from the device
    # return another VarReq with the indexes that we care about
    my ($polled, $comm) = @_;
    my $req_types = SNMP::Multi::VarReq->new (
        nonrepeaters => 1,
        hosts => [ $polled ],
        vars => [ [ 'sysUpTime' ], [ 'ifType' ] ],
    );
    die "VarReq: $SNMP::Multi::VarReq::error\n" unless $req_types;

    my $sm = SNMP::Multi->new (
        Method      => 'bulkwalk',
        MaxSessions => 32,
        PduPacking  => 16,
        Community   => $comm,
        Version     => '2c',
        Timeout     => 5,
        Retries     => 3,
        UseNumeric  => 1,
    )
    or die "$SNMP::Multi::error\n";

    $sm->request($req_types) or die $sm->error;
    my $resp = $sm->execute() or die "Execute: $SNMP::Multi::error\n";

    my @indexes;

    foreach my $host ($resp->hosts()) {
        foreach my $result ($host->results()) {
            if ($result->error()) {
                print "Error with $host: ", $result->error();
                next;
            }

            foreach my $varlist ($result->varlists()) {
                foreach my $v (@$varlist) {
                    # We only care about physical interfaces;
                    # this can obviously be changed as needed.
                    # ifType(6) == ethernetCsmacd
                    # ifType(202) == virtualTg (Virtual Trunk Group aka LAG)
                    push @indexes, @$v[1] if @$v[2] == 6;
                    push @indexes, @$v[1] if @$v[2] == 202;
                }
            }
        }
    }

    my @names;
    push @names, [ 'sysUpTime' ];
    foreach my $i (@indexes) {
        push @names, [ "IF-MIB::ifName." . $i ];
    }

    my $req_names = SNMP::Multi::VarReq->new (
        nonrepeaters => 1,
        hosts => [ $polled ],
        vars => [ @names ],
    );
    die "VarReq: $SNMP::Multi::VarReq::error\n" unless $req_names;

    return $req_names;
}

sub get_names {
    # issue request for ifName of the interesting interfaces
    # so that they can be converted to json by main()
    my ($req, $comm) = @_;

    my $sm = SNMP::Multi->new (
        Method      => 'get',
        MaxSessions => 32,
        PduPacking  => 16,
        Community   => $comm,
        Version     => '2c',
        Timeout     => 5,
        Retries     => 3,
        UseNumeric  => 0,
    )
    or die "$SNMP::Multi::error\n";

    $sm->request($req) or die $sm->error;
    my $resp = $sm->execute() or die "Execute: $SNMP::Multi::error\n";

    my %response = ();

    foreach my $host ($resp->hosts()) {
        foreach my $result ($host->results()) {
            if ($result->error()) {
                print "Error with $host: ", $result->error();
                next;
            }

            foreach my $varlist ($result->varlists()) {
                foreach my $v (@$varlist) {
                    if (@$v[0] eq '1.3.6.1.2.1.31.1.1.1.1') {
                       $response{@$v[1]}->{'ifName'} = @$v[2]
                    }
                }
            }
        }
    }

    return \%response;
}

sub get_vendor {
    # get vendor of device
    my ($polled, $comm) = @_;
    my $req = SNMP::Multi::VarReq->new (
        nonrepeaters => 1,
        hosts => [ $polled ],
        # for snmpget (vs snmpbulkwalk), the fully
        # qualified MIB object is required
        vars => [ [ 'sysUpTime' ], [ 'SNMPv2-MIB::sysDescr.0' ] ],
    );
    die "VarReq: $SNMP::Multi::VarReq::error\n" unless $req;

    my $sm = SNMP::Multi->new (
        Method      => 'get',
        MaxSessions => 32,
        PduPacking  => 16,
        Community   => $comm,
        Version     => '2c',
        Timeout     => 5,
        Retries     => 3,
        UseNumeric  => 1,
    )
    or die "$SNMP::Multi::error\n";

    my $vendor = undef;

    $sm->request($req) or die $sm->error;
    my $resp = $sm->execute() or die "Execute: $SNMP::Multi::error\n";

    foreach my $host ($resp->hosts()) {
        foreach my $result ($host->results()) {
            if ($result->error()) {
                print "Error with $host: ", $result->error();
                next;
            }

            foreach my $varlist ($result->varlists()) {
                foreach my $v (@$varlist) {
                    next if @$v[0] eq '1.3.6.1.2.1.1.3';
                    $vendor = @$v[2]
                }
            }
        }
    }

    return $vendor;
}

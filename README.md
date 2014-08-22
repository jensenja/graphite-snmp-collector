graphite-snmp-collector
=======================

This is a set of scripts and configuration files that are designed to poll a set of OIDs from various devices and then send that data to a Graphite instance. The scripts themselves are written in Perl and are currently intended to be run via cron. These scripts have only been run on Debian Linux systems and have only been tested with Perl 5.14.2. Set up of said systems is beyond the scope of this document, however I will call out the dependencies/system setup where these have been used with success (benchmarked at around 55k metrics per minute):

 1. Linux based operating system (I used Debian 7.5 64-bit)
 2. [Net-SNMP v5.7.2](http://sourceforge.net/projects/net-snmp/files/net-snmp/5.7.2/) (compiled from source with embedded Perl/Python modules - also note I have only used SNMPv2c with this, not SNMPv3)
 3. [SNMP::Multi](http://search.cpan.org/~tpg/SNMP-Multi-2.1/Multi.pm)
 4. [YAML](http://search.cpan.org/dist/YAML/lib/YAML.pod)
 5. [Log::Log4perl](http://search.cpan.org/~mschilli/Log-Log4perl-1.44/lib/Log/Log4perl.pm)
 6. [Parallel::ForkManager](http://search.cpan.org/~dlux/Parallel-ForkManager-0.7.5/ForkManager.pm)
 7. IO::Socket::INET (should be part of standard Perl distribution)
 8. [Python::Serialise::Pickle](http://search.cpan.org/~simonw/Python-Serialise-Pickle-0.01/lib/Python/Serialise/Pickle.pm)

Deploying is relatively straightforward. Configuring the system for Net-SNMP is the first thing that needs to happen.

Again, on a Debian system, one would just do:

    sudo apt-get install build-essential libtool libperl-dev python2.7-dev python-setuptools

This installs the necessary dependencies for Net-SNMP v5.7.2 to be compiled from source. Once you untar the Net-SNMP distribution, you then build it with the following options:

    ./configure --prefix=/usr --with-perl-modules --with-python-modules
    make
    sudo make install

(NOTE: Changing the directory in the `--prefix` flag is optional, but will install the libraries into /usr/lib rather than /usr/local/lib - which may or may not make your life easier if you're building something that needs access to the SNMP libs)

This will build and install Net-SNMP, standard MIBs, as well as the Perl and Python extensions to Net-SNMP.

At this point some may be asking "why not just use [Net::SNMP](http://search.cpan.org/~dtown/Net-SNMP-v6.0.1/lib/Net/SNMP.pm) instead?" Because Net::SNMP is pure Perl and much slower compared to the SNMP Perl module that comes with the Net-SNMP distribution (which is basically an XS extension).

Everything else can be installed from CPAN, however one may also want to consider installing `libyaml-dev` (if on a Debian-based system) to speed up YAML operations as well.


----------

## How The Scripts Work: 100-foot View ##

At a 100-foot view, the only thing you need to have this start working is a YAML document that is formatted with device hostnames as hash keys, and the values being another hash that contains a management interface IP address, as well as a SNMP community string. Exactly like so:

    ---
    zeus: {mgmt: 10.9.2.14, snmp: public}
    apollo: {mgmt: 10.9.2.15, snmp: public}

When your devices are added to your YAML file in this way, you can then run the script called `getpolled.pl` which has the job of reading your YAML spec which you created for the devices themselves and then generating another YAML file which functions to group devices with the same SNMP community string together, as well as provide mappings of SNMP ifIndex values to other attributes (ifName is definitely used, but others could be added as well). We'll call this the "interfaces YAML file."

The second script is called `collector.pl` and its job is to read in the interfaces YAML file and then issue the SNMP queries for the desired OIDs, collect the data and then feed it directly into Graphite. Both `getpolled.pl` and `collector.pl` can be run on a cron'ed schedule - the only real changes that need to be made would be to the devices YAML file.

## How The Scripts Work: 10-foot View ##

The Perl scripts make extensive use of the SNMP::Multi Perl module, which utilizes the asynchronous capabilities of the Net-SNMP Perl SNMP XS extension, essentially allowing a call for multiple OIDs to many hosts in parallel. On top of that, Parallel::ForkManager is used to spawn a new process of polling loop for each unique community string in your devices YAML file (note however that multiple communities per devices are not supported). So for example, if you have a network of 100 devices, and you have 4 SNMP community strings in use evenly across those devices (25 devices per unique community string), then `collector.pl` would essentially spawn 4 child processes which would then issue 25 asynchronous SNMP calls to the hosts. These calls could contain a single or multiple requests for [values at] OIDs at a time. When the SNMP data was returned, each process would then write that data to Graphite. When the data is written to Graphite, it is sent directly to carbon's Pickle interface via Python::Serialise::Pickle and IO::Socket::INET, rather than carbon's line receiver interface ("plaintext protocol" in the carbon documentation). The Pickle interface supports sending batches of metrics at a time vs. sending a single metric at a time via a socket to carbon's line receiver interface, thus being much more efficient.

## Caveats ##

It needs to be noted that I'm intentionally being somewhat specific with regards to which SNMP data that I would care about getting into Graphite. `getpolled.pl` is coded to ***only care about Ethernet interfaces as well as LAG interfaces*** - everything else that would have a registered ifType is ignored, ie SONET interfaces, MPLS LSP's, etc. In addition, only the following counters from IF-MIB are queried per interface:

 1. ifHCInOctets
 2. ifHCInUcastPkts
 3. ifHCInMulticastPkts
 4. ifHCInBroadcastPkts
 5. ifInErrors
 6. ifInDiscards
 7. ifHCOutOctets
 8. ifHCOutUcastPkts
 9. ifHCOutMulticastPkts
 10. ifHCOutBroadcastPkts
 11. ifOutErrors
 12. ifOutDiscards

This can obviously be customized in `collector.pl` to the user's liking, or even be abstracted away by more configuration files or perhaps a database.

Additionally, how the Graphite data is stored/downsampled is relevant. For SNMP data one needs to be using the default average aggregation method. It's at the user's discretion on how frequently they want to poll their devices and retain the metrics in Graphite.

***Please also reference line 124 in `collector.pl` for an example of how these metric paths are created - you will likely need to change this routine to fit your environment.*** The metric paths are important to consider, since you will be able to leverage them to get useful statistical information about your SNMP data. Using the example in the script itself, I'm able to get aggregate traffic for an entire datacenter because of Graphite's handy metric path wildcards and because I have defined my metric paths in a useful manner.

## Futures ##

I would like to keep working on this - I have some ideas about getting rid of the cron dependency and working the poller into an event loop paradigm such as [AnyEvent](http://search.cpan.org/dist/AnyEvent/lib/AnyEvent.pm) and it looks like there may [already be some code started for this](http://search.cpan.org/~jbarratt/AnyEvent-Graphite-0.08/lib/AnyEvent/Graphite/SNMPAgent.pm). I am also not a software development engineer by trade so I would value input from others on where I did things poorly or can make things better.

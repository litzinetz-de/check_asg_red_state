#!/usr/bin/perl -w
#vim:et:sw=3
# ---

=head1 NAME

check_asg_red_state - Nagios plugin for checking Astaro RED Device state

=head1 SYNOPSIS

 check_asg_red_state -H Host -R Red ID [-t] [-c] [-v] \

 check_asg_red_state [-h|-V]

=head1 OPTIONS

=over 4

=item -H|--hostl=IP address or hostname

The IP address or hostname where the red device connects to, e.g. 192.168.0.1 or fw.domain.net

=item -R|--red=red ID

The Red ID which should be checked

=item -t|--timeout=value (default: 10)

sets the timeout for this check, by default 10.

=item -c|--StrictHostKeyChecking={yes;no} (default: no)

Use strict host key check for the connection

=item -v|--verbose

increases verbosity, specify twice to see the original output.

=item -V|--version

print version an exit

=item -h|--help

print help message and exit

INFO

You need to gennerate a key pair for the nagios user in order to use the passwordless authentication with the host. 
This can be done by running ssh-keygen -t rsa -N "" as nagios user or su - nagios -c 'ssh-keygen -t rsa -N "" '.
The public key needs to configured on the firewall for the loginuser.

 ASG <  version 8: the key must be manually add to the authorized_keys file
 ASG >= version 8: the key can be set in the webinterface

=back

=cut

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../perl/lib";
use Nagios::Plugin;
use Getopt::Long qw(:config no_ignore_case bundling);
use Pod::Usage;
use Storable;
use Time::Local;
use POSIX qw/floor/;

my $name = "RED STATE";
my $np = Nagios::Plugin->new( shortname => $name);
my $host = '';
my $tmpdir = '/tmp';
my $cmd_scp = '';
my $use_scp_option_StrictHostKeyChecking = 'no';
my $line = '';
my $line_time = "";
my $line_date = "";

my $red_id = '';
my $red_ip = '';
my @red_connected_since = '';
my $red_connected_since_min = 0;

my $result = UNKNOWN;
my $version = 'V1.1/2011-30-08/dm';
my $printversion = 0;
my $verbose = 0;
my $help = 0;
my $timeout = 10;
my $debug = 0;
my $uptime = "";


# -- GetOpt
GetOptions(
   "H|host=s"       => \$host,
   "R|red=s"        => \$red_id,
   "t|timeout=s"    => \$timeout,
   "c|StrictHostKeyChecking=s" => \$use_scp_option_StrictHostKeyChecking,
   "h|help"         => \$help,
   "V|version"      => \$printversion,
   "v|verbose+"     => \$verbose,
   "d|debug:+"      => \$debug,
) or pod2usage({ -exitval => UNKNOWN,
                 -verbose => 0,
                 -msg     => "*** unknown argument found ***" });

pod2usage(-verbose => 1,
          -exitval => UNKNOWN,
     -output  => \*STDOUT,
         ) if ( $help );

pod2usage(-msg     => "\n$0 -- version: $version\n",
          -verbose => 0,
          -exitval => UNKNOWN,
         ) if ( $printversion );

pod2usage(-msg     => "*** no host/RED ID specified ***",
          -verbose => 0,
          -exitval => UNKNOWN,
         ) unless $red_id;

# -- Alarm

$SIG{ALRM} = sub { $np->nagios_die("Timeout reached"); }; 
alarm($timeout);

# -- main

$host = $1 if ($host && $host =~ m/^([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+|[a-zA-Z][-a-zA-Z0-9]+(\.[a-zA-Z][-a-zA-Z0-9]+)*)$/);
unless ($host) {
   print "No target host specified\n";
   $np->nagios_exit( CRITICAL, "Failure in hostname or IP");
}

$cmd_scp = `LANG=C scp -p -o StrictHostKeyChecking=$use_scp_option_StrictHostKeyChecking loginuser\@$host:/var/sec/chroot-httpd/tmp/red/server/red_state_$red_id $tmpdir/ 2>&1 `;

if (length($cmd_scp) =~ 0 or $cmd_scp =~ /Warning: Permanently added/ ) {
   print " connect to firewall ($host) successful \n" if ($verbose);
   $line = `ls -l $tmpdir/red_state_$red_id --time-style=long-iso 2>&1`;
   ($line_time) = $line =~ /([0-9]{2}:[0-9]{2})/;
   ($line_date) = $line =~ /([0-9]{4}-[0-9]{2}-[0-9]{2})/;
   print " file info $tmpdir/red_state_$red_id  time: $line_time  date: $line_date\n" if ($verbose);
   
   if (($line !~ /cannot access/i) and ($line !~ /No such file or directory/i)) {
      my $time_now = time();
      my @red_time = split(/:/,$line_time);
      my @red_day = split(/-/,$line_date);
      my $time_red = timelocal(0,$red_time[1],$red_time[0],$red_day[2],$red_day[1]-1,$red_day[0]-1900);
      $red_connected_since_min = int(($time_now - $time_red)/60);
      $red_connected_since[2] = int($red_connected_since_min%60); # min
      $uptime = "${red_connected_since[2]}min";
      $red_connected_since[1] = floor(($red_connected_since_min/60)%24); #hours
      $red_connected_since[0] = floor($red_connected_since_min/1440); # day
      $uptime = "${red_connected_since[1]}h $uptime" if (floor($red_connected_since[1] >0));
      $uptime = "${red_connected_since[0]}d $uptime" if (floor($red_connected_since[0] >0));
      print " time now: $time_now - RED connection time $red_connected_since_min\n" if ($verbose);
     
      if ((`ls -s $tmpdir/red_state_$red_id` =~ /([0-9]+)/) !~ "0") { # online
         my $hashref;
         $hashref = retrieve("$tmpdir/red_state_$red_id");
         $red_ip = $hashref->{'peer'};
         `rm -rf $tmpdir/red_state_$red_id`;
         $result = OK;
       #$np->add_perfdata( label => "Uptime", value => $red_connected_since_min, uom => "min" );
	   $np->add_perfdata( label => "State", value => 1, uom => "" );
      } else { # offline
        `rm -rf $tmpdir/red_state_$red_id`;
        $np->nagios_exit( CRITICAL, "unable to connect to RED - offline since $uptime");
      }
   }
} else {
   $np->nagios_exit( CRITICAL, "unable to connect to firewall or file not found");
}


alarm(0);

$np->nagios_exit( $result, "RED connected from $red_ip, uptime $uptime");

=head1 AUTHOR

daniel.mueller (at) cobotec (dot) de

=head1 KNOWN ISSUES

may be

=head1 BUGS

may be

=head1 LICENSE

This program is free software; you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation; version 2 of the License (and no
later version).

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program; if not, write to the Free Software
Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307 USA

=head1 HISTORY

V1.1/2011-30-08 minor bugfixes, changed default value for StrictHostKeyChecking to no
V1.0/2011-01-06 inital version

=cut

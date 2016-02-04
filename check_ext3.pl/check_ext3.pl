#!/usr/bin/perl

# Nagios Check to detect ext3 errors

BEGIN {
        if ($0 =~ m/^(.*?)[\/\\]([^\/\\]+)$/) {
                $runtimedir = $1;
                $PROGNAME = $2;
        }
}

use strict;
use lib $main::runtimedir;
use utils qw($TIMEOUT %ERRORS &print_revision &support);
alarm($TIMEOUT);
open DMESG, "/bin/dmesg |";
open SYSLOG, "cat /var/log/syslog /var/log/syslog.0 |";

my @errors;
my @warnings;

foreach (<DMESG>) {
        chomp;
        if (/EXT[34]-fs error/) {
                push(@errors, $_);
        }
}
foreach (<SYSLOG>){
        if (/I\/O error|media error|device error|bus error/) {
          next if (/I\/O error: Disk quota exceeded/);
          push(@warnings, $_);
        }
}


# Just in case of problems, let's not hang NetSaint
$SIG{'ALRM'} = sub {
        print "ERROR: No response from dmesg (alarm)\n";
        exit $ERRORS{"UNKNOWN"};
};

close DMESG;
close SYSLOG;

if (@errors) {
        my $sample_errorline = shift(@errors);
        print "CRITICAL: $sample_errorline\n";
        exit $ERRORS{'CRITICAL'};
}elsif ( @warnings ){
        my $sample_errorline = shift(@warnings);
        print "WARNING: $sample_errorline\n";
        exit $ERRORS{'WARNING'};
}else {
        print "OK: No ext3/4 errrors detected\n";
        exit $ERRORS{'OK'};
}


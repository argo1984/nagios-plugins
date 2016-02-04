#!/usr/bin/perl
# RAIDs monitoring script
#
# Supported devices:
#     LSI (aka PERC), 3ware, HP Smart Array (CCISS)
#
# RAID data:
#     virtual disk status, write-cache status, BBU status (for LSI and HP Smart Array)
#
# SMART data:
#     pending sectors, relocated sectors ("defect list" for SAS), temperature,
#     self-test status. Maximum temperature within all drives will be displayed
#     on the graph.
#
# HP Smart Array !NOTE!:
#     A new Smart Array driver called "hpsa" has been accepted into the main
#     line linux kernel as of Dec 18, 2009, in linux-2.6.33-rc1. This new
#     driver will support new Smart Array products going forward, and the
#     cciss driver will eventually be deprecated. Initially, there was some
#     overlap in the boards which these two drivers support. So, it is required to
#     rewrite hp_check_staus() once the new driver is on place.
#

use strict;
use warnings;
use Getopt::Long;
use POSIX ':sys_wait_h';

my %messages = (
    bad_args            => ' bad arguments;',
    no_supported_raid   => ' no supported device;',
    unsupported         => ' %s support is not implemented yet;',
    lsi_bbu_absent      => ' BBU absent;',
    lsi_bbu_bat_bad     => ' Battery Bad;',
    lsi_bbu_bat_time    => ' Remaining Time Alarm;',
    lsi_bbu_bat_cap     => ' Remaining Capacity Alarm;',
    lsi_bbu_bat_charge  => ' Charger not completed;',
    lsi_bbu_bad         => ' BBU Bad;',
    lsi_bad_drive       => ' %s Bad Drives;',
    lsi_errors          => ' %s Errors at LSI-RAID;',
    lsi_state_policy    => ' state "%s" on VD%s is not optimal;',
    tw_state_policy     => ' state is not optimal; %s dives affected;',
    tw_port_status      => ' Port%s status "%s" is not optimal;',
    hp_vol_state_policy => ' "%s" state is not optimal at %s;',
    hp_var_policy       => ' "%s" status is not OK at %s;',
    raid_wc_policy      => ' cache policy "%s" on VD%s is not optimal;',
    check_run_error     => ' error: Could not execute %s check;',
    check_not_exist     => ' error: Could not find %s tool;',
    smart_test_fail     => ' SMART self-test failure at %s Port%s;',
    smart_health_fail   => ' SMART Health Status is "%s" at %s Port%s;',
    smart_check_failure => ' no SMART info from %s at Port%s;',
    pending_sectors     => ' %s pending sectors at %s Port%s;',
    relocated_sectors   => ' %s relocated sectors at %s Port%s;',
    hight_temperature   => ' temperature is  %sC at %s Port%s;',
);

my $help;
my $no_bbu = 'N';

#Default threshold values
my $temp_w      = 35;
my $temp_c      = 40;
my $relocated_w = 0;
my $relocated_c = 0;
my $pending_w   = 0;
my $pending_c   = 0;

my $GetOptions_result = GetOptions(
    'help'          => \$help,
    'no_bbu=s'      => \$no_bbu,
    'temp_w=i'      => \$temp_w,
    'temp_c=i'      => \$temp_c,
    'pending_w=i'   => \$pending_w,
    'pending_c=i'   => \$pending_c,
    'relocated_w=i' => \$relocated_w,
    'relocated_c=i' => \$relocated_c,
);

if ( $GetOptions_result != 1 ) {
    mydie( $messages{'bad_args'} );
}

if ($help) {
    print <<HELP;
Usage: $0 [--check_bbu=Y|N] [--temp_w=temp] [--temp_c=temp]
          [--pending_w=count] [--pending_c=count]
          [--relocated_w=count] [--relocated_c=count]

       --no_bbu do not check BBU state (for LSI)
       --temp_w warning threshold for HDD temperature
       --temp_c critical threshold for HDD temperature
       --pending_w warning threshold for pending sectors
       --pending_c critical threshold for pending sectors
       --relcoated_w warning threshold for relocated sectors
       --relocated_c critical threshold for relocated sectors
HELP
    exit;
}

my $result             = 'OK';
my $result_description = '';
my $result_perf        = '';
my %result_rank        = (
    'OK'       => 0,
    'WARNING'  => 1,
    'CRITICAL' => 2,
);

#LSI binary utils
my $megacli      = '/usr/bin/megacli';
my $megacli_opts = '-NoLog';

#3ware binary utils
my $tw_cli = '/usr/bin/tw_cli';

#HP Smart Array binary utils
my $hp_cli     = '/usr/bin/cciss_vol_status';
my $hp_acu_cli = '/usr/sbin/hpacucli';

#smartmontools
my $smart_ctl = '/usr/sbin/smartctl';

my %paths = (
    'direct'     => [ $smart_ctl ],
    'megaraid'   => [ $smart_ctl, $megacli ],
    '3ware'      => [ $smart_ctl, $tw_cli  ],
    'cciss'      => [ $smart_ctl, $hp_cli, $hp_acu_cli],
    'hpsa'       => [ $smart_ctl, $hp_cli, $hp_acu_cli],
);

check_raid();

print "DISK_HEALTH $result - $result_description | $result_perf\n";
exit $result_rank{$result};

sub check_raid {
    my %handlers  = (
        'megaraid' => \&check_megaraid,
        '3ware'    => \&check_3ware,
        'cciss'    => \&check_cciss,
        'hpsa'     => \&check_hpsa,
        'direct'   => \&check_direct,
    );
    
    my $raid_type = get_raid_type();
    if ( exists $handlers{$raid_type} ) {
        check_paths($raid_type);
        $handlers{$raid_type}->();
    }
    return;
}

sub check_paths {
    my ($raid_type) = @_;
    
    foreach my $key ( @{ $paths{$raid_type} } ) {
        if ( ! -x $key ) {
            mydie( sprintf $messages{'check_not_exist'}, $raid_type );
        }
    }
    return;
}

sub get_raid_type {
    my %identity = (
        '/sys/bus/pci/drivers/megaraid_sas' => 'megaraid',
        '/sys/bus/pci/drivers/3w-xxxx'      => '3ware',
        '/sys/bus/pci/drivers/cciss'        => 'cciss',
        '/sys/bus/pci/drivers/hpsa'         => 'hpsa',
    );
    
    my $raid_type = 'direct';
    foreach my $key ( keys %identity ) {
        if ( -d $key ) {
            $raid_type = $identity{$key};
            last;
        }
    }
    return $raid_type;
}

sub check_megaraid {
    if ( $no_bbu ne 'Y' ) {
        check_lsi_bbu_status();
    }
    check_lsi_wc_status();
    my $megaraid_ports_ref = check_lsi_pd_status();
    check_smart( 'megaraid', undef, $megaraid_ports_ref );
    return;
}

sub check_3ware {
    my $tw_controllers_ref = check_tw_status();
    my $tw_ports_ref       = check_tw_wc_status($tw_controllers_ref);
    check_smart( '3ware', undef, $tw_ports_ref );
    return;
}

sub check_cciss {
    my ( $hp_controller, $hp_ports_ref ) = check_hp_status();
    check_smart( 'cciss', $hp_controller, $hp_ports_ref );
    return;
}

sub check_hpsa {
    my ( $hp_controller, $hp_ports_ref ) = check_hpsa_status();
    check_smart( 'cciss', $hp_controller, $hp_ports_ref );
    return;
}

sub check_direct {
    my $check_smart_status = check_direct_hdd_smart();
    if ( $check_smart_status == 1 ) {
        set_result('WARNING');
        $result_description .= $messages{'no_supported_raid'};
    }
    return;
}

sub check_lsi_bbu_status {
    my @result = `$megacli -AdpBbuCmd -GetBbuStatus -aAll $megacli_opts`;
    if ( WEXITSTATUS($?) != 0 ) {
        mydie( sprintf $messages{'check_run_error'}, 'megaraid' );
    }
    foreach my $line (@result) {
        if ( $line =~ m/^\s*Get BBU Status Failed/ ) {
            set_result('CRITICAL');
            $result_description .= $messages{'lsi_bbu_absent'};
        }
        elsif ( $line =~ m/^\s*Battery Pack Missing\s*:\s*(\w+)$/ ) {
            if ( $1 ne 'No' ) {
                set_result('CRITICAL');
                $result_description .= $messages{'lsi_bbu_absent'};
                return;
            }
        }
        elsif ( $line =~ m/^\s*Battery Replacement required\s*:\s*(\w+)$/ ) {
            if ( $1 ne 'No' ) {
                set_result('WARNING');
                $result_description .= $messages{'lsi_bbu_bat_bad'};
            }
        }
        elsif ( $line =~ m/^\s*Remaining Time Alarm\s*:\s*(\w+)$/ ) {
            if ( $1 ne 'No' ) {
                set_result('WARNING');
                $result_description .= $messages{'lsi_bbu_bat_time'};
            }
        }
        elsif ( $line =~ m/^\s*Remaining Capacity Alarm\s*:\s*(\w+)$/ ) {
            if ( $1 ne 'No' ) {
                set_result('WARNING');
                $result_description .= $messages{'lsi_bbu_bat_cap'};
            }
        }
        elsif ( $line =~ m/^\s*Charger Status\s*:\s*(\w+)/ ) {
            if ( $1 ne 'Complete' ) {
                set_result('WARNING');
                $result_description .= $messages{'lsi_bbu_bat_charge'};
            }
        }
        elsif ( $line =~ m/^\s*isSOHGood\s*:\s*(\w+)/ ) {
            if ( $1 ne 'Yes' ) {
                set_result('CRITICAL');
                $result_description .= $messages{'lsi_bbu_bad'};
            }
        }
    }
    return;
}

sub check_lsi_wc_status {
    my @result = `$megacli -LdInfo -LAll -aAll $megacli_opts`;
    if ( WEXITSTATUS($?) != 0 ) {
        mydie( sprintf $messages{'check_run_error'}, 'megaraid' );
    }
    my $virtual_disk = '';
    foreach my $line (@result) {
        if ( $line =~ m/^Virtual (Disk|Drive)\s*\:\s*(\d+)/ ) {
            $virtual_disk = $2;
        }
        elsif ( $line =~ m/^State\s*:\s*(\w+)/ ) {
            my $raid_current_state = $1;
            if ( $raid_current_state ne 'Optimal' ) {
                set_result('CRITICAL');
                $result_description .= sprintf $messages{'lsi_state_policy'},
                    $raid_current_state, $virtual_disk;
            }
        }
        elsif ( $line =~ m/^Current Cache Policy\s*:\s*(\w+)/ ) {
            my $raid_current_policy = $1;
            if ( $raid_current_policy ne 'WriteBack' ) {
                set_result('CRITICAL');
                $result_description .= sprintf $messages{'raid_wc_policy'},
                    $raid_current_policy,
                    $virtual_disk;
            }
        }
    }
    return;
}

sub check_lsi_pd_status {
    my @megacli_ports                 = ();
    my $megacli_drive_bad             = 0;
    my $megacli_drive_media_err       = 0;
    my $megacli_drive_predictable_err = 0;
    my $megacli_drive_other_err       = 0;

    my @result = `$megacli -PdList  -aAll $megacli_opts`;
    if ( WEXITSTATUS($?) != 0 ) {
        mydie( sprintf $messages{'check_run_error'}, 'megaraid' );
    }
    foreach my $line (@result) {
        if ( $line =~ m/^(\w+) Error Count\s*:\s*(\d+)/ ) {
            my $current_error_type  = $1;
            my $current_error_count = $2;
            if ( $current_error_type eq 'Media' ) {
                $megacli_drive_media_err += $current_error_count;
            }
            else {
                $megacli_drive_other_err += $current_error_count;
            }
        }
        elsif ( $line =~ m/^Predictive Failure Count\s*:\s*(\d+)/ ) {
            $megacli_drive_predictable_err += $1;
        }
        elsif ( $line =~ m/^Slot Number\s*:\s*(\d+)/ ) {
            my $current_slot_number = $1;
            if ( $current_slot_number == 255 ) {
                $megacli_drive_bad++;
            }
            else {
                push @megacli_ports, $current_slot_number;
            }
        }
    }
    if ($megacli_drive_bad) {
        set_result('CRITICAL');
        $result_description .= sprintf $messages{'lsi_bad_drive'},
            $megacli_drive_bad;
    }
    my $error_count =
          $megacli_drive_media_err
        + $megacli_drive_predictable_err
        + $megacli_drive_other_err;
    if ($error_count) {
        set_result('WARNING');
        $result_description .= sprintf $messages{'lsi_errors'}, $error_count;
    }
    return ( \@megacli_ports );
}

sub check_tw_status {
    my $tw_volumes_not_optimal = 0;
    my @tw_controllers         = ();

    my @result = `$tw_cli info`;
    if ( WEXITSTATUS($?) != 0 ) {
        mydie( sprintf $messages{'check_run_error'}, '3ware' );
    }
    foreach my $line (@result) {
        if ( $line =~ m/^c(\d+)(\s+\S+){4}\s+(\d+)/ ) {
            my $current_tw_controller = $1;
            my $current_tw_no_optimal = $3;
            push @tw_controllers, $current_tw_controller;
            $tw_volumes_not_optimal += $current_tw_no_optimal;
        }
    }
    if ( $tw_volumes_not_optimal > 0 ) {
        set_result('CRITICAL');
        $result_description .= sprintf $messages{'tw_state_policy'},
            $tw_volumes_not_optimal;
    }
    return \@tw_controllers;
}

sub check_tw_wc_status {
    my ($tw_controllers_ref) = @_;
    my @tw_ports = ();

    foreach my $cont_id ( @{$tw_controllers_ref} ) {
        my @result = `$tw_cli info c$cont_id`;
        if ( WEXITSTATUS($?) != 0 ) {
            mydie( sprintf $messages{'check_run_error'}, '3ware' );
        }
        foreach my $line (@result) {
            if ( $line =~ m/^u\d+(\s+\S+){6}\s+(\w+)/ ) {
                my $current_cache_status = $2;
                if (   $current_cache_status eq 'OFF'
                    or $current_cache_status eq 'Ri'
                    or $current_cache_status eq 'Rb' )
                {
                    set_result('CRITICAL');
                    $result_description .= sprintf $messages{'raid_wc_policy'},
                        $current_cache_status, $cont_id;
                }
            }
            if ( $line =~ m/^p(\d+)\s+(\S+)/ ) {
                my $tw_port_id  = $1;
                my $port_status = $2;
                push @tw_ports, $tw_port_id;
                if ( $port_status eq 'OK' ) {
                    #It's OK. Nothing to do.
                }
                elsif ($port_status eq 'UNKNOWN'
                    or $port_status eq 'DCB-DATA-CHECK'
                    or $port_status eq 'OFFLINE-JBOD' )
                {
                    set_result('WARNING');
                    $result_description .= sprintf $messages{'tw_port_status'},
                        $tw_port_id, $port_status;
                }
                elsif ($port_status eq 'NOT-PRESENT') {
                    pop @tw_ports;
                }
                else {
                    set_result('CRITICAL');
                    $result_description .= sprintf $messages{'tw_port_status'},
                        $tw_port_id, $port_status;
                }
            }
        }
    }
    return \@tw_ports;
}

sub check_hp_status {
    my $hp_controller_id = '';
    my @hp_ports         = ();

    my @result = `$hp_cli /dev/cciss/c*d0`;
    foreach my $line (@result) {
        if ( $line =~ m{^(/dev/cciss/c(\d+)d\d+).*status\:\s*(.+)\.\s+$} ) {
            $hp_controller_id = $1;
            my $slot_id = $2;
            my $status  = $3;
            if ( $status ne 'OK' ) {
                set_result('CRITICAL');
                $result_description .= sprintf $messages{'hp_vol_state_policy'},
                    $status, $hp_controller_id;
            }
            my @extended_result = `$hp_acu_cli ctrl slot=$slot_id show status`;
            foreach my $extended_line (@extended_result) {
                if ( $extended_line =~ m{^\s*(\w+/?\w+)\s*Status\:\s+(.+)\s+$} ) {
                    my $extended_var    = $1;
                    my $extended_status = $2;
                    if ( $extended_status ne 'OK' ) {
                        set_result('CRITICAL');
                        $result_description .=
                            sprintf $messages{'hp_var_policy'},
                            $extended_var, $hp_controller_id;
                    }
                }
            }
            foreach my $port ( ( 0 .. 10 ) ) {
                if (    -r $hp_controller_id . 'p' . ( $port + 1 )
                    and -w $hp_controller_id . 'p' . ( $port + 1 ) )
                {
                     push @hp_ports, $port;
                }
            }
        }
    }
    return ( $hp_controller_id, \@hp_ports );
}
        
sub check_hpsa_status {
    my $hp_controller_id = '';
    my @hp_ports         = ();
    my $hp_slot          = 0;

    my @result = `$hp_cli /dev/sg* 2>/dev/null`;
    foreach my $line (@result) {
        if ( $line =~ m{^(/dev/\w+).*status\:\s*(.+)\.\s+$} ) {
            $hp_controller_id = $1;
            my $status        = $2;
            if ( $status ne 'OK' ) {
                set_result('CRITICAL');
                $result_description .= sprintf $messages{'hp_vol_state_policy'},
                    $status, $hp_controller_id;
            }
            my @extended_result = `$hp_acu_cli ctrl slot=$hp_slot show status`;
            foreach my $extended_line (@extended_result) {
                if ( $extended_line =~ m{^\s*(\w+/?\w+)\s*Status\:\s+(.+)\s+$} ) {
                    my $extended_var    = $1;
                    my $extended_status = $2;
                    if ( $extended_status ne 'OK' ) {
                        set_result('CRITICAL');
                        $result_description .=
                            sprintf $messages{'hp_var_policy'},
                            $extended_var, $hp_controller_id;
                    }
                }
            }
            my @config_status_result = `$hp_acu_cli ctrl slot=0 show config`;
            foreach my $config_status_line (@config_status_result) {
                if ( $config_status_line =~ m{^\s*physicaldrive\s*(\w+):\d:(\d)} ) {
                    my $port = $2 - 1;
                    push @hp_ports, $port;
                }
            }
        }
        $hp_slot += 1;
    }
    return ( $hp_controller_id, \@hp_ports );
}

sub check_smart {
    my ( $raid_type, $controller, $ports_ref ) = @_;
    my $check_dev       = '';
    my $max_temperature = -273;

    if ( $raid_type eq 'megaraid' ) {
        foreach my $dev ('/dev/sda', '/dev/dm-0') {
            if ( -r $dev and -w $dev ) {
                $check_dev = $dev;
                last;
            }
        }
    }
    elsif ( $raid_type eq '3ware' ) {
        foreach my $dev ('/dev/twe0', '/dev/twa0') {
            if ( -r $dev and -w $dev ) {
                $check_dev = $dev;
                last;
            }
        }
    }
    elsif ( $raid_type eq 'cciss' ) {
        $check_dev = $controller;
    }
    foreach my $port ( @{$ports_ref} ) {
        my @result = `$smart_ctl -a -d $raid_type,$port $check_dev`;
        my $current_exit_status = WEXITSTATUS($?);
        if ( $current_exit_status > 0 and $current_exit_status < 4 ) {
            set_result('CRITICAL');
            $result_description .= sprintf $messages{'smart_check_failure'},
                $raid_type, $port;
        }
        my $temperature = process_smart_info( $raid_type, $port, \@result );
        if ( $temperature > $max_temperature ) {
            $max_temperature = $temperature;
        }
    }
    if ( $max_temperature != -273 ) {
        # DO NOT report temperature if it was not detected
        $result_perf .= "hdd_temperature=$max_temperature";
    }
    return;
}

sub check_direct_hdd_smart {
    my $check_success   = 0;
    my $max_temperature = -273;
    my @check_dev       = ();
    
    foreach my $device_letter ( ( 'a' .. 'z' ) ) {
        if ( -r "/dev/sd$device_letter" and -w "/dev/sd$device_letter" ) {
            push @check_dev, "/dev/sd$device_letter";
        }
    }
    foreach my $device (@check_dev) {
        my @result              = `$smart_ctl -a $device`;
        my $current_exit_status = WEXITSTATUS($?);
        if ( $current_exit_status == 0 or $current_exit_status >= 4 ) {
            my $temperature = process_smart_info( $device, 1, \@result );
            if ( $temperature > $max_temperature ) {
                $max_temperature = $temperature;
            }
            $check_success = 1;
        }
    }
    if ( ( $check_success == 1 ) and ( $max_temperature != -273 ) ) {
        $result_perf .= "hdd_temperature=$max_temperature";
        return 0;
    }
    return 1;
}

sub process_smart_info {
    my ( $raid_type, $port, $result_ref ) = @_;
    my $temperature     = -273;
    my $relocated_count = 0;
    my $pending_count   = 0;
    
    foreach my $line ( @{$result_ref} ) {
        if ( $line =~ m/^Self-test execution status\s*:\s*\(\s*(\d+)\s*\)/ ) {
            if ( $1 != 0 ) {
                set_result('CRITICAL');
                $result_description .= sprintf $messages{'smart_test_fail'},
                    $raid_type, $port;
            }
        }
        if ( $line =~ m/^SMART Health Status\s*:\s+([\w ]+)/ ) {
            my $smart_health_status = $1;
            $smart_health_status =~ s/\s+$//g;
            if ( $smart_health_status ne 'OK' ) {
                set_result('CRITICAL');
                $result_description .= sprintf $messages{'smart_health_fail'},
                    $smart_health_status, $raid_type, $port;
            }
        }
        elsif ( $line =~ m/^Current Drive Temperature:\s+(\d+)/ ) {
            $temperature = $1;
        }
        elsif ( $line =~ m/^\s*194\sTemperature_Celsius(\s+\S+){7}\s+(\d+)/ ) {
            $temperature = $2;
        }
        elsif ( $line =~ m/^\s*5\sReallocated_Sector_Ct(\s+\S+){7}\s+(\d+)/ ) {
            $relocated_count += $2;
        }
        elsif ( $line =~ m/^\s*197\sCurrent_Pending_Sector(\s+\S+){7}\s+(\d+)/ ) {
            $pending_count += $2;
        }
        elsif ( $line =~ m/^Elements in grown defect list:\s+(\d+)/ ) {
            $relocated_count += $1;
        }
    }
    if ( $temperature > $temp_c ) {
        set_result('CRITICAL');
        $result_description .= sprintf $messages{'hight_temperature'},
            $temperature, $raid_type, $port;
    }
    elsif ( $temperature > $temp_w ) {
        set_result('WARNING');
        $result_description .= sprintf $messages{'hight_temperature'},
            $temperature, $raid_type, $port;
    }
    if ( $pending_count > $pending_c ) {
        set_result('CRITICAL');
        $result_description .= sprintf $messages{'pending_sectors'},
            $pending_count,
            $raid_type, $port;
    }
    elsif ( $pending_count > $pending_w ) {
        set_result('WARNING');
        $result_description .= sprintf $messages{'pending_sectors'},
            $pending_count,
            $raid_type, $port;
    }
    if ( $relocated_count > $relocated_c ) {
        set_result('CRITICAL');
        $result_description .= sprintf $messages{'relocated_sectors'},
            $relocated_count, $raid_type, $port;
    }
    elsif ( $relocated_count > $relocated_w ) {
        set_result('WARNING');
        $result_description .= sprintf $messages{'relocated_sectors'},
            $relocated_count, $raid_type, $port;
    }
    return $temperature;
}

sub set_result {
    my ($new_result) = @_;
    
    if ( $result_rank{$result} < $result_rank{$new_result} ) {
        $result = $new_result;
        if ( $result_description eq '' ) {
            $result_description .= 'WARNING:';
        }
    }
    return;
}

sub mydie {
    my ($message) = @_;
    
    print "DISK_HEALTH CRITICAL - $message\n";
    exit 2;
}


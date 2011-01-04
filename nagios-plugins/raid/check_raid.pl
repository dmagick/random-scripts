#!/usr/bin/perl -w
#
# This script should handle all the different types of raid controllers
# we currently deploy with.
# It currently handles:
# - hp
# - dell
# - mdstat
# - threeware
#
# From there it should look at the specific controller to work out
# what's going on.
# After all that, return the right code(s) for nagios to deal with.
#
# The threeware util *requires* being run as root, it will not run any other way.
# So you'll need a sudo line to deal with that for whoever runs nagios
# (either nrpe or nagios depending on the o/s).
# The other utils are not so picky.
#
# general idea is
# degraded == critical, rebuilding == warning
# using a spare == critical

use strict;
use Data::Dumper;

# The main controller class.
# Others extend from this, it just has 2 methods
# 'new' and 'trim'.
# To invoke a new controller to check, just path in the path
# to the file/program and the individual classes deal with the rest.
#
package Controller;

    sub new {
        my $class = shift;
        my $self = {
            _path => shift,
        };

        bless $self, $class;
        return $self;
    };

    # Trim whitespace off the beginning of a string
    # and from the end.
    sub trim {
        my ( $self, $string ) = @_;
        $string =~ s/^\s+//;
        $string =~ s/\s+$//;
        return $string;
    }

# deals with the hp controller (hpacucli)
package hp;

    our @ISA = qw(Controller);

    sub getInfo {
        my( $self ) = @_;
        my @output = `$self->{_path} controller slot=0 physicaldrive all show`;
        my ($raidArray, $driveBay, $driveStatus);

        my $status = 0;
        my $statusMsg = '';
        foreach (@output) {
            my $line = $self->SUPER::trim($_);
            if ($line =~ /^$/) {
                next;
            }

            if ($line =~ /^array (.*)/) {
                $raidArray = $1;
                next;
            }

            if ($line =~ /^physicaldrive/) {
                my @chunk = split(':', $line);
                my @driveinfo = split(',', $chunk[-1]);
                $driveBay = $driveinfo[0];
                $driveStatus = lc($driveinfo[-1]);
                $driveBay =~ s/bay //;
                $driveStatus =~ s/\)//;

                if ($driveStatus =~ /ok/) {
                    next;
                }

                # only set status to '1' if it's currently ok
                if ($status eq 0) {
                    $status = 1;
                }

                # set it to 2 regardless of whether it's currently 2 or 1
                # it's bad either way.
                if ($driveStatus =~ /spare/ or $driveStatus =~ /active spare/) {
                    $status = 2;
                }

                $statusMsg = $statusMsg . "Array $raidArray drive in bay $driveBay has status $driveStatus.";
            }
        }
        return ($status, $statusMsg);
    };

# deals with dell's (perc - omreport)
package dell;

    our @ISA = qw(Controller);

    sub getInfo {
        my( $self ) = @_;
        # First we need the controller id.
        #
        my @output = `$self->{_path} storage controller`;
        my $controllerId = -1;
        foreach (@output) {
            my $line = $self->SUPER::trim($_);
            if ($line =~ /^ID\s+:\s+(.*)/) {
                $controllerId = $1;
                last;
            }
        }
        if ($controllerId lt 0) {
            return (2, "Unable to get controller id");
        }

        my $statusMsg = '';
        my $status = 0;

        # the 'vdisk' output is for the entire array.
        # the output is in this order:
        # so once we hit 'State' we can break out of the output.
        #
        # Controller PERC a/b Integrated (Embedded)
        # ID                        : X
        # Status                    : $arrayStatus
        # Name                      : $arrayName
        # State                     : $arrayState
        #
        my $cmd = "$self->{_path} storage vdisk controller=$controllerId";
        @output = `$cmd`;
        my ($arrayStatus, $arrayName, $arrayState);
        foreach (@output) {
            my $line = $self->SUPER::trim($_);

            if ($line =~ /^Status\s+:\s+(.*)/) {
                $arrayStatus = lc($1);
                next;
            }

            if ($line =~ /^Name\s+:\s+(.*)/) {
                $arrayName = $1;
                next;
            }

            if ($line =~ /^State\s+:\s+(.*)/) {
                $arrayState = lc($1);
            }
        }

        # if it's status is 'Ok' then we don't need to check
        # specific disks, the array is fine.
        if ($arrayState =~ /ok/) {
            return ($status, $statusMsg);
        }

        # we got a non-ok status, something is wrong.
        # we need to check the disks to work out what.
        $cmd = "$self->{_path} storage pdisk controller=$controllerId";
        @output = `$cmd`;
        my ($diskId, $diskStatus, $diskName, $diskState, $diskProgress);
        foreach (@output) {
            my $line = $self->SUPER::trim($_);

            if ($line =~ /^ID\s+:\s+(.*)/) {
                $diskId = $1;
                next;
            }

            if ($line =~ /^Status\s+:\s+(.*)/) {
                $diskStatus = lc($1);
                next;
            }

            if ($line =~ /^Name\s+:\s+(.*)/) {
                $diskName = $1;
                next;
            }

            if ($line =~ /^State\s+:\s+(.*)/) {
                $diskState = lc($1);
                if ($diskState !~ /online/) {
                    $statusMsg = $statusMsg . "$diskName is $diskState ~progress~.";

                    # if the disk is rebuilding, set return status to '1'
                    # (unless something else is already broken)
                    if ($diskState =~ /rebuilding/) {
                        if ($status eq 0) {
                            $status = 1;
                        }
                    } else {
                        $status = 2;
                    }
                }
            }

            if ($line =~ /^Progress\s+:\s+(.*)/) {
                $diskProgress = $1;
                if ($diskProgress !~ /not applicable/i) {
                    $diskProgress = "($diskProgress)";
                } else {
                    $diskProgress = "";
                }
                $statusMsg =~ s/~progress~/$diskProgress/;
            }
        }
        return ($status, $statusMsg);
    };

# mdstat/mdadm - ie linux raid.
package mdstat;

    our @ISA = qw(Controller);

    sub getInfo {
        my( $self ) = @_;
        my ($device, $statusLine);

        my %devices;
        my %statuses;
        my %statusInfo;

        my $statusMsg = '';
        my $status = 0;

        open MDSTAT, $self->{_path} or die $!;
        while (<MDSTAT>) {
            my $line = $_;

            $line = $self->SUPER::trim($line);

            if ($line =~ /^$/) {
                next;
            }

            # Ignore the 'personalities' line
            if ($line =~ /^Personalities/ or $line =~ /unused devices/) {
                next;
            }

            # lines that we want are:
            # $device : active (.*)
            # regardless of their actual status
            # it always says 'active'.
            if ($line =~ /(.*?):\s+active\s+(.*)/) {
                $device = $self->SUPER::trim($1);
                $statusLine = $self->SUPER::trim($2);
                $devices{$device} = $device;
                $statuses{$device} = $statusLine;
                $statusInfo{$device} = '';
                next;
            }

            $statusInfo{$device} = $statusInfo{$device}.$line.".";
        }
        close MDSTAT;

        DEVICE: foreach my $raidArray (sort keys %devices) {
            $statuses{$raidArray} =~ /(raid\d+)\s/;
            my $raidType = $1;

            my @statusBits = split(' ', $statuses{$raidArray});

            # md0 : active raid1 hda5[0] hda6[2](F)
            # hda6 is 'faulty' or failed.
            my $faultFound = 0;
            foreach (@statusBits) {
                if ($_ =~ /(.*?)\[\d+\]\(F\)/) {
                    $statusMsg = $statusMsg . "Device $1 has failed in raid array $raidArray.";
                    $status = 2;
                    $faultFound = 1;
                }
            }

            if ($faultFound gt 0) {
                next DEVICE;
            }

            # We're in recovery, that lowers the error from critical to warning.
            if ($statusInfo{$raidArray} =~ /recovery\s+=(.*)/) {
                $statusMsg = $statusMsg . "Raid array $raidArray is currently rebuilding (".$self->SUPER::trim($1).").";
                if ($status eq 0) {
                    $status = 1;
                }
                next;
            }

            # resync pending is critical and needs action.
            if ($statusInfo{$raidArray} =~ /resync=pending/i) {
                $statusMsg = $statusMsg . "Raid array $raidArray requires a resync.";
                $status = 2;
                next;
            }

            # We're in the process of doing a resync, that lowers the error from critical to warning.
            if ($statusInfo{$raidArray} =~ /resync\s+=(.*)/) {
                $statusMsg = $statusMsg . "Raid array $raidArray is currently resyncing (".$self->SUPER::trim($1).").";
                if ($status eq 0) {
                    $status = 1;
                }
                next;
            }

            # raid 0 - you already know whether it's working or not.
            # broken raid 0 = broken filesystem.
            if ($raidType =~ /^raid0$/) {
                next DEVICE;
            }

            # maybe there has been a disk removed?
            if ($statusInfo{$raidArray} =~ /\d+ blocks \[(\d+)\/(\d+)\]/) {
                my $expectedRaidSize = $1;
                my $realRaidSize = $2;

                if ($realRaidSize lt $expectedRaidSize) {
                    $statusMsg = $statusMsg . "Raid array $raidArray should have $expectedRaidSize disks but only has $realRaidSize.";
                    $status = 2;
                }
                next DEVICE;
            }

            # raid 5 looks a little different:
            # md1 : active raid5 sde1[4] sdd1[3] sdc1[2] sdb1[1]
            # X blocks level 5, 64k chunk, algorithm 2 [5/4] [_UUUU]
            if ($statusInfo{$raidArray} =~ /\d+ blocks level 5.*?\[(\d+)\/(\d+)\]/) {
                my $expectedRaidSize = $1;
                my $realRaidSize = $2;

                if ($realRaidSize lt $expectedRaidSize) {
                    $statusMsg = $statusMsg . "Raid array $raidArray should have $expectedRaidSize disks but only has $realRaidSize.";
                    $status = 2;
                }
                next DEVICE;
            }

            $status = 3;
            $statusMsg = $statusMsg . "Raid array $raidArray has an unknown state: ".$statuses{$raidArray}.".".$statusInfo{$raidArray}.".";
        }

        return ($status, $statusMsg);
    };

package threeware;
    our @ISA = qw(Controller);

    sub getInfo {
        my( $self ) = @_;
        my @output = `sudo $self->{_path} /c0 show 2>&1`;

        my $status = 0;
        my $statusMsg = '';

	if ( $? != 0 ) {
		$statusMsg = "Unable to run command to get controller information (permissions?)";
		foreach (@output) {
			    my $line = $self->SUPER::trim($_);
			    if ($line =~ /^$/) {
				next;
			    }
			$statusMsg = $statusMsg . $line;
		}
		$status = 3;
		return ($status, $statusMsg);
	}

        my (%raidUnits, %raidStatus, %raidPercent, %raidDisks, %diskStatus);
        my ($raidStatus, $raidUnit, $raidPercent);
        my ($diskStatus, $physicalDisk, $vPort);
        foreach (@output) {
            my $line = $self->SUPER::trim($_);

            if ($line =~ /^$/) {
                next;
            }

            # Looking for these sorts of lines:
            # Unit  UnitType  Status         %RCmpl  %V/I/M  Stripe  Size(GB)  Cache  AVrfy
            # ------------------------------------------------------------------------------
            # u0    RAID-1    OK             -       -       -       931.312   ON     OFF    
            # u1    RAID-1    DEGRADED       -       -       -       931.312   OFF    OFF    
            if ($line =~ /(.*?)\s+(RAID-.*?)\s+(.*?)\s+(.*?)\s+/) {
                $raidUnit = $1;
                $raidStatus = $3;
                $raidPercent = $4;
                $raidUnits{$raidUnit} = $raidUnit;
                $raidStatus{$raidUnit} = $raidStatus;
                $raidPercent{$raidUnit} = $raidPercent;
                next;
            }

            # Looking for these sorts of lines under:
            # VPort Status         Unit Size      Type  Phy Encl-Slot    Model
            # ------------------------------------------------------------------------------
            #
            # p0    OK             u0   931.51 GB SATA  0   -            ST31000333AS        
            # p3    OK             u1   931.51 GB SATA  3   -            ST31000333AS        
            if ($line =~ /(.*?)\s+(.*?)\s+(.*?)\s+(\d+\.\d+)\s+[G|T]B\s+(.*?)\s+(\d+)/) {
                $vPort = $1;
                $diskStatus = $2;
                $raidUnit = $3;
                $physicalDisk = $6;
                $raidDisks{$raidUnit} = $diskStatus;
            }
        }

        foreach my $device (sort keys %raidUnits) {
            if ($raidStatus{$device} =~ /OK/) {
                next;
            }

            if ($raidStatus{$device} =~ /REBUILDING/) {
                $statusMsg = $statusMsg . "Raid array $device is currently rebuilding (".$self->SUPER::trim($raidPercent{$device}).").";
                if ($status eq 0) {
                    $status = 1;
                }
            }

            if ($raidStatus{$device} =~ /DEGRADED/) {
                $statusMsg = $statusMsg . "Raid array $device is degraded (missing a disk).";
                $status = 2;
            }
        }

        return ($status, $statusMsg);
};


# not much in the main package
# the 'getType' subroutine works out what sort of
# raid is in use based on which tools are available.
#
# then it just calls the particular class above to do the work.
package main;

    sub getType {
        my %paths = ();
        $paths{'hp'}     = '/opt/compaq/hpacucli/bld/hpacucli';
        $paths{'dell'}   = '/opt/dell/srvadmin/bin/omreport';
        $paths{'threeware'}  = '/usr/local/sbin/tw_cli';

        while (my ($type, $path) = each(%paths)) {
            if (-e $path) {
                return ($type, $path);
            }
        }

        # do this check last after all the rest.
        if (-e '/proc/mdstat') {
            return ('mdstat', '/proc/mdstat');
        }

        return ('unknown', 'unknown');
    }

    my ($controllerType, $controllerPath) = getType();
    if ($controllerType =~ /unknown/) {
        print "Unable to work out controller type, aborting script.";
        exit(3);
    }

    my $controller = new $controllerType($controllerPath);
    my ($status, $statusMsg) = $controller->getInfo();

    if ($status eq 0) {
        $statusMsg = "Everything ok.";
    }
    print $statusMsg;
    exit $status;


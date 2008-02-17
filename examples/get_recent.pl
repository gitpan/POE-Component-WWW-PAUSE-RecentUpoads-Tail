#!/usr/bin/env perl

use strict;
use warnings;

use lib '../lib';
sub POE::Kernel::ASSERT_DEFAULT () { 1 }
use POE qw(Component::WWW::PAUSE::RecentUploads::Tail);

unless ( @ARGV == 2 ) {
    die "usage: perl tail_info.pl PAUSE_LOGIN PAUSE_PASS\n";
}

POE::Component::WWW::PAUSE::RecentUploads::Tail->spawn(
    login => shift,
    pass  => shift,
    store => 'data.file',
    debug => 1,
    alias => 'pause',
);

POE::Session->create(
    package_states => [
        main => [ qw( _start recent ) ],
    ],
);

$poe_kernel->run;

sub _start {
    $poe_kernel->post( pause => fetch =>  {
            event => 'recent',
            interval => 600, # 10 minute interval
        }
    );
}

sub recent {
    my $data_ref = $_[ARG0];

    my $iter_time = localtime $data_ref->{time};

    
    if ( $data_ref->{error} ) {
        print "Failed on this itteration with $data_ref->{error}\n";
    }
    else {
        my $message = @{ $data_ref->{data} || [] }
                    ? "\nNew uploads at $iter_time\n"
                    : "\nNo uploads at $iter_time\n";
        print $message;
        
        foreach my $dist ( @{ $data_ref->{data} || [] } ) {
            printf "%s by %s (size: %s)\n",
                @$dist{ qw( dist name size ) };
        }
    }
}
